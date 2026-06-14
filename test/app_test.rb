# frozen_string_literal: true

require_relative "test_helper"

class AppTest < Minitest::Test
  include ApiTest

  def test_get_health
    get "/api/health"

    assert last_response.ok?
    assert_equal({"status" => "ok"}, json_response)
    assert_equal "no-store", last_response.headers.fetch("cache-control")
  end

  def test_get_today
    get "/api/game/today"

    assert last_response.ok?
    assert_kind_of Integer, json_response.fetch("puzzle_num")
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, json_response.fetch("date"))
    assert_equal 5, json_response.fetch("word_length")
  end

  def test_options_returns_cors_headers
    options "/api/game/guess"

    assert_equal 204, last_response.status
    assert_equal "*", last_response.headers.fetch("access-control-allow-origin")
  end

  def test_post_guess_rejects_invalid_json
    post "/api/game/guess", "{", {"CONTENT_TYPE" => "application/json"}

    assert_equal 400, last_response.status
    assert_equal "Request body must be valid JSON", json_response.fetch("detail")
  end

  def test_post_guess_rejects_invalid_row_index
    answer = today_answer

    post_json "/api/game/guess", {guess: answer, row_index: 6}

    assert_equal 400, last_response.status
    assert_match(/Row index/, json_response.fetch("detail"))
  end

  def test_post_guess_rejects_unknown_word
    post_json "/api/game/guess", {guess: "zxqvw", row_index: 0}

    assert_equal 400, last_response.status
    assert_equal "Not in word list", json_response.fetch("detail")
  end

  def test_post_guess_returns_fail_and_solution_on_last_row
    answer = today_answer
    wrong_guess = WordData::AnswerList::WORDS.find { |word| word != answer }

    post_json "/api/game/guess", {guess: wrong_guess, row_index: 5}

    assert last_response.ok?
    assert_equal "FAIL", json_response.fetch("game_status")
    assert_equal answer, json_response.fetch("solution")
  end

  def test_post_guess_returns_win_and_solution
    answer = today_answer

    post_json "/api/game/guess", {guess: answer, row_index: 0}

    assert last_response.ok?
    assert_equal ["correct"] * 5, json_response.fetch("evaluation")
    assert_equal "WIN", json_response.fetch("game_status")
    assert_equal 1, json_response.fetch("row_index")
    assert_equal answer, json_response.fetch("solution")
  end

  private

  def today_answer
    puzzle = LeftWordle::Game.today
    LeftWordle::Game.answer_for(puzzle[:number])
  end
end
