# frozen_string_literal: true

require "json"
require "mail"
require "sinatra/base"
require "yaml"

require_relative "lib/db"
require_relative "lib/models/guesser_user"
require_relative "lib/models/answer"
require_relative "lib/models/legal_word"
require_relative "lib/models/played_game"
require_relative "lib/models/user"
require_relative "lib/models/passkey_credential"
require_relative "lib/models/session"
require_relative "lib/models/device_link_token"
require_relative "lib/models/user_profile"
require_relative "lib/models/stats_adjustment"
require_relative "lib/models/storage_snapshot"
require_relative "lib/left_wordle/game"
require_relative "lib/guesser/solve_engine"
require_relative "lib/verbose_logger"
require_relative "lib/webauthn_config"
require_relative "lib/auth_helpers"

class LeftWordleApi < Sinatra::Base
  ANSWER_XOR_KEY = "xQ7mN2vK9pL4wR8tY1sB6dF3hJ0cG5eA"
  DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
  MAX_DIAGNOSTICS_BODY_BYTES = 512 * 1024
  MAX_IMPORT_ENTRIES = 5_000
  # Client-submitted storage_snapshots events -- deliberately narrow (only
  # what a client actually pushes today) rather than accepting an arbitrary
  # string, since this becomes a permanent audit-trail label.
  CLIENT_SNAPSHOT_EVENTS = ["new user creation"].freeze
  # Which flow produced a stats_adjustments row -- "manual" is Tools >
  # Adjust Stats; "signup_reconciliation" is the automatic carry-over-local-
  # totals push in pushLocalDataToNewAccount when history import can't
  # chain everything contiguously. Narrow on purpose, same reasoning as
  # CLIENT_SNAPSHOT_EVENTS above: it becomes a permanent audit-trail label.
  STATS_ADJUSTMENT_SOURCES = %w[manual signup_reconciliation].freeze
  CLIENT_DEVICE_ID_PATTERN = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  RATE_LIMIT_WINDOW_SECONDS = 60
  RATE_LIMIT_MAX_REQUESTS = 20
  RATE_LIMIT_MUTEX = Mutex.new
  RATE_LIMIT_BUCKETS = {}

  set :root, File.expand_path(__dir__)
  enable :static

  configure do
    cfg_file = File.join(File.expand_path(__dir__), "config", "app_config.yml")
    app_cfg = File.exist?(cfg_file) ? (YAML.load_file(cfg_file) || {}) : {}
    set :allowed_origins, Array(app_cfg["cors_origins"]).map(&:strip).reject(&:empty?).freeze
    set :smtp_username, app_cfg["smtp_username"]
    set :smtp_password, app_cfg["smtp_password"]
    set :smtp_from, app_cfg["smtp_from"]
    set :server_api_token, app_cfg["server_api_token"]
    set :wordle_base_url, app_cfg["wordle_base_url"]
    set :session_secret, app_cfg["session_secret"]
    set :session_token_ttl_days, (app_cfg["session_token_ttl_days"] || 365).to_i
    set :device_link_token_ttl_minutes, (app_cfg["device_link_token_ttl_minutes"] || 15).to_i
    set :webauthn_origin, app_cfg["webauthn_origin"]
    set :logging, false
    set :protection, except: :json_csrf
    set :show_exceptions, false

    LeftWordle::Game.load_words!(
      answers: Answer.order(:position).select_map(:word),
      legal_words: LegalWord.select_map(:word)
    )

    if settings.webauthn_origin.to_s.strip.length.positive?
      LeftWordle::WebauthnConfig.configure!(
        origin: settings.webauthn_origin,
        rp_name: "Left Wordle",
        rp_id: app_cfg["webauthn_rp_id"]
      )
    end

    if ENV["RACK_ENV"] == "production" && app_cfg["session_secret"].to_s.strip.empty?
      raise "session_secret must be set in config/app_config.yml in production"
    end
  end

  helpers AuthHelpers

  set :engine, SolveEngine.new

  before do
    next if request.path.start_with?("/guesser")
    content_type :json
    validate_request_origin!
    headers cors_headers.merge("Cache-Control" => "no-store")
  end

  before "/api/v2/auth/*" do
    rate_limit!(request.path)
  end

  before "/guesser*" do
    guesser_protected!
  end

  before "/guesser/api/*" do
    content_type :json
  end

  options "*" do
    status :no_content
  end

  get "/api/v1/health" do
    health_response
  end

  get "/api/v1/version" do
    version_response
  end

  get "/api/v1/game/puzzle" do
    puzzle_response
  end

  get "/api/v1/game/answer" do
    answer_response
  end

  post "/api/v1/game/start" do
    start_response
  end

  post "/api/v1/game/guess" do
    guess_response
  end

  post "/api/v1/game/remaining_counts" do
    remaining_counts_response
  end

  post "/api/v1/game/complete" do
    complete_response
  end

  post "/api/v1/game/progress" do
    progress_response
  end

  post "/api/v1/diagnostics" do
    diagnostics_response
  end

  get "/api/v1/debug/verbose" do
    require_server_api_token!
    json_response({verbose_logging: VerboseLogging.enabled?})
  end

  post "/api/v1/debug/verbose" do
    require_server_api_token!
    payload = request_payload
    enabled = payload["enabled"]
    halt_json(:bad_request, "enabled must be true or false") unless [true, false].include?(enabled)
    VerboseLogging.enabled = enabled
    json_response({verbose_logging: VerboseLogging.enabled?})
  end

  get "/api/v1/ref/legal_words" do
    legal_words_response
  end

  get "/api/v1/ref/answers" do
    answers_response
  end

  get "/api/v1/ref/prev_answers" do
    prev_answers_response
  end

  post "/api/v2/auth/register/begin" do
    register_begin_response
  end

  post "/api/v2/auth/register/finish" do
    register_finish_response
  end

  post "/api/v2/auth/login/begin" do
    login_begin_response
  end

  post "/api/v2/auth/login/finish" do
    login_finish_response
  end

  post "/api/v2/auth/logout" do
    logout_response
  end

  post "/api/v2/auth/device_link" do
    device_link_response
  end

  post "/api/v2/auth/recover" do
    recover_response
  end

  patch "/api/v2/account/email" do
    patch_email_response
  end

  get "/api/v2/account/passkeys" do
    passkeys_list_response
  end

  delete "/api/v2/account/passkeys/:id" do
    passkey_revoke_response
  end

  get "/api/v2/profile" do
    profile_get_response
  end

  put "/api/v2/profile/preferences" do
    put_preferences_response
  end

  put "/api/v2/profile/game_state" do
    put_game_state_response
  end

  post "/api/v2/profile/local_storage_snapshot" do
    local_storage_snapshot_response
  end

  get "/api/v2/history" do
    history_get_response
  end

  post "/api/v2/history/import" do
    history_import_response
  end

  post "/api/v2/stats/adjust" do
    stats_adjust_response
  end

  get "/guesser" do
    @game_date, @game_date_error = g_validate_game_date(params["date"])
    @param_warnings = g_collect_param_warnings(request.GET)
    @wordle_base_url = settings.wordle_base_url
    erb :guesser
  end

  get "/guesser/api/starter-choices" do
    JSON.generate(starter_choices: guesser.starter_choices)
  end

  post "/guesser/api/start" do
    body = g_json_body
    starter = g_normalized_word(body["starter"])
    g_halt(422, "Starter must be a legal 5 character word") unless g_legal_word?(starter)

    remaining = settings.engine.start_remaining
    JSON.generate(
      starter:,
      attempt: 1,
      current_guess: starter,
      remaining:,
      remaining_count: remaining.length,
      possibilities: g_visible_possibilities(remaining),
      unused_possibilities: g_visible_unused_possibilities(remaining)
    )
  end

  post "/guesser/api/evaluate" do
    body = g_json_body
    guess = g_normalized_word(body["guess"]).downcase
    date_str = body.fetch("date", LeftWordle::Game.latest_available_date.iso8601).to_s

    g_halt(422, "Guess must be a legal 5 character word") unless guess.match?(/\A[a-z]{5}\z/) && LeftWordle::Game.valid_guess?(guess)

    date = begin
      Date.iso8601(date_str)
    rescue Date::Error
      g_halt(422, "Date must be a valid calendar date")
    end

    answer = LeftWordle::Game.answer_for(LeftWordle::Game.puzzle_number_for(date))
    evaluation = g_evaluation_string(LeftWordle::Game.evaluate(guess, answer))

    JSON.generate(evaluation:)
  end

  post "/guesser/api/validate-word" do
    body = g_json_body
    word = g_normalized_word(body["word"])
    remaining = g_word_array(body["remaining"])

    JSON.generate(
      word:,
      valid: g_legal_word?(word),
      in_remaining: remaining.include?(word)
    )
  end

  post "/guesser/api/turn" do
    body = g_json_body
    attempt = Integer(body["attempt"], exception: false)
    guess = g_normalized_word(body["guess"])
    pattern = g_parse_pattern(body["pattern"])
    remaining = g_word_array(body["remaining"])

    g_halt(422, "Attempt must be between 1 and #{SolveEngine::MAX_ATTEMPTS}") unless (1..SolveEngine::MAX_ATTEMPTS).cover?(attempt)
    g_halt(422, "Guess must be a legal 5 character word") unless g_legal_word?(guess)
    g_halt(422, "Pattern must contain exactly five digits from 0 to 2") unless pattern
    g_halt(422, "Remaining words are required") if remaining.empty?

    result = settings.engine.process_turn(remaining:, guess:, pattern:, attempt:)

    case result[:status]
    when :solved
      halt 200, JSON.generate(status: "solved", attempt:, guess:, remaining_count: 0)
    when :no_answers
      halt 200, g_turn_result("no_answers", attempt:, remaining: result[:remaining])
    when :answer
      halt 200, g_turn_result("answer", attempt:, remaining: result[:remaining], answer: result[:answer])
    when :exhausted
      halt 200, g_turn_result("exhausted", attempt:, remaining: result[:remaining])
    when :continue
      g_turn_result("continue", attempt: result[:attempt], remaining: result[:remaining], suggestions: result[:suggestions])
    end
  end

  not_found do
    json_response({detail: "Not found"}, status: :not_found)
  end

  error JSON::ParserError do
    json_response({detail: "Request body must be valid JSON"}, status: :bad_request)
  end

  error do
    json_response({detail: "Internal server error"}, status: :internal_server_error)
  end

  helpers do
    def cors_headers
      origin = request.env["HTTP_ORIGIN"]
      headers = {
        "Access-Control-Allow-Headers" => "Content-Type, X-Device-Id, X-CSRF-Token",
        "Access-Control-Allow-Methods" => "GET, POST, PUT, PATCH, DELETE, OPTIONS",
        "Vary" => "Origin"
      }

      if settings.allowed_origins.include?(origin)
        headers["Access-Control-Allow-Origin"] = origin
        # Same-origin requests never need this (browsers don't apply CORS to
        # them at all), but setting it defends the deployment against ever
        # drifting to a separate frontend/API host without the session
        # cookie silently breaking -- see api/docs/security_architecture.md.
        headers["Access-Control-Allow-Credentials"] = "true"
      end
      headers
    end

    def game_status_for(evaluation, row_index)
      if evaluation.all?(LeftWordle::Game::CORRECT)
        "WIN"
      elsif row_index >= LeftWordle::Game::MAX_GUESSES - 1
        "FAIL"
      else
        "IN_PROGRESS"
      end
    end

    def guess_response
      payload = request_payload
      date = requested_date(payload["date"])
      guess = payload.fetch("guess", "").to_s.downcase

      unless guess.match?(/\A[a-z]{#{LeftWordle::Game::WORD_LENGTH}}\z/o)
        halt_json(:bad_request, "Guess must be #{LeftWordle::Game::WORD_LENGTH} letters")
      end

      unless LeftWordle::Game.valid_guess?(guess)
        halt_json(:bad_request, "Not in word list")
      end

      row_index = row_index_from(payload)

      mode = payload.fetch("mode", "regular").to_s
      halt_json(:bad_request, "Mode must be regular, hard, or insane") unless %w[regular hard insane].include?(mode)

      prev_guesses = payload.fetch("prev_guesses", [])
      unless prev_guesses.is_a?(Array) && prev_guesses.all? { |p|
        p.is_a?(Array) && p.length == 2 &&
          p[0].to_s.match?(/\A[a-zA-Z]{5}\z/) &&
          p[1].to_s.match?(/\A[012]{5}\z/)
      }
        halt_json(:bad_request, "prev_guesses must be an array of [word, pattern] pairs")
      end
      if prev_guesses.length > LeftWordle::Game::MAX_GUESSES
        halt_json(:bad_request, "prev_guesses cannot have more than #{LeftWordle::Game::MAX_GUESSES} entries")
      end

      case mode
      when "hard" then validate_hard_mode!(guess, prev_guesses)
      when "insane" then validate_insane_mode!(guess, prev_guesses)
      end

      puzzle_number = LeftWordle::Game.puzzle_number_for(date)
      answer = LeftWordle::Game.answer_for(puzzle_number)
      evaluation = LeftWordle::Game.evaluate(guess, answer)
      game_status = game_status_for(evaluation, row_index)

      response = {
        date: date.iso8601,
        evaluation: g_evaluation_string(evaluation),
        game_status: game_status,
        puzzle_num: puzzle_number,
        guess_number: row_index + 1,
        solution: (answer if game_status != "IN_PROGRESS")
      }

      if payload["return_remaining_count"] == true
        eval_string = g_evaluation_string(evaluation)
        response[:answers_remaining] = if eval_string == "22222"
          0
        else
          answers_remaining_for(prev_guesses + [[guess, eval_string]])
        end
      end

      json_response(response)
    end

    def diagnostics_response
      raw_body = request.body.read
      halt_json(:bad_request, "Request body is required") if raw_body.strip.empty?
      halt_json(:payload_too_large, "Request body exceeds 512 KB") if raw_body.bytesize > MAX_DIAGNOSTICS_BODY_BYTES
      JSON.parse(raw_body)
      halt_json(:service_unavailable, "Diagnostics email is not configured") unless smtp_configured?
      send_diagnostics_email(raw_body)
      json_response({status: "sent"})
    end

    def smtp_configured?
      settings.smtp_username.to_s.strip.length.positive? &&
        settings.smtp_password.to_s.strip.length.positive?
    end

    def send_diagnostics_email(json_body)
      ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      from_addr = settings.smtp_from.to_s.strip
      from_addr = settings.smtp_username.to_s.strip if from_addr.empty?

      mail = Mail.new
      mail.from    = from_addr
      mail.to      = "left.wordle@wrightzone.com"
      mail.subject = "Left Wordle Diagnostics Report"
      mail.body    = "See attached."
      mail.attachments["left_wordle_diagnostics_#{ts}.json"] = {
        mime_type: "application/json",
        content: json_body
      }
      if ENV["RACK_ENV"] == "test"
        mail.delivery_method :test
      else
        mail.delivery_method :smtp, {
          address: "smtp.fastmail.com",
          port: 587,
          user_name: settings.smtp_username.to_s.strip,
          password: settings.smtp_password.to_s.strip,
          authentication: :login,
          enable_starttls_auto: true
        }
      end

      mail.deliver!
    end

    def halt_json(status, message)
      halt Rack::Utils.status_code(status), JSON.generate(detail: message)
    end

    def health_response
      json_response({status: "ok"})
    end

    def version_response
      revision_file = File.join(__dir__, "REVISION")
      revisions_log = File.join(__dir__, "..", "..", "revisions.log")
      version_file = File.join(__dir__, "VERSION")

      commit = File.exist?(revision_file) ? File.read(revision_file).strip[0, 8] : nil
      release = File.exist?(revisions_log) ? File.readlines(revisions_log).count : nil
      version = File.exist?(version_file) ? File.read(version_file).strip : nil

      json_response({version: version, commit: commit, release: release})
    end

    def json_response(payload, status: :ok)
      status(status)
      JSON.generate(payload)
    end

    def encrypt_answer(word)
      word.each_char.with_index.map { |c, i|
        c.ord ^ ANSWER_XOR_KEY[i % ANSWER_XOR_KEY.length].ord
      }.pack("C*").unpack1("H*")
    end

    def answer_response
      date = requested_date(params["date"])
      puzzle_number = LeftWordle::Game.puzzle_number_for(date)
      answer = LeftWordle::Game.answer_for(puzzle_number)

      headers "Cache-Control" => "public, max-age=300, s-maxage=86400"
      json_response({
        encrypted_answer: encrypt_answer(answer),
        puzzle_num: puzzle_number,
        date: date.iso8601
      })
    end

    def remaining_counts_response
      payload = request_payload
      date = requested_date(payload["date"])
      guesses = payload.fetch("guesses", [])

      unless guesses.is_a?(Array) && guesses.all? { |p|
        p.is_a?(Array) && p.length == 2 &&
          p[0].to_s.match?(/\A[a-zA-Z]{5}\z/) &&
          p[1].to_s.match?(/\A[012]{5}\z/)
      }
        halt_json(:bad_request, "guesses must be an array of [word, pattern] pairs")
      end
      if guesses.length > LeftWordle::Game::MAX_GUESSES
        halt_json(:bad_request, "guesses cannot have more than #{LeftWordle::Game::MAX_GUESSES} entries")
      end

      counts = (0...guesses.length).map { |i|
        guesses[i][1].to_s == "22222" ? 0 : answers_remaining_for(guesses[0..i])
      }
      json_response({date: date.iso8601, remaining_counts: counts})
    end

    def start_response
      payload = request_payload
      date = requested_date(payload["date"])
      puzzle_number = LeftWordle::Game.puzzle_number_for(date)
      submitted_puzzle_number = Integer(payload["puzzle_num"], exception: false)

      halt_json(:bad_request, "puzzle_num is required") unless submitted_puzzle_number
      halt_json(:bad_request, "puzzle_num must match date") unless submitted_puzzle_number == puzzle_number

      if (client_device_id = extract_client_device_id)
        record_game_initiation!(client_device_id, extract_country_code, date, puzzle_number, current_user&.id)
      end

      json_response({status: "recorded"})
    end

    def complete_response
      payload = request_payload
      date = requested_date(payload["date"])

      mode = payload.fetch("mode", "regular").to_s
      halt_json(:bad_request, "Mode must be regular, hard, or insane") unless %w[regular hard insane].include?(mode)

      game_status = payload["game_status"].to_s
      halt_json(:bad_request, "game_status must be WIN or FAIL") unless %w[WIN FAIL].include?(game_status)

      guesses = payload.fetch("guesses", [])
      unless guesses.is_a?(Array) && guesses.any? && guesses.all? { |p|
        p.is_a?(Array) && p.length == 2 &&
            p[0].to_s.match?(/\A[a-zA-Z]{5}\z/) &&
            p[1].to_s.match?(/\A[012]{5}\z/)
      }
        halt_json(:bad_request, "guesses must be a non-empty array of [word, pattern] pairs")
      end
      if guesses.length > LeftWordle::Game::MAX_GUESSES
        halt_json(:bad_request, "guesses cannot have more than #{LeftWordle::Game::MAX_GUESSES} entries")
      end

      puzzle_number = LeftWordle::Game.puzzle_number_for(date)

      if (client_device_id = extract_client_device_id)
        record_game_completion!(client_device_id, extract_country_code, date, puzzle_number, mode, game_status, guesses, current_user&.id)
      end

      json_response({status: "recorded"})
    end

    # Live per-guess save of an in-progress (not yet WIN/FAIL) game -- called
    # after every guess, from every device, logged in or not (see
    # online_play_redesign.md's "Playing online" section and this session's
    # extension of it to offline devices too: server-side visibility into
    # abandoned games, and the basis for an online device resuming a game
    # started on a different device). Same played_games row/target as
    # completion; a device's progress and its eventual completion are just
    # two writes to the same (client_device_id, date) row.
    def progress_response
      payload = request_payload
      date = requested_date(payload["date"])

      mode = payload.fetch("mode", "regular").to_s
      halt_json(:bad_request, "Mode must be regular, hard, or insane") unless %w[regular hard insane].include?(mode)

      guesses = payload.fetch("guesses", [])
      unless guesses.is_a?(Array) && guesses.all? { |p|
        p.is_a?(Array) && p.length == 2 &&
            p[0].to_s.match?(/\A[a-zA-Z]{5}\z/) &&
            p[1].to_s.match?(/\A[012]{5}\z/)
      }
        halt_json(:bad_request, "guesses must be an array of [word, pattern] pairs")
      end
      if guesses.length > LeftWordle::Game::MAX_GUESSES
        halt_json(:bad_request, "guesses cannot have more than #{LeftWordle::Game::MAX_GUESSES} entries")
      end

      puzzle_number = LeftWordle::Game.puzzle_number_for(date)

      if (client_device_id = extract_client_device_id)
        record_game_progress!(client_device_id, extract_country_code, date, puzzle_number, mode, guesses, current_user&.id)
      end

      json_response({status: "recorded"})
    end

    def extract_client_device_id
      raw_device_id = request.env["HTTP_X_DEVICE_ID"]
      raw_device_id if raw_device_id.is_a?(String) && raw_device_id.match?(CLIENT_DEVICE_ID_PATTERN)
    end

    def extract_country_code
      country_code = request.env["HTTP_CF_IPCOUNTRY"]
      country_code if country_code.is_a?(String) && country_code.match?(/\A[A-Za-z]{2}\z/)
    end

    def record_game_initiation!(client_device_id, country_code, date, puzzle_number, user_id = nil)
      DB[:played_games].insert_conflict(
        target: [:client_device_id, :date],
        update: {
          puzzle_num: Sequel[:excluded][:puzzle_num],
          initiated_at: Sequel.function(
            :coalesce,
            Sequel[:played_games][:initiated_at],
            Sequel[:played_games][:completed_at],
            Sequel[:excluded][:initiated_at]
          ),
          country_code: Sequel.function(:coalesce, Sequel[:played_games][:country_code], Sequel[:excluded][:country_code]),
          # A device's rows attach to a user once it has an active session,
          # and never get un-attached by a later anonymous request.
          user_id: Sequel.function(:coalesce, Sequel[:excluded][:user_id], Sequel[:played_games][:user_id])
        }
      ).insert(
        client_device_id: client_device_id, date: date, puzzle_num: puzzle_number,
        country_code: country_code, initiated_at: Sequel::CURRENT_TIMESTAMP, updated_at: Sequel::CURRENT_TIMESTAMP,
        user_id: user_id
      )
    rescue Sequel::DatabaseError
      nil
    end

    # Shared upsert for both a live in-progress save and a final completion --
    # same (client_device_id, date) target row either way, so a game's
    # progress writes and its eventual completion write are just two calls
    # against the same row. game_status is coalesced (not overwritten
    # unconditionally) so a progress call that lands *after* completion
    # (e.g. a lagging retry) can never reset a recorded WIN/FAIL back to
    # unset. completed_at is only ever set by a completion call
    # (`completed:` true) and, like the other fields, coalesced so it's
    # never clobbered back to nil by a later progress write.
    def record_game_event!(client_device_id, country_code, date, puzzle_number, mode, game_status, guesses, user_id, completed:)
      DB[:played_games].insert_conflict(
        target: [:client_device_id, :date],
        update: {
          puzzle_num: Sequel[:excluded][:puzzle_num],
          mode: Sequel[:excluded][:mode],
          game_status: Sequel.function(:coalesce, Sequel[:excluded][:game_status], Sequel[:played_games][:game_status]),
          guesses: Sequel[:excluded][:guesses],
          completed_at: Sequel.function(:coalesce, Sequel[:played_games][:completed_at], Sequel[:excluded][:completed_at]),
          country_code: Sequel.function(:coalesce, Sequel[:excluded][:country_code], Sequel[:played_games][:country_code]),
          user_id: Sequel.function(:coalesce, Sequel[:excluded][:user_id], Sequel[:played_games][:user_id])
        }
      ).insert(
        client_device_id: client_device_id, date: date, puzzle_num: puzzle_number,
        mode: mode, game_status: game_status, guesses: Sequel.pg_json(guesses),
        country_code: country_code, completed_at: (completed ? Sequel::CURRENT_TIMESTAMP : nil),
        updated_at: Sequel::CURRENT_TIMESTAMP, user_id: user_id
      )
    end

    def record_game_completion!(client_device_id, country_code, date, puzzle_number, mode, game_status, guesses, user_id = nil)
      record_game_event!(client_device_id, country_code, date, puzzle_number, mode, game_status, guesses, user_id, completed: true)
      apply_played_game_to_statistics!(User[user_id], puzzle_number, game_status) if user_id
    rescue Sequel::DatabaseError
      nil
    end

    # No game_status (game isn't over yet) and no stats side effect --
    # apply_played_game_to_statistics! only ever runs from a completion.
    def record_game_progress!(client_device_id, country_code, date, puzzle_number, mode, guesses, user_id = nil)
      record_game_event!(client_device_id, country_code, date, puzzle_number, mode, nil, guesses, user_id, completed: false)
    rescue Sequel::DatabaseError
      nil
    end

    # -- Rate limiting (auth endpoints only) -------------------------------
    # Per-process sliding window. Puma runs multiple worker processes, so
    # this only bounds abuse per-worker -- adequate for launch, not a
    # substitute for edge-layer rate limiting (see
    # api/docs/security_architecture.md's layered rate-limiting guidance).

    def rate_limit!(bucket_key)
      return if ENV["RACK_ENV"] == "test"

      key = "#{request.ip}:#{bucket_key}"
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      RATE_LIMIT_MUTEX.synchronize do
        # Drop buckets whose newest entry has aged out, so the hash doesn't
        # grow unboundedly with one key per (ip, path) ever seen.
        RATE_LIMIT_BUCKETS.delete_if { |_, ts| ts.empty? || now - ts.last > RATE_LIMIT_WINDOW_SECONDS }
        timestamps = (RATE_LIMIT_BUCKETS[key] ||= [])
        timestamps.reject! { |t| now - t > RATE_LIMIT_WINDOW_SECONDS }
        halt_json(:too_many_requests, "Too many requests, try again later") if timestamps.length >= RATE_LIMIT_MAX_REQUESTS
        timestamps << now
      end
    end

    # -- Passkey registration and login ------------------------------------

    def normalize_email(value)
      return nil if value.nil?
      email = value.to_s.strip
      return nil if email.empty?
      halt_json(:bad_request, "Email is not valid") unless email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
      email.downcase
    end

    def display_name_for(user)
      user.email || "Left Wordle Player"
    end

    def register_begin_response
      payload = request_payload
      raw_link_token = payload["device_link_token"]

      if raw_link_token
        token = redeem_device_link_token(raw_link_token)
        halt_json(:bad_request, "This device-link code has expired or already been used") unless token
        user = token.user
        device_link_token_digest = token.token_digest
      else
        begin
          user = User.create(email: normalize_email(payload["email"]))
        rescue Sequel::UniqueConstraintViolation
          halt_json(:conflict, "Email already in use")
        end
        device_link_token_digest = nil
      end

      options = WebAuthn::Credential.options_for_create(
        user: {id: user.webauthn_user_id, name: display_name_for(user), display_name: display_name_for(user)},
        # Only exclude active credentials -- a revoked physical key should be
        # re-registrable, not permanently blocked.
        exclude: user.passkey_credentials_dataset.where(revoked_at: nil).select_map(:external_id),
        # Accounts are anonymous by default, so login (login_begin_response)
        # uses the usernameless/discoverable-credential flow -- that only
        # works if the credential was created as discoverable in the first
        # place, which requires explicitly requesting a resident key here.
        authenticator_selection: {resident_key: "required", user_verification: "preferred"}
      )

      issue_pending_ceremony!(
        purpose: "register",
        challenge: options.challenge,
        user_id: user.id,
        device_link_token_digest: device_link_token_digest
      )

      json_response({options: options.as_json})
    end

    def register_finish_response
      payload = request_payload
      pending = consume_pending_ceremony!(purpose: "register")
      user = User[pending["user_id"]]
      halt_json(:bad_request, "Passkey ceremony expired or invalid") unless user

      credential = verify_new_credential!(payload["credential"], pending["challenge"])

      joined_existing_account = !pending["device_link_token_digest"].nil?
      if joined_existing_account
        token = DeviceLinkToken.first(token_digest: pending["device_link_token_digest"])
        halt_json(:bad_request, "This device-link code has expired or already been used") unless token&.redeemable?
        unless consume_device_link_token!(token)
          halt_json(:bad_request, "This device-link code has expired or already been used")
        end
      end

      PasskeyCredential.create(
        user_id: user.id,
        external_id: credential.id,
        public_key: credential.public_key,
        sign_count: credential.sign_count || 0,
        nickname: payload["nickname"],
        last_used_at: Sequel::CURRENT_TIMESTAMP
      )

      issue_session_cookie!(user, extract_client_device_id)

      json_response({
        user_id: user.id,
        email: user.email,
        joined_existing_account: joined_existing_account,
        csrf_token: current_csrf_token
      }, status: :created)
    end

    def verify_new_credential!(credential_payload, expected_challenge)
      halt_json(:bad_request, "credential is required") unless credential_payload.is_a?(Hash)
      result = WebAuthn::Credential.from_create(credential_payload)
      result.verify(expected_challenge)
      result
    rescue WebAuthn::Error => e
      halt_json(:bad_request, "Passkey registration failed: #{e.message}")
    end

    def login_begin_response
      options = WebAuthn::Credential.options_for_get(allow: [])
      issue_pending_ceremony!(purpose: "login", challenge: options.challenge)
      json_response({options: options.as_json})
    end

    def login_finish_response
      payload = request_payload
      pending = consume_pending_ceremony!(purpose: "login")
      credential_payload = payload["credential"]
      halt_json(:bad_request, "credential is required") unless credential_payload.is_a?(Hash)

      stored = PasskeyCredential.first(external_id: credential_payload["id"])
      halt_json(:unauthorized, "Not authorized") unless stored&.active?

      result = verify_assertion!(credential_payload, pending["challenge"], stored)

      stored.update(sign_count: result.sign_count || stored.sign_count, last_used_at: Sequel::CURRENT_TIMESTAMP)
      user = stored.user
      issue_session_cookie!(user, extract_client_device_id)

      json_response({user_id: user.id, email: user.email, csrf_token: current_csrf_token})
    end

    def verify_assertion!(credential_payload, expected_challenge, stored_credential)
      result = WebAuthn::Credential.from_get(credential_payload)
      result.verify(expected_challenge, public_key: stored_credential.public_key, sign_count: stored_credential.sign_count)
      result
    rescue WebAuthn::Error
      halt_json(:unauthorized, "Not authorized")
    end

    def logout_response
      require_authenticated_user!
      clear_session_cookie!
      json_response({status: "logged_out"})
    end

    def device_link_response
      user = require_authenticated_user!
      require_csrf!
      payload = request_payload
      delivery = payload["delivery"].to_s
      halt_json(:bad_request, "delivery must be qr or email") unless %w[qr email].include?(delivery)

      if delivery == "email"
        halt_json(:bad_request, "Add an email to your account first") if user.email.to_s.strip.empty?
        halt_json(:service_unavailable, "Email is not configured") unless smtp_configured?
      end

      raw_token, token = issue_device_link_token_for!(user, delivery)
      link_url = "#{settings.wordle_base_url}/?link_token=#{raw_token}"

      if delivery == "qr"
        json_response({delivery: "qr", url: link_url, expires_at: token.expires_at.iso8601})
      else
        send_device_link_email(user.email, link_url)
        json_response({delivery: "email", status: "sent", expires_at: token.expires_at.iso8601})
      end
    end

    def send_device_link_email(to_email, link_url)
      from_addr = settings.smtp_from.to_s.strip
      from_addr = settings.smtp_username.to_s.strip if from_addr.empty?
      ttl = settings.device_link_token_ttl_minutes

      mail = Mail.new
      mail.from = from_addr
      mail.to = to_email
      mail.subject = "Add this device to your Left Wordle account"
      mail.body = "Open this link on the device you want to add:\n\n#{link_url}\n\n" \
        "This link expires in #{ttl} minutes and can only be used once."

      if ENV["RACK_ENV"] == "test"
        mail.delivery_method :test
      else
        mail.delivery_method :smtp, {
          address: "smtp.fastmail.com",
          port: 587,
          user_name: settings.smtp_username.to_s.strip,
          password: settings.smtp_password.to_s.strip,
          authentication: :login,
          enable_starttls_auto: true
        }
      end

      mail.deliver!
    end

    # Unauthenticated on purpose -- this is the only way back into an
    # account once every device with a passkey is lost. Always responds
    # identically whether or not the email matches an account, so the
    # endpoint can't be used to discover which emails have accounts.
    def recover_response
      halt_json(:service_unavailable, "Email is not configured") unless smtp_configured?
      payload = request_payload
      email = normalize_email(payload["email"])
      halt_json(:bad_request, "Email is required") unless email

      user = User.first(email: email)
      if user
        raw_token, = issue_device_link_token_for!(user, "email")
        link_url = "#{settings.wordle_base_url}/?link_token=#{raw_token}"
        send_recovery_email(user.email, link_url)
      end

      json_response({status: "sent"})
    end

    def send_recovery_email(to_email, link_url)
      from_addr = settings.smtp_from.to_s.strip
      from_addr = settings.smtp_username.to_s.strip if from_addr.empty?
      ttl = settings.device_link_token_ttl_minutes

      mail = Mail.new
      mail.from = from_addr
      mail.to = to_email
      mail.subject = "Recover access to your Left Wordle account"
      mail.body = "Open this link on the device you want to use:\n\n#{link_url}\n\n" \
        "This link expires in #{ttl} minutes and can only be used once. If you didn't " \
        "request this, you can safely ignore this email."

      if ENV["RACK_ENV"] == "test"
        mail.delivery_method :test
      else
        mail.delivery_method :smtp, {
          address: "smtp.fastmail.com",
          port: 587,
          user_name: settings.smtp_username.to_s.strip,
          password: settings.smtp_password.to_s.strip,
          authentication: :login,
          enable_starttls_auto: true
        }
      end

      mail.deliver!
    end

    def patch_email_response
      user = require_authenticated_user!
      require_csrf!
      payload = request_payload
      email = normalize_email(payload["email"])
      halt_json(:bad_request, "Email is required") unless email

      begin
        user.update(email: email, email_verified_at: nil)
      rescue Sequel::UniqueConstraintViolation
        halt_json(:conflict, "Email already in use")
      end

      json_response({email: user.email})
    end

    def passkeys_list_response
      user = require_authenticated_user!
      passkeys = user.passkey_credentials_dataset.where(revoked_at: nil).order(:created_at).all
      json_response({
        passkeys: passkeys.map { |pk|
          {id: pk.id, nickname: pk.nickname, created_at: pk.created_at.iso8601, last_used_at: pk.last_used_at&.iso8601}
        }
      })
    end

    def passkey_revoke_response
      user = require_authenticated_user!
      require_csrf!
      passkey = PasskeyCredential.first(id: params[:id], user_id: user.id)
      halt_json(:not_found, "Passkey not found") unless passkey
      return json_response({status: "revoked"}) unless passkey.active?

      # Revoking the last passkey is only allowed when the account has an
      # email, so /api/v2/auth/recover can still get the user back in.
      active_count = user.passkey_credentials_dataset.where(revoked_at: nil).count
      if active_count <= 1 && user.email.to_s.strip.empty?
        halt_json(:bad_request, "This is your only Passkey — add another device or set an email before removing it")
      end

      passkey.update(revoked_at: Sequel::CURRENT_TIMESTAMP)
      json_response({status: "revoked"})
    end

    # -- Profile (preferences / game_state / statistics) ---------------------

    def find_or_create_profile(user)
      UserProfile.first(user_id: user.id) || UserProfile.create(user_id: user.id)
    end

    # Debug/audit trail of what got written into the client's local storage
    # and when -- see storage_snapshots migration for the pruning rationale.
    def record_storage_snapshot!(user, event, local_storage)
      StorageSnapshot.create(
        user_id: user.id,
        client_device_id: extract_client_device_id,
        event: event,
        local_storage: Sequel.pg_json(local_storage)
      )
    end

    def profile_get_response
      user = require_authenticated_user!
      profile = user.user_profile
      data = {
        preferences: profile&.preferences || {},
        game_state: profile&.game_state || {},
        statistics: profile&.statistics || {}
      }
      record_storage_snapshot!(user, "update client local storage", data)

      json_response(data.merge(email: user.email, csrf_token: current_csrf_token))
    end

    # Client-initiated counterpart to record_storage_snapshot! above --
    # currently only used at brand-new registration, to capture the client's
    # pristine local storage before any server-side migration writes touch
    # the account (see migration_rethink.md's Initial Registration section).
    # Audit-trail only: this is never treated as a source of truth for
    # preferences/game_state/statistics, which each have their own explicit
    # push path.
    def local_storage_snapshot_response
      user = require_authenticated_user!
      require_csrf!
      payload = request_payload
      event = payload["event"].to_s
      unless CLIENT_SNAPSHOT_EVENTS.include?(event)
        halt_json(:bad_request, "event must be one of: #{CLIENT_SNAPSHOT_EVENTS.join(", ")}")
      end
      local_storage = payload["local_storage"]
      halt_json(:bad_request, "local_storage must be a JSON object") unless local_storage.is_a?(Hash)

      record_storage_snapshot!(user, event, local_storage)
      json_response({status: "ok"})
    end

    def put_preferences_response
      user = require_authenticated_user!
      require_csrf!
      find_or_create_profile(user).update(preferences: Sequel.pg_json(request_payload))
      json_response({status: "ok"})
    end

    def put_game_state_response
      user = require_authenticated_user!
      require_csrf!
      find_or_create_profile(user).update(game_state: Sequel.pg_json(request_payload))
      json_response({status: "ok"})
    end

    def stats_adjust_response
      user = require_authenticated_user!
      require_csrf!
      request = request_payload

      payload = request["statistics"]
      halt_json(:bad_request, "statistics must be an object") unless payload.is_a?(Hash)

      source = request["source"].to_s
      unless STATS_ADJUSTMENT_SOURCES.include?(source)
        halt_json(:bad_request, "source must be one of: #{STATS_ADJUSTMENT_SOURCES.join(", ")}")
      end

      profile = find_or_create_profile(user)
      before_stats = profile.statistics || {}

      # currentStreakAnchorPuzzleNum is pure server bookkeeping for
      # apply_played_game_to_statistics!'s gap check -- the client has no
      # concept of it and never sends one. Force it through from whatever
      # we already had rather than letting a client-submitted blob (which
      # necessarily omits it) silently clear it, which would let the very
      # next played game apply as if this were a brand new profile.
      payload["currentStreakAnchorPuzzleNum"] = before_stats["currentStreakAnchorPuzzleNum"]

      DB.transaction do
        StatsAdjustment.create(user_id: user.id, before: Sequel.pg_json(before_stats), after: Sequel.pg_json(payload), source: source)
        profile.update(statistics: Sequel.pg_json(payload))
      end

      json_response({status: "ok", statistics: profile.statistics})
    end

    # -- History (server-side played_games for the logged-in user) -----------

    def history_get_response
      user = require_authenticated_user!
      rows = PlayedGame.where(user_id: user.id).order(:created_at, :id).all
      json_response(history_hash_for(rows))
    end

    # Rows are expected in ascending created_at (server-arrival) order --
    # first arrival wins on a puzzle_num collision between devices, so once a
    # key is set here it's never overwritten. See
    # canonical_played_game_for/CANONICALIZATION in the stats section below.
    def history_hash_for(rows)
      rows.each_with_object({}) do |row, hash|
        key = row.puzzle_num.to_s
        next if hash.key?(key)
        hash[key] = {
          puzzle_num: row.puzzle_num,
          date: row.date.iso8601,
          mode: row.mode,
          game_status: row.game_status,
          guesses: row.guesses,
          completed_at: row.completed_at&.iso8601
        }
      end
    end

    def history_import_response
      user = require_authenticated_user!
      require_csrf!
      entries = request_payload["history"]
      halt_json(:bad_request, "history must be an array") unless entries.is_a?(Array)
      halt_json(:payload_too_large, "Too many history entries") if entries.length > MAX_IMPORT_ENTRIES

      imported = 0
      skipped = 0
      stats_applied = 0
      stats_skip_reasons = Hash.new(0)

      entries.each do |entry|
        result = import_history_row!(user, entry)
        if result[:row] == :imported
          imported += 1
        else
          skipped += 1
        end

        if result[:stats] == :applied
          stats_applied += 1
        elsif result[:stats]
          stats_skip_reasons[result[:stats].to_s] += 1
        end
      end

      json_response({
        imported: imported, skipped: skipped,
        stats_applied: stats_applied, stats_skip_reasons: stats_skip_reasons
      })
    end

    # entry shape (agreed client<->API contract): {puzzle_num, date, mode,
    # game_status ("WIN"/"FAIL", already translated by the client from its
    # own local result encoding), guesses (optional [word, pattern] pairs),
    # completed_at (optional), device_id (optional, the device it was
    # actually played on)}.
    #
    # Always attempts the (client_device_id, date)-scoped upsert, even if the
    # user already has a row for this puzzle_num from a different device --
    # every device's data is preserved (see migration_rethink.md's
    # preserve-information principle). row: :skipped here means no new row
    # was created for this device+date, not "this puzzle was already known"
    # -- whether the row counts toward stats is a separate question,
    # reported in stats: (nil when there's no completion to apply, :applied
    # when it moved the numbers, or apply_played_game_to_statistics!'s
    # no-op reason otherwise) so a sync response can explain itself instead
    # of requiring a database lookup to find out what happened.
    def import_history_row!(user, entry)
      return {row: :skipped, stats: nil} unless entry.is_a?(Hash)

      date = safe_date(entry["date"])
      puzzle_num = Integer(entry["puzzle_num"], exception: false)
      return {row: :skipped, stats: nil} unless date && puzzle_num

      client_device_id = valid_uuid?(entry["device_id"]) ? entry["device_id"] : extract_client_device_id
      return {row: :skipped, stats: nil} unless client_device_id

      mode = entry.fetch("mode", "regular").to_s
      mode = "regular" unless %w[regular hard insane].include?(mode)
      game_status = entry["game_status"].to_s
      game_status = nil unless %w[WIN FAIL].include?(game_status)
      guesses = entry["guesses"].is_a?(Array) ? entry["guesses"] : []
      completed_at = safe_time(entry["completed_at"])

      is_new_row = PlayedGame.where(client_device_id: client_device_id, date: date).empty?

      DB[:played_games].insert_conflict(
        target: [:client_device_id, :date],
        update: {
          user_id: Sequel[:excluded][:user_id],
          puzzle_num: Sequel[:excluded][:puzzle_num],
          mode: Sequel[:excluded][:mode],
          game_status: Sequel.function(:coalesce, Sequel[:played_games][:game_status], Sequel[:excluded][:game_status]),
          guesses: Sequel.function(:coalesce, Sequel[:played_games][:guesses], Sequel[:excluded][:guesses]),
          completed_at: Sequel.function(:coalesce, Sequel[:played_games][:completed_at], Sequel[:excluded][:completed_at])
        }
      ).insert(
        user_id: user.id, client_device_id: client_device_id, date: date, puzzle_num: puzzle_num,
        mode: mode, game_status: game_status, guesses: Sequel.pg_json(guesses),
        completed_at: completed_at, updated_at: Sequel::CURRENT_TIMESTAMP
      )

      stats = game_status ? apply_played_game_to_statistics!(user, puzzle_num, game_status) : nil
      {row: (is_new_row ? :imported : :skipped), stats: stats}
    rescue Sequel::DatabaseError
      {row: :skipped, stats: nil}
    end

    # -- Stats/streak derivation (server-authoritative, event-driven) --------
    #
    # Statistics are never trusted as a client-pushed blob (see
    # migration_rethink.md -- a prior full-recompute-from-history approach
    # caused real data loss, and a full-blob push from one device silently
    # clobbers another device's progress). Instead every played_games row --
    # whether it arrived via live play or a history import/backfill -- is
    # applied here as a single incremental event.
    #
    # currentStreakAnchorPuzzleNum tracks the last puzzle_num already
    # reflected in the numbers. A row only moves the numbers if it's the
    # canonical (earliest server-arrival) row for its puzzle_num AND its
    # puzzle_num is greater than the anchor. Anything at or behind the
    # anchor -- a losing duplicate, or a row landing behind it (older
    # backfill, out-of-order arrival) -- is archival only: it's preserved
    # in played_games/history but never changes stats, regardless of the
    # order events arrive in. A puzzle_num ahead of the anchor always
    # moves the numbers, but next_statistics_for only *continues* the
    # streak when it's exactly anchor + 1 -- anything further ahead is a
    # genuine gap and breaks it instead of leaving stats frozen forever.
    def canonical_played_game_for(user, puzzle_num)
      PlayedGame.where(user_id: user.id, puzzle_num: puzzle_num).order(:created_at, :id).first
    end

    # Returns why this event did or didn't move the numbers -- :applied,
    # :non_canonical (a losing duplicate, or this row's status lost to an
    # earlier-arriving one for the same puzzle_num), or :archival (at or
    # behind the anchor already) -- so callers can report it instead of
    # requiring a database lookup to reconstruct what happened.
    def apply_played_game_to_statistics!(user, puzzle_num, game_status)
      return :invalid unless user && %w[WIN FAIL].include?(game_status)

      DB.transaction do
        profile = UserProfile.where(user_id: user.id).for_update.first || find_or_create_profile(user)

        canonical = canonical_played_game_for(user, puzzle_num)
        next :non_canonical unless canonical && canonical.game_status == game_status

        stats = profile.statistics || {}
        anchor = stats["currentStreakAnchorPuzzleNum"]
        next :archival unless anchor.nil? || puzzle_num > anchor

        profile.update(statistics: Sequel.pg_json(next_statistics_for(stats, canonical, game_status, puzzle_num)))
        :applied
      end
    end

    def next_statistics_for(stats, canonical, game_status, puzzle_num)
      updated = stats.dup
      guesses = (stats["guesses"] || {}).dup
      updated["gamesPlayed"] = (stats["gamesPlayed"] || 0) + 1
      updated["gamesWon"] = stats["gamesWon"] || 0
      updated["maxStreak"] = stats["maxStreak"] || 0

      anchor = stats["currentStreakAnchorPuzzleNum"]
      is_continuation = anchor && puzzle_num == anchor + 1

      if game_status == "WIN"
        updated["currentStreak"] = is_continuation ? (stats["currentStreak"] || 0) + 1 : 1
        updated["maxStreak"] = [updated["maxStreak"], updated["currentStreak"]].max
        updated["gamesWon"] += 1

        # Imported/backfilled entries may not carry a guesses array (the
        # client's history-import payload doesn't include one) -- when that
        # guess count is unknown, still count the win, just skip the
        # per-guess-count histogram bucket for this row. canonical.guesses
        # comes back from Sequel's pg_json extension as a JSONBArray/
        # JSONArray wrapper (not a plain Array), so check for either.
        raw_guesses = canonical.guesses
        is_array = raw_guesses.is_a?(Array) || raw_guesses.is_a?(Sequel::Postgres::JSONArrayBase)
        guess_count = is_array ? raw_guesses.length : nil
        if guess_count && (1..6).cover?(guess_count)
          guesses[guess_count.to_s] = (guesses[guess_count.to_s] || 0) + 1
        end
      else
        updated["currentStreak"] = 0
        guesses["fail"] = (guesses["fail"] || 0) + 1
      end

      updated["guesses"] = guesses
      updated["currentStreakAnchorPuzzleNum"] = puzzle_num
      updated["winPercentage"] = updated["gamesPlayed"].positive? ? ((updated["gamesWon"].to_f / updated["gamesPlayed"]) * 100).round : 0

      guess_sum = (1..6).sum { |n| n * (guesses[n.to_s] || 0) }
      updated["averageGuesses"] = updated["gamesWon"].to_i.positive? ? (guess_sum.to_f / updated["gamesWon"] * 100).round / 100.0 : 0
      updated
    end

    def safe_date(value)
      return nil unless value.is_a?(String) && value.match?(DATE_PATTERN)
      Date.iso8601(value)
    rescue Date::Error
      nil
    end

    def safe_time(value)
      return nil unless value.is_a?(String) && !value.empty?
      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    def valid_uuid?(value)
      value.is_a?(String) && value.match?(CLIENT_DEVICE_ID_PATTERN)
    end

    def puzzle_response
      date = requested_date(params["date"])
      puzzle_number = LeftWordle::Game.puzzle_number_for(date)

      json_response({
        puzzle_num: puzzle_number,
        date: date.iso8601,
        word_length: LeftWordle::Game::WORD_LENGTH
      })
    end

    def request_payload
      body = request.body.read
      return {} if body.empty?

      payload = JSON.parse(body)
      halt_json(:bad_request, "Request body must be a JSON object") unless payload.is_a?(Hash)

      payload
    end

    def requested_date(value)
      halt_json(:bad_request, "Date is required") if value.nil?
      halt_json(:bad_request, "Date must use YYYY-MM-DD format") unless value.is_a?(String) && value.match?(DATE_PATTERN)

      date = Date.iso8601(value)
      latest_date = LeftWordle::Game.latest_available_date

      halt_json(:bad_request, "Date cannot be later than #{latest_date.iso8601}") if date > latest_date

      date
    rescue Date::Error
      halt_json(:bad_request, "Date must be a valid calendar date")
    end

    def row_index_from(payload)
      row_index = Integer(payload.fetch("row_index", 0))
      return row_index if row_index.between?(0, LeftWordle::Game::MAX_GUESSES - 1)

      halt_json(:bad_request, "Row index must be between 0 and #{LeftWordle::Game::MAX_GUESSES - 1}")
    rescue ArgumentError, TypeError
      halt_json(:bad_request, "Row index must be an integer")
    end

    def validate_request_origin!
      return if request.env["HTTP_SEC_FETCH_SITE"] == "same-origin"

      origin = request.env["HTTP_ORIGIN"]

      if origin
        halt_json(:forbidden, "Origin not allowed") unless settings.allowed_origins.include?(origin)
        return
      end

      auth = request.env["HTTP_AUTHORIZATION"]
      token = auth&.start_with?("Bearer ") ? auth.delete_prefix("Bearer ") : nil
      return if token && valid_api_token?(token)
      halt_json(:unauthorized, "Authorization required")
    end

    def valid_api_token?(token)
      return true if %w[development test].include?(ENV["RACK_ENV"]) && token == "1234"
      server_token = settings.server_api_token.to_s.strip
      server_token.length.positive? && token == server_token
    end

    # For operator-only endpoints: passing the origin check isn't enough
    # (any browser on an allowed origin does that) -- the server API token
    # itself is required.
    def require_server_api_token!
      auth = request.env["HTTP_AUTHORIZATION"]
      token = auth&.start_with?("Bearer ") ? auth.delete_prefix("Bearer ") : nil
      halt_json(:unauthorized, "Authorization required") unless token && valid_api_token?(token)
    end

    def guesser_protected!
      return if guesser_authorized?
      headers["WWW-Authenticate"] = 'Basic realm="Wordle Guesser"'
      halt 401, "Not authorized"
    end

    def guesser_authorized?
      auth = Rack::Auth::Basic::Request.new(request.env)
      return false unless auth.provided? && auth.basic? && auth.credentials
      username, password = auth.credentials
      !!GuesserUser.authenticate(username, password)
    end

    def guesser
      settings.engine.guesser
    end

    def g_halt(status_code, message)
      halt status_code, JSON.generate(error: message)
    end

    def g_json_body
      JSON.parse(request.body.read)
    end

    def g_legal_word?(word)
      word&.match?(/\A[A-Z]{5}\z/) && guesser.legal_words.include?(word)
    end

    def g_normalized_word(value)
      value.to_s.strip.upcase
    end

    def g_parse_pattern(value)
      string = value.to_s.strip
      return unless string.match?(/\A[012]{5}\z/)
      string.chars.map(&:to_i)
    end

    def g_turn_result(status, attempt:, remaining:, suggestions: [], answer: nil)
      JSON.generate(
        status:,
        attempt:,
        remaining:,
        remaining_count: remaining.length,
        possibilities: g_visible_possibilities(remaining),
        unused_possibilities: g_visible_unused_possibilities(remaining),
        suggestions:,
        answer:
      )
    end

    def g_visible_possibilities(words)
      (words.length <= 10) ? words : []
    end

    def g_visible_unused_possibilities(words)
      g_visible_possibilities(words) & guesser.unused
    end

    def g_evaluation_string(evaluation)
      map = {LeftWordle::Game::ABSENT => "0", LeftWordle::Game::PRESENT => "1", LeftWordle::Game::CORRECT => "2"}
      evaluation.map { |v| map[v] }.join
    end

    def validate_hard_mode!(guess, prev_guesses)
      return if prev_guesses.empty?

      last_word, last_mask = prev_guesses.last
      last_word = last_word.to_s.downcase
      last_mask = last_mask.to_s

      last_mask.each_char.with_index do |eval_char, i|
        if eval_char == "2" && guess[i] != last_word[i]
          halt_json(:bad_request, "#{ordinal(i + 1)} letter must be #{last_word[i].upcase}")
        end
      end

      required = Hash.new(0)
      last_mask.each_char.with_index do |eval_char, i|
        required[last_word[i]] += 1 if %w[1 2].include?(eval_char)
      end

      guess_counts = guess.chars.tally
      required.each do |letter, count|
        halt_json(:bad_request, "Guess must contain #{letter.upcase}") if (guess_counts[letter] || 0) < count
      end
    end

    def validate_insane_mode!(guess, prev_guesses)
      validate_hard_mode!(guess, prev_guesses)
      return if prev_guesses.empty?

      forbidden_positions = Hash.new { |h, k| h[k] = [] }
      known_absent = Set.new
      max_counts = {}

      prev_guesses.each do |word, mask|
        word = word.to_s.downcase
        mask = mask.to_s
        abs_count = Hash.new(0)
        pres_cor_count = Hash.new(0)

        mask.each_char.with_index do |eval_char, i|
          letter = word[i]
          case eval_char
          when "1"
            forbidden_positions[letter] << i
            pres_cor_count[letter] += 1
          when "2"
            pres_cor_count[letter] += 1
          when "0"
            abs_count[letter] += 1
          end
        end

        abs_count.each_key do |letter|
          if pres_cor_count[letter] == 0
            known_absent.add(letter)
          else
            max_allowed = pres_cor_count[letter]
            max_counts[letter] = [max_counts.fetch(letter, max_allowed), max_allowed].min
          end
        end
      end

      guess.each_char.with_index do |letter, i|
        if forbidden_positions[letter].include?(i)
          halt_json(:bad_request, "#{letter.upcase} can't be in #{ordinal(i + 1)} position")
        end
      end

      guess_counts = guess.chars.tally

      known_absent.each do |letter|
        halt_json(:bad_request, "Guess cannot contain #{letter.upcase}") if guess_counts[letter]
      end

      max_counts.each do |letter, max|
        halt_json(:bad_request, "Too many #{letter.upcase}s") if (guess_counts[letter] || 0) > max
      end
    end

    def ordinal(n)
      suffix = if [11, 12, 13].include?(n % 100)
        "th"
      else
        case n % 10
        when 1 then "st"
        when 2 then "nd"
        when 3 then "rd"
        else "th"
        end
      end
      "#{n}#{suffix}"
    end

    def answers_remaining_for(prev_guesses)
      remaining = LeftWordle::Game.all_answers
      prev_guesses.each do |pair|
        guess = pair[0].to_s.downcase
        pattern = pair[1].to_s
        next unless guess.match?(/\A[a-z]{5}\z/) && pattern.match?(/\A[012]{5}\z/)
        remaining = remaining.select { |candidate| g_evaluation_string(LeftWordle::Game.evaluate(guess, candidate)) == pattern }
      end
      remaining.length
    end

    def g_collect_param_warnings(query_params)
      warnings = []
      query_params.each do |key, value|
        next if key.downcase == "date"
        if key.downcase.include?("date")
          warnings << {type: "date_typo", key: key, value: value}
        else
          warnings << {type: "unknown", key: key, value: value}
        end
      end
      warnings
    end

    def g_validate_game_date(value)
      return [nil, nil] if value.nil?
      return [nil, "Date must use YYYY-MM-DD format"] unless value.is_a?(String) && value.match?(DATE_PATTERN)

      date = begin
        Date.iso8601(value)
      rescue Date::Error
        return [nil, "Date must be a valid calendar date"]
      end

      if date < LeftWordle::Game::PUZZLE_EPOCH
        return [nil, "Date cannot be before #{LeftWordle::Game::PUZZLE_EPOCH.iso8601} (puzzle start date)"]
      end

      last_puzzle_date = LeftWordle::Game::PUZZLE_EPOCH + LeftWordle::Game.all_answers.length - 1
      if date > last_puzzle_date
        return [nil, "Date cannot be after #{last_puzzle_date.iso8601} (end of answer list)"]
      end

      [value, nil]
    end

    def g_word_array(value)
      Array(value).filter_map do |word|
        normalized = g_normalized_word(word)
        normalized if normalized.match?(/\A[A-Z]{5}\z/)
      end
    end

    def legal_words_response
      json_response(LeftWordle::Game.all_valid_words.sort)
    end

    def answers_response
      json_response(LeftWordle::Game.all_answers.sort)
    end

    def prev_answers_response
      today = requested_date(params["date"])
      last_puzzle = LeftWordle::Game.puzzle_number_for(today - 1)

      records = (0..last_puzzle).map do |n|
        {
          puzzle_number: n,
          date: (LeftWordle::Game::PUZZLE_EPOCH + n).iso8601,
          word: LeftWordle::Game.answer_for(n)
        }
      end

      json_response(records)
    end
  end
end
