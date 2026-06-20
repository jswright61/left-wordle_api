require_relative "wordle_guesser"

class SolveEngine
  ANSWER_BONUS = 0.1
  FEW_ANSWERS_THRESHOLD = 10
  MAX_ATTEMPTS = 6
  SOLVED_PATTERN = [2, 2, 2, 2, 2].freeze
  UNUSED_ANSWER_BONUS = 0.2

  attr_reader :guesser

  def initialize(guesser = WordleGuesser.new)
    @guesser = guesser
  end

  def start_remaining
    @guesser.orig_answers.dup
  end

  def process_turn(remaining:, guess:, pattern:, attempt:)
    return {status: :solved} if pattern == SOLVED_PATTERN

    filtered = @guesser.filter_words(remaining, guess, pattern)
    return {status: :no_answers, remaining: filtered} if filtered.empty?
    return {status: :answer, remaining: filtered, answer: filtered.first} if filtered.one?
    return {status: :exhausted, remaining: filtered} if attempt >= MAX_ATTEMPTS

    {status: :continue, remaining: filtered, attempt: attempt + 1, suggestions: weighted_suggestions(filtered)}
  end

  def weighted_suggestions(remaining)
    preferred_answers = (remaining.length <= FEW_ANSWERS_THRESHOLD) ? @guesser.unused : []
    suggestions = @guesser.find_weighted_guesses(
      remaining,
      @guesser.legal_words,
      answer_bonus: ANSWER_BONUS,
      preferred_answer_bonus: UNUSED_ANSWER_BONUS,
      preferred_answers:
    )
    unused = @guesser.unused
    suggestions.map { |s| s.merge(unused_answer: unused.include?(s[:word])) }
  end
end
