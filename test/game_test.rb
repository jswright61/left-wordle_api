# frozen_string_literal: true

require_relative "test_helper"

class GameTest < Minitest::Test
  def test_answer_list_wraps
    answer_count = WordData::AnswerList::WORDS.length

    assert_equal LeftWordle::Game.answer_for(0), LeftWordle::Game.answer_for(answer_count)
  end

  def test_evaluate_handles_duplicate_letters
    assert_equal(
      %w[correct correct present absent absent],
      LeftWordle::Game.evaluate("creep", "crane")
    )
  end

  def test_evaluate_marks_a_matching_guess_correct
    assert_equal [LeftWordle::Game::CORRECT] * 5, LeftWordle::Game.evaluate("crane", "crane")
  end

  def test_puzzle_number_uses_the_original_epoch
    assert_equal 0, LeftWordle::Game.puzzle_number_for(Date.new(2021, 6, 19))
    assert_equal 1, LeftWordle::Game.puzzle_number_for(Date.new(2021, 6, 20))
  end

  def test_valid_guess_accepts_answers_and_allowed_guesses
    assert LeftWordle::Game.valid_guess?("crane")
    assert LeftWordle::Game.valid_guess?("aahed")
    refute LeftWordle::Game.valid_guess?("zxqvw")
  end
end
