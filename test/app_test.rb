# frozen_string_literal: true

require_relative "test_helper"

class AppTest < Minitest::Test
  include ApiTest

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

  def test_request_without_an_origin_is_allowed
    get "/api/v1/health"

    assert last_response.ok?
    refute last_response.headers.key?("access-control-allow-origin")
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

  def test_post_guess_omits_answers_remaining_when_prev_guesses_absent
    post_json "/api/v1/game/guess", {date: "2021-06-19", guess: "crane", row_index: 0}

    assert last_response.ok?
    refute json_response.key?("answers_remaining")
  end

  def test_post_guess_returns_count_after_current_guess_for_empty_prev_guesses
    date = "2021-06-19"
    answer = answer_for(date)

    post_json "/api/v1/game/guess", {date: date, guess: "crane", row_index: 0, prev_guesses: []}

    assert last_response.ok?
    # answers_remaining reflects answers left after the current guess (not just prev_guesses)
    expected = answers_remaining_count([["crane", answer]])
    assert_equal expected, json_response.fetch("answers_remaining")
  end

  def test_post_guess_returns_zero_answers_remaining_for_winning_guess
    date = "2021-06-19"
    answer = answer_for(date)

    post_json "/api/v1/game/guess", {date: date, guess: answer, row_index: 0, prev_guesses: []}

    assert last_response.ok?
    assert_equal "WIN", json_response.fetch("game_status")
    assert_equal 0, json_response.fetch("answers_remaining")
  end

  def test_post_guess_filters_answers_by_prev_guesses_and_current_guess
    date = "2021-06-19"
    answer = answer_for(date)

    post_json "/api/v1/game/guess", {date: date, guess: "crane", row_index: 1, prev_guesses: [[answer, "22222"]]}

    assert last_response.ok?
    # prev_guesses filtered to just the answer; current guess also matches, so still 1
    assert_equal 1, json_response.fetch("answers_remaining")
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

  private

  def answer_for(date)
    puzzle_number = LeftWordle::Game.puzzle_number_for(Date.iso8601(date))
    LeftWordle::Game.answer_for(puzzle_number)
  end

  def evaluation_string(eval_array)
    map = {LeftWordle::Game::ABSENT => "0", LeftWordle::Game::PRESENT => "1", LeftWordle::Game::CORRECT => "2"}
    eval_array.map { |v| map[v] }.join
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
