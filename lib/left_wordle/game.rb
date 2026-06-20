# frozen_string_literal: true

require "date"

require_relative "../word_data/answer_list"
require_relative "../word_data/valid_guesses"

module LeftWordle
  module Game
    ABSENT = "absent"
    CORRECT = "correct"
    MAX_UTC_OFFSET = "+14:00"
    MAX_GUESSES = 6
    PRESENT = "present"
    PUZZLE_EPOCH = Date.new(2021, 6, 19)
    WORD_LENGTH = 5

    ALL_VALID_WORDS = (WordData::ValidGuesses::WORDS | Set.new(WordData::AnswerList::WORDS)).freeze

    module_function

    def answer_for(puzzle_number)
      WordData::AnswerList::WORDS.fetch(puzzle_number % WordData::AnswerList::WORDS.length)
    end

    def evaluate(guess, answer)
      guess = guess.downcase
      answer = answer.downcase
      result = Array.new(answer.length, ABSENT)
      guess_unmatched = Array.new(answer.length, true)
      answer_unmatched = Array.new(answer.length, true)

      answer.length.times do |index|
        next unless guess[index] == answer[index]

        result[index] = CORRECT
        guess_unmatched[index] = false
        answer_unmatched[index] = false
      end

      answer.length.times do |guess_index|
        next unless guess_unmatched[guess_index]

        answer.length.times do |answer_index|
          next unless answer_unmatched[answer_index] && guess[guess_index] == answer[answer_index]

          result[guess_index] = PRESENT
          answer_unmatched[answer_index] = false
          break
        end
      end

      result
    end

    def latest_available_date(time: Time.now)
      time.getlocal(MAX_UTC_OFFSET).to_date
    end

    def puzzle_number_for(date)
      (date - PUZZLE_EPOCH).to_i
    end

    def all_answers
      WordData::AnswerList::WORDS
    end

    def valid_guess?(word)
      ALL_VALID_WORDS.include?(word.downcase)
    end
  end
end
