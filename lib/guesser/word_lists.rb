require "date"
require "yaml"
require_relative "sorted_upper_string_set"

module WordLists
  STARTERS_FILE = File.expand_path("../../data/guesser/starters.yml", __dir__).freeze

  def legal_words(force: false)
    @legal_words = nil if force
    @legal_words ||= LeftWordle::Game::ALL_VALID_WORDS.map(&:upcase)
  end

  def orig_answers(force: false)
    @orig_answers = nil if force
    @orig_answers ||= WordData::AnswerList::WORDS.map(&:upcase)
  end

  def starters(force: false)
    @starters = nil if force
    @starters ||= begin
      answer_dates = orig_answers.each_with_index.to_h do |word, index|
        [word, LeftWordle::Game::PUZZLE_EPOCH + index]
      end

      YAML.load_file(STARTERS_FILE).map do |starter|
        starter.merge(puzzle_date: answer_dates[starter[:word]])
      end
    end
  end

  def unused
    orig_answers[LeftWordle::Game.puzzle_number_for(Date.today)..]
  end
end
