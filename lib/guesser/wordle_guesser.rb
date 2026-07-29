require_relative "word_lists"

class WordleGuesser
  include WordLists

  DEFAULT_ANSWER_BONUS = 0.2

  attr_reader :ordered

  def starter_choices(today: LeftWordle::Game.latest_available_date)
    grouped = starters.group_by do |starter|
      puzzle_date = starter[:puzzle_date]
      if puzzle_date.nil?
        :legal_words
      elsif puzzle_date >= today
        :unused
      else
        :orig_answers
      end
    end

    [:unused, :orig_answers, :legal_words].flat_map do |group|
      grouped.fetch(group, []).max_by(3) { |starter| starter[:entropy] }.map do |starter|
        {word: starter[:word], entropy: starter[:entropy], group:}
      end
    end.sort_by { |choice| -choice[:entropy] }
  end

  def filter_words(words, guess, pattern)
    words.select { |word| get_pattern(guess, word) == pattern }
  end

  def find_weighted_guesses(
    possible_answers,
    possible_guesses = nil,
    answer_bonus: DEFAULT_ANSWER_BONUS,
    preferred_answer_bonus: 0,
    preferred_answers: []
  )
    possible_guesses ||= possible_answers

    word_scores = possible_guesses.map do |word|
      entropy = calculate_entropy(word, possible_answers)
      in_answer = possible_answers.include?(word)
      preferred_answer = in_answer && preferred_answers.include?(word)
      weighted_entropy = entropy + (in_answer ? answer_bonus : 0) + (preferred_answer ? preferred_answer_bonus : 0)
      {word:, entropy:, weighted_entropy:, in_answer:}
    end

    ordered = word_scores.sort_by { |score| score[:weighted_entropy] }.reverse
    @ordered = ordered
    ordered.first(10)
  end

  def get_pattern(guess, target)
    pattern = [0] * 5
    target_chars = target.chars
    guess_chars = guess.chars

    5.times do |index|
      next unless guess_chars[index] == target_chars[index]

      pattern[index] = 2
      target_chars[index] = nil
      guess_chars[index] = nil
    end

    5.times do |index|
      next unless guess_chars[index] && target_chars.include?(guess_chars[index])

      pattern[index] = 1
      target_chars[target_chars.index(guess_chars[index])] = nil
    end

    pattern
  end

  private

  def calculate_entropy(guess, possible_answers)
    return 0.0 if possible_answers.empty?

    pattern_counts = possible_answers.each_with_object(Hash.new(0)) do |answer, counts|
      counts[get_pattern(guess, answer)] += 1
    end

    total = possible_answers.length.to_f
    pattern_counts.sum do |_pattern, count|
      probability = count / total
      -probability * Math.log2(probability)
    end
  end
end
