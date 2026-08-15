# frozen_string_literal: true

require "securerandom"

require_relative "test_helper"

class AppTest < Minitest::Test
  include ApiTest

  def setup
    origins = ENV["CORS_ORIGINS"].to_s.split(",").map(&:strip).reject(&:empty?)
    LeftWordleApi.set :allowed_origins, origins.freeze
    header "Authorization", "Bearer 1234"
  end

  def teardown
    return unless @client_device_ids

    PlayedGame.where(client_device_id: @client_device_ids).delete
  end

  def test_get_health
    get "/api/v1/health"

    assert last_response.ok?
    assert_equal({"status" => "ok"}, json_response)
    assert_equal "no-store", last_response.headers.fetch("cache-control")
  end

  def test_get_version
    get "/api/v1/version"

    assert last_response.ok?
    body = json_response
    assert body.key?("commit")
    assert body.key?("release")
  end

  def test_get_puzzle_rejects_a_date_that_has_not_started_in_utc_plus_fourteen
    future_date = LeftWordle::Game.latest_available_date + 1

    get "/api/v1/game/puzzle", date: future_date.iso8601

    assert_equal 400, last_response.status
    assert_match(/cannot be later/, json_response.fetch("detail"))
  end

  def test_get_puzzle_rejects_a_non_iso_date
    get "/api/v1/game/puzzle", date: "2021-6-19"

    assert_equal 400, last_response.status
    assert_equal "Date must use YYYY-MM-DD format", json_response.fetch("detail")
  end

  def test_get_puzzle_rejects_an_invalid_calendar_date
    get "/api/v1/game/puzzle", date: "2026-02-30"

    assert_equal 400, last_response.status
    assert_equal "Date must be a valid calendar date", json_response.fetch("detail")
  end

  def test_get_puzzle_requires_a_date
    get "/api/v1/game/puzzle"

    assert_equal 400, last_response.status
    assert_equal "Date is required", json_response.fetch("detail")
  end

  def test_get_puzzle_returns_the_requested_past_puzzle
    get "/api/v1/game/puzzle", date: "2021-06-19"

    assert last_response.ok?
    assert_equal 0, json_response.fetch("puzzle_num")
    assert_equal "2021-06-19", json_response.fetch("date")
    assert_equal 5, json_response.fetch("word_length")
  end

  def test_options_echoes_an_allowed_origin
    options "/api/v1/game/guess", {}, {"HTTP_ORIGIN" => "https://left-wordle.example"}

    assert_equal 204, last_response.status
    assert_equal "https://left-wordle.example", last_response.headers.fetch("access-control-allow-origin")
    assert_equal "Origin", last_response.headers.fetch("vary")
    # DELETE (passkey revocation) must be preflight-allowed, or browsers
    # block the real request before it's ever sent.
    assert_includes last_response.headers.fetch("access-control-allow-methods"), "DELETE"
  end

  def test_request_rejects_an_unapproved_origin
    get "/api/v1/health", {}, {"HTTP_ORIGIN" => "https://unrelated.example"}

    assert_equal 403, last_response.status
    assert_equal "Origin not allowed", json_response.fetch("detail")
  end

  def test_origin_less_request_accepts_dev_bearer_token
    # setup already sets "Bearer 1234", which is always valid in test/development
    get "/api/v1/health"

    assert last_response.ok?
    refute last_response.headers.key?("access-control-allow-origin")
  end

  def test_same_origin_get_allowed_without_bearer_token
    header "Authorization", nil
    get "/api/v1/health", {}, {"HTTP_SEC_FETCH_SITE" => "same-origin"}

    assert last_response.ok?
  end

  def test_get_answer_returns_encrypted_answer_for_date
    date = "2021-06-19"
    get "/api/v1/game/answer", date: date

    assert last_response.ok?
    assert_equal "public, max-age=300, s-maxage=86400", last_response.headers.fetch("cache-control")
    body = json_response
    assert_equal date, body.fetch("date")
    assert_equal 0, body.fetch("puzzle_num")
    assert_match(/\A[0-9a-f]+\z/, body.fetch("encrypted_answer"))
    assert_equal answer_for(date), decrypt_answer(body.fetch("encrypted_answer"))
  end

  def test_get_answer_decrypted_word_is_five_letters
    get "/api/v1/game/answer", date: "2021-06-20"

    assert last_response.ok?
    assert_equal 5, decrypt_answer(json_response.fetch("encrypted_answer")).length
  end

  def test_get_answer_requires_a_date
    get "/api/v1/game/answer"

    assert_equal 400, last_response.status
    assert_equal "Date is required", json_response.fetch("detail")
  end

  def test_get_answer_rejects_a_non_iso_date
    get "/api/v1/game/answer", date: "2021-6-19"

    assert_equal 400, last_response.status
    assert_equal "Date must use YYYY-MM-DD format", json_response.fetch("detail")
  end

  def test_get_answer_rejects_an_invalid_calendar_date
    get "/api/v1/game/answer", date: "2026-02-30"

    assert_equal 400, last_response.status
    assert_equal "Date must be a valid calendar date", json_response.fetch("detail")
  end

  def test_get_answer_does_not_record_an_initiation_when_device_id_header_present
    @client_device_ids = [client_device_id = SecureRandom.uuid]

    get "/api/v1/game/answer", {date: "2021-06-19"}, {"HTTP_X_DEVICE_ID" => client_device_id, "HTTP_CF_IPCOUNTRY" => "US"}

    assert last_response.ok?
    assert_nil PlayedGame.first(client_device_id: client_device_id)
  end

  def test_post_start_records_an_initiation_when_device_id_header_present
    @client_device_ids = [client_device_id = SecureRandom.uuid]

    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 0}, {"HTTP_X_DEVICE_ID" => client_device_id, "HTTP_CF_IPCOUNTRY" => "US"}

    assert last_response.ok?
    assert_equal({"status" => "recorded"}, json_response)
    played_game = PlayedGame.first(client_device_id: client_device_id)
    refute_nil played_game
    assert_equal "US", played_game.country_code
    assert_equal Date.iso8601("2021-06-19"), played_game.date
    assert_equal 0, played_game.puzzle_num
    refute_nil played_game.initiated_at
    assert_nil played_game.completed_at
  end

  def test_post_start_returns_recorded_when_device_id_header_missing
    played_game_count_before = PlayedGame.count

    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 0}

    assert last_response.ok?
    assert_equal({"status" => "recorded"}, json_response)
    assert_equal played_game_count_before, PlayedGame.count
  end

  def test_post_start_is_a_noop_for_telemetry_when_device_id_header_is_malformed
    played_game_count_before = PlayedGame.count

    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 0}, {"HTTP_X_DEVICE_ID" => "not-a-uuid"}

    assert last_response.ok?
    assert_equal played_game_count_before, PlayedGame.count
  end

  def test_post_start_rejects_a_missing_puzzle_num
    post_json "/api/v1/game/start", {date: "2021-06-19"}

    assert_equal 400, last_response.status
    assert_equal "puzzle_num is required", json_response.fetch("detail")
  end

  def test_post_start_rejects_a_puzzle_num_that_does_not_match_the_date
    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 1}

    assert_equal 400, last_response.status
    assert_equal "puzzle_num must match date", json_response.fetch("detail")
  end

  def test_post_start_repeated_same_day_does_not_change_initiated_at
    @client_device_ids = [client_device_id = SecureRandom.uuid]
    request_env = {"HTTP_X_DEVICE_ID" => client_device_id}

    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 0}, request_env
    first_initiated_at = PlayedGame.first(client_device_id: client_device_id).initiated_at

    sleep 0.01
    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 0}, request_env
    second_initiated_at = PlayedGame.first(client_device_id: client_device_id).initiated_at

    assert_equal first_initiated_at, second_initiated_at
  end

  def test_post_start_missing_country_header_does_not_blank_existing_country_code
    @client_device_ids = [client_device_id = SecureRandom.uuid]

    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 0}, {"HTTP_X_DEVICE_ID" => client_device_id, "HTTP_CF_IPCOUNTRY" => "US"}
    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 0}, {"HTTP_X_DEVICE_ID" => client_device_id}

    assert_equal "US", PlayedGame.first(client_device_id: client_device_id).country_code
  end

  def test_post_complete_records_a_completion
    @client_device_ids = [client_device_id = SecureRandom.uuid]

    request_env = {"HTTP_X_DEVICE_ID" => client_device_id, "CONTENT_TYPE" => "application/json"}
    post "/api/v1/game/complete", JSON.generate(date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: [["train", "01000"], ["crane", "22222"]]), request_env

    assert last_response.ok?
    assert_equal({"status" => "recorded"}, json_response)

    played_game = PlayedGame.first(client_device_id: client_device_id)
    refute_nil played_game
    assert_equal "regular", played_game.mode
    assert_equal "WIN", played_game.game_status
    assert_equal [["train", "01000"], ["crane", "22222"]], played_game.guesses.to_a
    refute_nil played_game.completed_at
  end

  def test_post_complete_after_initiation_preserves_initiated_at_and_sets_completed_at
    @client_device_ids = [client_device_id = SecureRandom.uuid]
    request_env = {"HTTP_X_DEVICE_ID" => client_device_id}

    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 0}, request_env
    initiated_at = PlayedGame.first(client_device_id: client_device_id).initiated_at

    post "/api/v1/game/complete", JSON.generate(date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]]), request_env.merge("CONTENT_TYPE" => "application/json")

    played_game = PlayedGame.first(client_device_id: client_device_id)
    assert_equal initiated_at, played_game.initiated_at
    refute_nil played_game.completed_at
  end

  def test_post_start_after_completion_preserves_the_single_completed_game
    @client_device_ids = [client_device_id = SecureRandom.uuid]
    completion_env = {"HTTP_X_DEVICE_ID" => client_device_id, "HTTP_CF_IPCOUNTRY" => "US", "CONTENT_TYPE" => "application/json"}
    start_env = {"HTTP_X_DEVICE_ID" => client_device_id, "HTTP_CF_IPCOUNTRY" => "CA"}

    post "/api/v1/game/complete", JSON.generate(date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]]), completion_env
    completed_at = PlayedGame.first(client_device_id: client_device_id).completed_at

    sleep 0.01
    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 0}, start_env

    assert last_response.ok?
    assert_equal 1, PlayedGame.where(client_device_id: client_device_id, date: Date.iso8601("2021-06-19")).count

    played_game = PlayedGame.first(client_device_id: client_device_id)
    assert_equal completed_at, played_game.completed_at
    assert_equal completed_at, played_game.initiated_at
    assert_equal "US", played_game.country_code
    assert_equal "WIN", played_game.game_status
    assert_equal [["crane", "22222"]], played_game.guesses.to_a
  end

  def test_post_complete_carries_over_country_code_from_initiation_when_absent_at_completion
    @client_device_ids = [client_device_id = SecureRandom.uuid]

    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 0}, {"HTTP_X_DEVICE_ID" => client_device_id, "HTTP_CF_IPCOUNTRY" => "US"}
    post "/api/v1/game/complete", JSON.generate(date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]]), {"HTTP_X_DEVICE_ID" => client_device_id, "CONTENT_TYPE" => "application/json"}

    assert_equal "US", PlayedGame.first(client_device_id: client_device_id).country_code
  end

  def test_post_complete_updates_country_code_when_a_devices_country_changes_between_games
    @client_device_ids = [client_device_id = SecureRandom.uuid]

    post_json "/api/v1/game/start", {date: "2021-06-19", puzzle_num: 0}, {"HTTP_X_DEVICE_ID" => client_device_id, "HTTP_CF_IPCOUNTRY" => "US"}
    post "/api/v1/game/complete", JSON.generate(date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]]), {"HTTP_X_DEVICE_ID" => client_device_id, "CONTENT_TYPE" => "application/json"}

    post_json "/api/v1/game/start", {date: "2021-06-20", puzzle_num: 1}, {"HTTP_X_DEVICE_ID" => client_device_id, "HTTP_CF_IPCOUNTRY" => "CA"}

    assert_equal "US", PlayedGame.first(client_device_id: client_device_id, date: Date.iso8601("2021-06-19")).country_code
    assert_equal "CA", PlayedGame.first(client_device_id: client_device_id, date: Date.iso8601("2021-06-20")).country_code
  end

  def test_post_complete_rejects_guesses_that_is_not_an_array
    post_json "/api/v1/game/complete", {date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: "nope"}

    assert_equal 400, last_response.status
    assert_match(/non-empty array/, json_response.fetch("detail"))
  end

  def test_post_complete_rejects_empty_guesses
    post_json "/api/v1/game/complete", {date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: []}

    assert_equal 400, last_response.status
    assert_match(/non-empty array/, json_response.fetch("detail"))
  end

  def test_post_complete_rejects_malformed_guess_pair
    post_json "/api/v1/game/complete", {date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: [["train", "999"]]}

    assert_equal 400, last_response.status
    assert_match(/non-empty array/, json_response.fetch("detail"))
  end

  def test_post_complete_rejects_more_than_max_guesses
    guesses = Array.new(LeftWordle::Game::MAX_GUESSES + 1) { ["crane", "00000"] }
    post_json "/api/v1/game/complete", {date: "2021-06-19", mode: "regular", game_status: "FAIL", guesses: guesses}

    assert_equal 400, last_response.status
    assert_match(/cannot have more than/, json_response.fetch("detail"))
  end

  def test_post_complete_rejects_invalid_mode
    post_json "/api/v1/game/complete", {date: "2021-06-19", mode: "bogus", game_status: "WIN", guesses: [["crane", "22222"]]}

    assert_equal 400, last_response.status
    assert_match(/Mode must be/, json_response.fetch("detail"))
  end

  def test_post_complete_rejects_invalid_game_status
    post_json "/api/v1/game/complete", {date: "2021-06-19", mode: "regular", game_status: "PLAYING", guesses: [["crane", "22222"]]}

    assert_equal 400, last_response.status
    assert_match(/game_status must be/, json_response.fetch("detail"))
  end

  def test_post_complete_returns_recorded_even_without_device_id_header
    post_json "/api/v1/game/complete", {date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]]}

    assert last_response.ok?
    assert_equal({"status" => "recorded"}, json_response)
  end

  def test_post_complete_is_idempotent_on_retry
    @client_device_ids = [client_device_id = SecureRandom.uuid]
    request_env = {"HTTP_X_DEVICE_ID" => client_device_id, "CONTENT_TYPE" => "application/json"}
    body = JSON.generate(date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]])

    post "/api/v1/game/complete", body, request_env
    post "/api/v1/game/complete", body, request_env

    assert_equal 1, PlayedGame.where(client_device_id: client_device_id).count
  end

  def test_post_progress_records_an_in_progress_game_with_no_status_or_completed_at
    @client_device_ids = [client_device_id = SecureRandom.uuid]
    request_env = {"HTTP_X_DEVICE_ID" => client_device_id, "CONTENT_TYPE" => "application/json"}
    post "/api/v1/game/progress", JSON.generate(date: "2021-06-19", mode: "regular", guesses: [["train", "01000"]]), request_env

    assert last_response.ok?
    assert_equal({"status" => "recorded"}, json_response)

    played_game = PlayedGame.first(client_device_id: client_device_id)
    refute_nil played_game
    assert_equal [["train", "01000"]], played_game.guesses.to_a
    assert_nil played_game.game_status
    assert_nil played_game.completed_at
  end

  def test_post_progress_allows_empty_guesses
    @client_device_ids = [client_device_id = SecureRandom.uuid]
    post_json "/api/v1/game/progress", {date: "2021-06-19", mode: "regular", guesses: []}, {"HTTP_X_DEVICE_ID" => client_device_id}

    assert last_response.ok?
    assert_equal [], PlayedGame.first(client_device_id: client_device_id).guesses.to_a
  end

  def test_post_progress_rejects_malformed_guess_pair
    post_json "/api/v1/game/progress", {date: "2021-06-19", mode: "regular", guesses: [["train", "999"]]}

    assert_equal 400, last_response.status
    assert_match(/word, pattern/, json_response.fetch("detail"))
  end

  def test_post_progress_rejects_more_than_max_guesses
    guesses = Array.new(LeftWordle::Game::MAX_GUESSES + 1) { ["crane", "00000"] }
    post_json "/api/v1/game/progress", {date: "2021-06-19", mode: "regular", guesses: guesses}

    assert_equal 400, last_response.status
    assert_match(/cannot have more than/, json_response.fetch("detail"))
  end

  def test_post_progress_rejects_invalid_mode
    post_json "/api/v1/game/progress", {date: "2021-06-19", mode: "bogus", guesses: [["crane", "22222"]]}

    assert_equal 400, last_response.status
    assert_match(/Mode must be/, json_response.fetch("detail"))
  end

  def test_post_progress_is_idempotent_and_updates_guesses_in_place
    @client_device_ids = [client_device_id = SecureRandom.uuid]
    request_env = {"HTTP_X_DEVICE_ID" => client_device_id, "CONTENT_TYPE" => "application/json"}

    post "/api/v1/game/progress", JSON.generate(date: "2021-06-19", mode: "regular", guesses: [["train", "01000"]]), request_env
    post "/api/v1/game/progress", JSON.generate(date: "2021-06-19", mode: "regular", guesses: [["train", "01000"], ["crane", "22222"]]), request_env

    assert_equal 1, PlayedGame.where(client_device_id: client_device_id).count
    assert_equal [["train", "01000"], ["crane", "22222"]], PlayedGame.first(client_device_id: client_device_id).guesses.to_a
  end

  def test_post_progress_after_completion_does_not_clobber_game_status_or_completed_at
    @client_device_ids = [client_device_id = SecureRandom.uuid]
    request_env = {"HTTP_X_DEVICE_ID" => client_device_id, "CONTENT_TYPE" => "application/json"}

    post "/api/v1/game/complete", JSON.generate(date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]]), request_env
    completed_at = PlayedGame.first(client_device_id: client_device_id).completed_at

    # A lagging progress retry landing after completion (e.g. a slow
    # network) must not resurrect the row as "in progress".
    post "/api/v1/game/progress", JSON.generate(date: "2021-06-19", mode: "regular", guesses: [["train", "01000"]]), request_env

    played_game = PlayedGame.first(client_device_id: client_device_id)
    assert_equal "WIN", played_game.game_status
    assert_equal completed_at, played_game.completed_at
  end

  def test_post_complete_after_progress_sets_status_and_completed_at
    @client_device_ids = [client_device_id = SecureRandom.uuid]
    request_env = {"HTTP_X_DEVICE_ID" => client_device_id, "CONTENT_TYPE" => "application/json"}

    post "/api/v1/game/progress", JSON.generate(date: "2021-06-19", mode: "regular", guesses: [["train", "01000"]]), request_env
    post "/api/v1/game/complete", JSON.generate(date: "2021-06-19", mode: "regular", game_status: "WIN", guesses: [["train", "01000"], ["crane", "22222"]]), request_env

    played_game = PlayedGame.first(client_device_id: client_device_id)
    assert_equal "WIN", played_game.game_status
    refute_nil played_game.completed_at
    assert_equal [["train", "01000"], ["crane", "22222"]], played_game.guesses.to_a
  end

  def test_post_progress_returns_recorded_even_without_device_id_header
    post_json "/api/v1/game/progress", {date: "2021-06-19", mode: "regular", guesses: [["crane", "22222"]]}

    assert last_response.ok?
    assert_equal({"status" => "recorded"}, json_response)
  end

  def test_get_answer_rejects_a_future_date
    future_date = LeftWordle::Game.latest_available_date + 1
    get "/api/v1/game/answer", date: future_date.iso8601

    assert_equal 400, last_response.status
    assert_match(/cannot be later/, json_response.fetch("detail"))
  end

  def test_post_remaining_counts_returns_counts_for_each_guess
    date = "2021-06-19"
    answer = answer_for(date)
    guesses = [["crane", evaluation_string(LeftWordle::Game.evaluate("crane", answer))]]

    post_json "/api/v1/game/remaining_counts", {date: date, guesses: guesses}

    assert last_response.ok?
    body = json_response
    assert_equal date, body.fetch("date")
    counts = body.fetch("remaining_counts")
    assert_equal 1, counts.length
    assert_kind_of Integer, counts[0]
    assert counts[0] >= 0
  end

  def test_post_remaining_counts_is_cumulative
    date = "2021-06-19"
    answer = answer_for(date)
    g1 = ["crane", evaluation_string(LeftWordle::Game.evaluate("crane", answer))]
    g2 = ["slate", evaluation_string(LeftWordle::Game.evaluate("slate", answer))]

    post_json "/api/v1/game/remaining_counts", {date: date, guesses: [g1, g2]}

    assert last_response.ok?
    counts = json_response.fetch("remaining_counts")
    assert_equal 2, counts.length
    assert counts[1] <= counts[0], "second count should be <= first count"
  end

  def test_post_remaining_counts_returns_zero_for_winning_guess
    date = "2021-06-19"
    answer = answer_for(date)
    winning_guess = [answer, "22222"]

    post_json "/api/v1/game/remaining_counts", {date: date, guesses: [winning_guess]}

    assert last_response.ok?
    assert_equal [0], json_response.fetch("remaining_counts")
  end

  def test_post_remaining_counts_returns_zero_for_winning_guess_in_sequence
    date = "2021-06-19"
    answer = answer_for(date)
    g1 = ["crane", evaluation_string(LeftWordle::Game.evaluate("crane", answer))]
    winning = [answer, "22222"]

    post_json "/api/v1/game/remaining_counts", {date: date, guesses: [g1, winning]}

    assert last_response.ok?
    counts = json_response.fetch("remaining_counts")
    assert_equal 2, counts.length
    assert counts[0] > 0, "non-winning guess should have positive count"
    assert_equal 0, counts[1]
  end

  def test_post_remaining_counts_returns_empty_array_for_no_guesses
    post_json "/api/v1/game/remaining_counts", {date: "2021-06-19", guesses: []}

    assert last_response.ok?
    assert_equal [], json_response.fetch("remaining_counts")
  end

  def test_post_remaining_counts_requires_a_date
    post_json "/api/v1/game/remaining_counts", {guesses: []}

    assert_equal 400, last_response.status
    assert_equal "Date is required", json_response.fetch("detail")
  end

  def test_post_remaining_counts_rejects_guesses_that_is_not_an_array
    post_json "/api/v1/game/remaining_counts", {date: "2021-06-19", guesses: "bad"}

    assert_equal 400, last_response.status
    assert_equal "guesses must be an array of [word, pattern] pairs", json_response.fetch("detail")
  end

  def test_post_remaining_counts_rejects_malformed_pair
    post_json "/api/v1/game/remaining_counts", {date: "2021-06-19", guesses: [["crane"]]}

    assert_equal 400, last_response.status
    assert_equal "guesses must be an array of [word, pattern] pairs", json_response.fetch("detail")
  end

  def test_post_remaining_counts_rejects_invalid_pattern
    post_json "/api/v1/game/remaining_counts", {date: "2021-06-19", guesses: [["crane", "xyz99"]]}

    assert_equal 400, last_response.status
    assert_equal "guesses must be an array of [word, pattern] pairs", json_response.fetch("detail")
  end

  def test_post_remaining_counts_rejects_more_than_max_guesses
    guesses = Array.new(LeftWordle::Game::MAX_GUESSES + 1) { ["crane", "00000"] }
    post_json "/api/v1/game/remaining_counts", {date: "2021-06-19", guesses: guesses}

    assert_equal 400, last_response.status
    assert_match(/cannot have more than/, json_response.fetch("detail"))
  end

  def test_post_guess_rejects_invalid_json
    post "/api/v1/game/guess", "{", {"CONTENT_TYPE" => "application/json"}

    assert_equal 400, last_response.status
    assert_equal "Request body must be valid JSON", json_response.fetch("detail")
  end

  def test_post_guess_rejects_invalid_row_index
    date = "2021-06-19"
    answer = answer_for(date)

    post_json "/api/v1/game/guess", {date: date, guess: answer, row_index: 6}

    assert_equal 400, last_response.status
    assert_match(/Row index/, json_response.fetch("detail"))
  end

  def test_post_guess_rejects_json_that_is_not_an_object
    post "/api/v1/game/guess", "[]", {"CONTENT_TYPE" => "application/json"}

    assert_equal 400, last_response.status
    assert_equal "Request body must be a JSON object", json_response.fetch("detail")
  end

  def test_post_guess_rejects_unknown_word
    post_json "/api/v1/game/guess", {date: "2021-06-19", guess: "zxqvw", row_index: 0}

    assert_equal 400, last_response.status
    assert_equal "Not in word list", json_response.fetch("detail")
  end

  def test_post_guess_requires_a_date
    post_json "/api/v1/game/guess", {guess: "cigar", row_index: 0}

    assert_equal 400, last_response.status
    assert_equal "Date is required", json_response.fetch("detail")
  end

  def test_post_guess_returns_fail_and_solution_on_last_row
    date = "2021-06-19"
    answer = answer_for(date)
    wrong_guess = LeftWordle::Game.all_answers.find { |word| word != answer }

    post_json "/api/v1/game/guess", {date: date, guess: wrong_guess, row_index: 5}

    assert last_response.ok?
    assert_equal date, json_response.fetch("date")
    assert_equal "FAIL", json_response.fetch("game_status")
    assert_equal 0, json_response.fetch("puzzle_num")
    assert_equal answer, json_response.fetch("solution")
  end

  def test_post_guess_returns_win_and_solution_for_the_requested_date
    date = "2021-06-20"
    answer = answer_for(date)

    post_json "/api/v1/game/guess", {date: date, guess: answer, row_index: 0}

    assert last_response.ok?
    assert_equal date, json_response.fetch("date")
    assert_equal "22222", json_response.fetch("evaluation")
    assert_equal "WIN", json_response.fetch("game_status")
    assert_equal 1, json_response.fetch("puzzle_num")
    assert_equal 1, json_response.fetch("guess_number")
    assert_equal answer, json_response.fetch("solution")
  end

  def test_post_guess_omits_answers_remaining_without_return_remaining_count
    post_json "/api/v1/game/guess", {date: "2021-06-19", guess: "crane", row_index: 0}

    assert last_response.ok?
    refute json_response.key?("answers_remaining")
  end

  def test_post_guess_returns_count_after_current_guess_for_empty_prev_guesses
    date = "2021-06-19"
    answer = answer_for(date)

    post_json "/api/v1/game/guess", {date: date, guess: "crane", row_index: 0, prev_guesses: [], return_remaining_count: true}

    assert last_response.ok?
    # answers_remaining reflects answers left after the current guess (not just prev_guesses)
    expected = answers_remaining_count([["crane", answer]])
    assert_equal expected, json_response.fetch("answers_remaining")
  end

  def test_post_guess_returns_zero_answers_remaining_for_winning_guess
    date = "2021-06-19"
    answer = answer_for(date)

    post_json "/api/v1/game/guess", {date: date, guess: answer, row_index: 0, prev_guesses: [], return_remaining_count: true}

    assert last_response.ok?
    assert_equal "WIN", json_response.fetch("game_status")
    assert_equal 0, json_response.fetch("answers_remaining")
  end

  def test_post_guess_rejects_more_than_max_prev_guesses
    prev_guesses = Array.new(LeftWordle::Game::MAX_GUESSES + 1) { ["crane", "00000"] }
    post_json "/api/v1/game/guess", {date: "2021-06-19", guess: "crane", row_index: 0, prev_guesses: prev_guesses}

    assert_equal 400, last_response.status
    assert_match(/cannot have more than/, json_response.fetch("detail"))
  end

  def test_post_guess_filters_answers_by_prev_guesses_and_current_guess
    date = "2021-06-19"
    answer = answer_for(date)

    post_json "/api/v1/game/guess", {date: date, guess: "crane", row_index: 1, prev_guesses: [[answer, "22222"]], return_remaining_count: true}

    assert last_response.ok?
    # prev_guesses filtered to just the answer; current guess also matches, so still 1
    assert_equal 1, json_response.fetch("answers_remaining")
  end

  def test_post_guess_rejects_invalid_mode
    post_json "/api/v1/game/guess", {date: "2021-06-19", guess: "crane", row_index: 0, mode: "nightmare"}

    assert_equal 400, last_response.status
    assert_equal "Mode must be regular, hard, or insane", json_response.fetch("detail")
  end

  def test_post_guess_accepts_regular_mode
    post_json "/api/v1/game/guess", {date: "2021-06-19", guess: "crane", row_index: 0, mode: "regular", prev_guesses: []}

    assert last_response.ok?
  end

  def test_post_guess_rejects_hard_mode_correct_position_violation
    date = "2021-06-19"
    # "crane" vs "cigar": c=correct(pos 0), r=present, a=present → "21100"
    # "stale" has 's' at pos 0, violating the correct 'c' at pos 0
    post_json "/api/v1/game/guess", {
      date: date, guess: "stale", row_index: 1, mode: "hard",
      prev_guesses: [["crane", "21100"]]
    }

    assert_equal 400, last_response.status
    assert_equal "1st letter must be C", json_response.fetch("detail")
  end

  def test_post_guess_rejects_hard_mode_missing_required_letter
    date = "2021-06-19"
    # Must include 'r' and 'a' (both present in "crane" mask "21100")
    # "might" has neither 'r' nor 'a'
    post_json "/api/v1/game/guess", {
      date: date, guess: "might", row_index: 1, mode: "hard",
      prev_guesses: [["crane", "21100"]]
    }

    assert_equal 400, last_response.status
  end

  def test_post_guess_accepts_valid_hard_mode_guess
    date = "2021-06-19"
    # "cargo": c at pos 0 ✓, has 'r' ✓, has 'a' ✓ → satisfies "crane" mask "21100"
    post_json "/api/v1/game/guess", {
      date: date, guess: "cargo", row_index: 1, mode: "hard",
      prev_guesses: [["crane", "21100"]]
    }

    assert last_response.ok?
  end

  def test_post_guess_rejects_insane_mode_forbidden_position
    date = "2021-06-19"
    # "crane" mask "21100": r at pos 1 and a at pos 2 are forbidden positions
    # "craft": c at 0 ✓, r at pos 1 (FORBIDDEN), a at 2 (also FORBIDDEN)
    post_json "/api/v1/game/guess", {
      date: date, guess: "craft", row_index: 1, mode: "insane",
      prev_guesses: [["crane", "21100"]]
    }

    assert_equal 400, last_response.status
    assert_match(/can't be in 2nd position/i, json_response.fetch("detail"))
  end

  def test_post_guess_rejects_insane_mode_absent_letter
    date = "2021-06-19"
    # "crane" mask "21100": n and e are absent — insane mode bans them
    # "carve": c at 0 ✓, a at 1 (not forbidden), r at 2 (not forbidden), has 'e' (ABSENT → banned)
    post_json "/api/v1/game/guess", {
      date: date, guess: "carve", row_index: 1, mode: "insane",
      prev_guesses: [["crane", "21100"]]
    }

    assert_equal 400, last_response.status
    assert_match(/cannot contain E/i, json_response.fetch("detail"))
  end

  def test_post_guess_accepts_valid_insane_mode_guess
    date = "2021-06-19"
    # "cargo": c at 0 ✓, a at 1 (not forbidden), r at 2 (not forbidden), g and o not absent
    post_json "/api/v1/game/guess", {
      date: date, guess: "cargo", row_index: 1, mode: "insane",
      prev_guesses: [["crane", "21100"]]
    }

    assert last_response.ok?
  end

  def test_post_guess_rejects_prev_guesses_that_is_not_an_array
    post_json "/api/v1/game/guess", {date: "2021-06-19", guess: "crane", row_index: 0, prev_guesses: '[["soare","00001"]]'}

    assert_equal 400, last_response.status
    assert_equal "prev_guesses must be an array of [word, pattern] pairs", json_response.fetch("detail")
  end

  def test_post_guess_rejects_prev_guesses_with_wrong_element_shape
    post_json "/api/v1/game/guess", {date: "2021-06-19", guess: "crane", row_index: 1, prev_guesses: [["soare"]]}

    assert_equal 400, last_response.status
    assert_equal "prev_guesses must be an array of [word, pattern] pairs", json_response.fetch("detail")
  end

  def test_post_guess_rejects_prev_guesses_with_invalid_pattern
    post_json "/api/v1/game/guess", {date: "2021-06-19", guess: "crane", row_index: 1, prev_guesses: [["soare", "xyz99"]]}

    assert_equal 400, last_response.status
    assert_equal "prev_guesses must be an array of [word, pattern] pairs", json_response.fetch("detail")
  end

  def test_unversioned_routes_are_not_available
    get "/api/health"
    assert_equal 404, last_response.status

    get "/api/game/today", date: "2021-06-19"
    assert_equal 404, last_response.status

    post_json "/api/game/guess", {date: "2021-06-19", guess: "cigar", row_index: 0}
    assert_equal 404, last_response.status
  end

  def test_origin_less_request_without_bearer_returns_401
    header "Authorization", nil
    get "/api/v1/health"

    assert_equal 401, last_response.status
    assert_equal "Authorization required", json_response.fetch("detail")
  end

  def test_origin_less_request_rejects_wrong_bearer_token
    get "/api/v1/health", {}, {"HTTP_AUTHORIZATION" => "Bearer wrong-token"}

    assert_equal 401, last_response.status
    assert_equal "Authorization required", json_response.fetch("detail")
  end

  def test_origin_less_request_accepts_correct_bearer_token
    with_server_api_token("test-server-token") do
      get "/api/v1/health", {}, {"HTTP_AUTHORIZATION" => "Bearer test-server-token"}

      assert last_response.ok?
    end
  end

  def test_browser_request_with_allowed_origin_needs_no_bearer
    get "/api/v1/health", {}, {"HTTP_ORIGIN" => "https://left-wordle.example"}

    assert last_response.ok?
  end

  def test_request_with_invalid_origin_returns_403_not_401
    get "/api/v1/health", {}, {"HTTP_ORIGIN" => "https://unrelated.example", "HTTP_AUTHORIZATION" => nil}

    assert_equal 403, last_response.status
    assert_equal "Origin not allowed", json_response.fetch("detail")
  end

  def test_post_diagnostics_returns_413_for_oversized_body
    oversized = "x" * (513 * 1024)
    post "/api/v1/diagnostics", oversized, {"CONTENT_TYPE" => "application/json"}

    assert_equal 413, last_response.status
    assert_match(/512 KB/, json_response.fetch("detail"))
  end

  def test_post_diagnostics_returns_400_for_empty_body
    post "/api/v1/diagnostics", "", {"CONTENT_TYPE" => "application/json"}

    assert_equal 400, last_response.status
    assert_equal "Request body is required", json_response.fetch("detail")
  end

  def test_post_diagnostics_returns_400_for_invalid_json
    post "/api/v1/diagnostics", "{bad json", {"CONTENT_TYPE" => "application/json"}

    assert_equal 400, last_response.status
    assert_equal "Request body must be valid JSON", json_response.fetch("detail")
  end

  def test_post_diagnostics_returns_503_when_smtp_not_configured
    with_smtp_not_configured do
      post_json "/api/v1/diagnostics", {preferences: {}}

      assert_equal 503, last_response.status
      assert_match(/not configured/, json_response.fetch("detail"))
    end
  end

  def test_post_diagnostics_sends_email_and_returns_200_when_configured
    Mail::TestMailer.deliveries.clear
    with_smtp_configured do
      post_json "/api/v1/diagnostics", {preferences: {darkTheme: true}, device_id: "abc"}

      assert_equal 200, last_response.status
      assert_equal "sent", json_response.fetch("status")
      assert_equal 1, Mail::TestMailer.deliveries.length

      mail = Mail::TestMailer.deliveries.first
      assert_equal "Left Wordle Diagnostics Report", mail.subject
      assert_equal ["left.wordle@wrightzone.com"], mail.to
      assert mail.has_attachments?
      assert_match(/left_wordle_diagnostics_.*\.json/, mail.attachments.first.filename)
    end
  end

  private

  def decrypt_answer(hex)
    key = LeftWordleApi::ANSWER_XOR_KEY
    [hex].pack("H*").bytes.each_with_index.map { |b, i| (b ^ key[i % key.length].ord).chr }.join
  end

  def answer_for(date)
    puzzle_number = LeftWordle::Game.puzzle_number_for(Date.iso8601(date))
    LeftWordle::Game.answer_for(puzzle_number)
  end

  def evaluation_string(eval_array)
    map = {LeftWordle::Game::ABSENT => "0", LeftWordle::Game::PRESENT => "1", LeftWordle::Game::CORRECT => "2"}
    eval_array.map { |v| map[v] }.join
  end

  def with_server_api_token(token = "test-server-token")
    LeftWordleApi.set :server_api_token, token
    yield
  ensure
    LeftWordleApi.set :server_api_token, nil
  end

  def answers_remaining_count(guess_answer_pairs)
    remaining = LeftWordle::Game.all_answers
    guess_answer_pairs.each do |guess, answer|
      pattern = evaluation_string(LeftWordle::Game.evaluate(guess, answer))
      remaining = remaining.select { |candidate|
        evaluation_string(LeftWordle::Game.evaluate(guess, candidate)) == pattern
      }
    end
    remaining.length
  end
end
