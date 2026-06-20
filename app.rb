# frozen_string_literal: true

require "bcrypt"
require "json"
require "sinatra/base"
require "yaml"

require_relative "lib/left_wordle/game"
require_relative "lib/guesser/solve_engine"

class LeftWordleApi < Sinatra::Base
  DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/

  set :root, File.expand_path(__dir__)
  enable :static

  configure do
    set :allowed_origins, ENV.fetch("CORS_ORIGINS", "").split(",").map(&:strip).reject(&:empty?).freeze
    set :protection, except: :json_csrf
    set :show_exceptions, false
  end

  set :engine, SolveEngine.new

  users_file = File.join(File.expand_path(__dir__), "users.yml")
  set :users, File.exist?(users_file) ? (YAML.load_file(users_file) || {}) : {}

  before do
    next if request.path.start_with?("/guesser")
    content_type :json
    validate_request_origin!
    headers cors_headers.merge("Cache-Control" => "no-store")
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

  post "/api/v1/game/guess" do
    guess_response
  end

  get "/guesser" do
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
        "Access-Control-Allow-Headers" => "Content-Type",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Vary" => "Origin"
      }

      headers["Access-Control-Allow-Origin"] = origin if settings.allowed_origins.include?(origin)
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

      if payload.key?("prev_guesses")
        all_guesses = Array(payload["prev_guesses"]) + [[guess, g_evaluation_string(evaluation)]]
        response[:answers_remaining] = answers_remaining_for(all_guesses)
      end

      json_response(response)
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
      origin = request.env["HTTP_ORIGIN"]
      return if origin.nil? || settings.allowed_origins.include?(origin)

      halt_json(:forbidden, "Origin not allowed")
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
      stored = settings.users[username]
      stored && BCrypt::Password.new(stored) == password
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

    def g_word_array(value)
      Array(value).filter_map do |word|
        normalized = g_normalized_word(word)
        normalized if normalized.match?(/\A[A-Z]{5}\z/)
      end
    end
  end
end
