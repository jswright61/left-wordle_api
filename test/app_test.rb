# frozen_string_literal: true

require_relative "test_helper"

class AppTest < Minitest::Test
  include ApiTest

  def setup
    origins = ENV["CORS_ORIGINS"].to_s.split(",").map(&:strip).reject(&:empty?)
    LeftWordleApi.set :allowed_origins, origins.freeze
    header "Authorization", "Bearer 1234"
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

  def test_get_answer_returns_encrypted_answer_for_date
    date = "2021-06-19"
    get "/api/v1/game/answer", date: date

    assert last_response.ok?
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
    wrong_guess = WordData::AnswerList::WORDS.find { |word| word != answer }

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
    post_json "/api/v1/diagnostics", {preferences: {}}

    assert_equal 503, last_response.status
    assert_match(/not configured/, json_response.fetch("detail"))
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

  def with_smtp_configured
    LeftWordleApi.set :smtp_username, "sender@example.com"
    LeftWordleApi.set :smtp_password, "test-password"
    LeftWordleApi.set :smtp_from, "sender@example.com"
    yield
  ensure
    LeftWordleApi.set :smtp_username, nil
    LeftWordleApi.set :smtp_password, nil
    LeftWordleApi.set :smtp_from, nil
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
