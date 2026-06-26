require "date"
require "yaml"

# Picks words from a weighted list, where weight decays sharply right after
# a word is used and then recovers gradually over subsequent days. Words
# used more times recover more slowly.
class OldWeightedWordPicker
  DEFAULT_CONFIG_PATH = "config/weighted_word_picker.yml"

  # Fallback values, used for any key missing from the config source.
  CONFIG_DEFAULTS = {
    recent_use_penalty: 90,
    min_score: 1,
    penalty_days: 1,
    recovery_base: 2
  }.freeze

  # word_list: array of hashes, each { word:, default_weight:, last_used:, times_used: }
  # This array is held by reference and mutated in place when a word is picked
  # via #select_and_record!.
  #
  # config_path: where get_config loads from. Swap this method's body out
  # later (e.g. to read from a database) without touching anything else
  # in the class.
  def initialize(word_list, config_path: DEFAULT_CONFIG_PATH)
    @word_list = word_list
    @config_path = config_path
    @config = get_config
  end

  # Loads config from the YAML file at @config_path, falling back to
  # CONFIG_DEFAULTS for any missing keys (or if the file doesn't exist).
  # This is the one method to swap out when moving to a database later.
  def get_config
    loaded = File.exist?(@config_path) ? YAML.safe_load_file(@config_path, symbolize_names: true) : {}
    CONFIG_DEFAULTS.merge(loaded)
  end

  # Returns the weighted_score for a single word hash, as of for_date.
  def weighted_score(word_hash, for_date: Date.today)
    default_weight = word_hash[:default_weight]
    times_used     = word_hash[:times_used]

    return default_weight if times_used == 0

    days_since = (for_date - word_hash[:last_used]).to_i

    penalized = [default_weight - @config[:recent_use_penalty], @config[:min_score]].max
    return penalized if days_since <= @config[:penalty_days]

    recovery_days = days_since - @config[:penalty_days]
    recovered = penalized + (recovery_days * per_day_recovery_rate(times_used))

    return default_weight if recovered >= default_weight

    recovered.to_i
  end

  # Builds the full weighted list (with cumulative start_range) for the
  # current word_list, as of for_date.
  # Returns: array of { word:, weighted_score:, start_range: }
  def build_weighted_list(for_date: Date.today)
    running_total = 0

    @word_list.map do |w|
      score = weighted_score(w, for_date: for_date)
      entry = { word: w[:word], weighted_score: score, start_range: running_total }
      running_total += score
      entry
    end
  end

  # Picks one entry from a pre-built weighted_list via cumulative-weight
  # random selection. Returns nil if total weight is 0.
  def pick(weighted_list)
    total = weighted_list.sum { |entry| entry[:weighted_score] }
    return nil if total <= 0

    roll = rand(0...total)
    weighted_list.reverse_each.find { |entry| entry[:start_range] <= roll }
  end

  # Full cycle: builds the weighted list, picks a winner, and updates that
  # word's entry in the original word_list (last_used = for_date,
  # times_used += 1). Returns the winner's updated hash, or nil if nothing
  # could be picked.
  def select_and_record!(for_date: Date.today)
    weighted_list = build_weighted_list(for_date: for_date)
    chosen = pick(weighted_list)
    return nil if chosen.nil?

    winner = @word_list.find { |w| w[:word] == chosen[:word] }
    winner[:last_used] = for_date
    winner[:times_used] += 1
    winner
  end

  private

  # 1/2 per day if used once, 1/4 if twice, 1/8 if 3 times, etc.
  def per_day_recovery_rate(times_used)
    1.0 / (@config[:recovery_base]**(times_used - 1))
  end
end

# --- Example usage ---
if __FILE__ == $0
  sample_words = [
    { word: "apple",  default_weight: 100, last_used: nil,            times_used: 0 },
    { word: "banana", default_weight: 100, last_used: Date.today - 1, times_used: 1 },
    { word: "cherry", default_weight: 100, last_used: Date.today - 10, times_used: 2 },
    { word: "date",   default_weight: 100, last_used: Date.today - 30, times_used: 5 }
  ]

  picker = WeightedWordPicker.new(sample_words)

  picker.build_weighted_list.each { |e| puts e }

  puts "---"
  winner = picker.select_and_record!
  puts "Picked: #{winner[:word]}"
  puts "Updated original entry: #{winner}"
end