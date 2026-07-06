# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "lib"
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

namespace :users do
  desc "Add or update a guesser user interactively"
  task :add do
    require "bcrypt"
    require "io/console"
    require "yaml"

    users_file = File.join(__dir__, "users.yml")
    users = File.exist?(users_file) ? (YAML.load_file(users_file) || {}) : {}

    print "Username: "
    username = $stdin.gets.chomp.strip
    abort "Username cannot be blank." if username.empty?

    if users.key?(username)
      print "User '#{username}' already exists. Update password? (y/n): "
      abort "Cancelled." unless $stdin.gets.chomp.strip.downcase == "y"
    end

    print "Password: "
    password = $stdin.noecho(&:gets).chomp
    puts

    abort "Password cannot be blank." if password.empty?

    print "Confirm password: "
    confirm = $stdin.noecho(&:gets).chomp
    puts

    abort "Passwords do not match." unless password == confirm

    users[username] = BCrypt::Password.create(password).to_s
    File.write(users_file, users.to_yaml)
    puts "User '#{username}' saved."
  end
end

def wl_parse_input(args)
  first = args[:input].to_s.strip
  extras = args.extras.map(&:strip).reject(&:empty?)

  return [] if first.empty? && extras.empty?

  # Single arg with no extras: could be a file path or comma-separated words
  if extras.empty?
    if File.exist?(first)
      ext = File.extname(first).downcase
      case ext
      when ".json"
        require "json"
        return JSON.parse(File.read(first))
      when ".yml", ".yaml"
        require "yaml"
        return YAML.safe_load(File.read(first))
      else
        abort "Unsupported file extension '#{ext}'. Use .json or .yml"
      end
    else
      return first.split(",").map(&:strip).reject(&:empty?)
    end
  end

  # Multiple rake args (rake splits "word1,word2" into separate task args)
  [first, *extras].reject(&:empty?)
end

def wl_validate(words)
  valid, rejected = [], []
  words.each do |w|
    (w.to_s.downcase.strip.match?(/\A[a-z]{5}\z/) ? valid : rejected) << w.to_s.downcase.strip
  end
  [valid, rejected]
end

def wl_show_preview(words, ordered:)
  display = ordered ? words : words.sort
  if display.length <= 10
    puts "  Words:  #{display.join(", ")}"
  else
    puts "  First 5: #{display.first(5).join(", ")}"
    puts "  Last 5:  #{display.last(5).join(", ")}"
  end
end

def wl_confirm
  print "\nProceed? (y/n): "
  $stdin.gets.chomp.strip.casecmp?("y")
end

def wl_write_valid_guesses(words)
  sorted = words.to_a.sort
  path = File.join(__dir__, "lib/word_data/valid_guesses.rb")
  word_lines = sorted.each_with_index.map { |w, i| "      #{w.inspect}#{i < sorted.length - 1 ? "," : ""}" }
  File.write(path, [
    "# frozen_string_literal: true",
    "",
    "module WordData",
    "  module ValidGuesses",
    "    WORDS = Set.new([",
    *word_lines,
    "    ]).freeze",
    "  end",
    "end",
    ""
  ].join("\n"))
end

def wl_write_answer_list(words)
  path = File.join(__dir__, "lib/word_data/answer_list.rb")
  word_lines = words.each_with_index.map { |w, i| "      #{w.inspect}#{i < words.length - 1 ? "," : ""}" }
  File.write(path, [
    "# frozen_string_literal: true",
    "",
    "module WordData",
    "  module AnswerList",
    "    WORDS = [",
    *word_lines,
    "    ].freeze",
    "  end",
    "end",
    ""
  ].join("\n"))
end

def wl_write_client_js(answer_words, valid_guess_words)
  combined = (answer_words.to_a + valid_guess_words.to_a).uniq.sort
  output = File.expand_path("../../client/src/valid_guesses.js", __FILE__)
  lines = combined.map { |w| "    #{w.inspect}" }
  File.write(output, "var valid_guesses = [\n#{lines.join(",\n")}\n];\n")
  puts "Wrote #{combined.length} words to #{output}"
end

namespace :word_lists do
  desc "Add allowable-guess words (not answers). Arg: comma-separated words or path to .json/.yml file"
  task :add_legal_words, [:input] do |_t, args|
    require "set"
    require_relative "lib/word_data/valid_guesses"
    require_relative "lib/word_data/answer_list"

    raw = wl_parse_input(args)
    valid_input, rejected = wl_validate(raw)

    existing = WordData::ValidGuesses::WORDS
    unique_input = valid_input.uniq
    new_words = unique_input - existing.to_a
    skipped = unique_input & existing.to_a

    puts
    puts "=== word_lists:add_legal_words ==="
    puts "  Rejected (not 5 lowercase ASCII letters): #{rejected.any? ? rejected.join(", ") : "none"}"
    puts "  Already present (skipped): #{skipped.any? ? skipped.join(", ") : "none"}"
    puts

    if new_words.empty?
      puts "No new words to add. Nothing to do."
      next
    end

    puts "New words to add to valid_guesses.rb (#{new_words.length} total, alphabetical):"
    wl_show_preview(new_words, ordered: false)

    next unless wl_confirm

    merged = existing | Set.new(new_words)
    wl_write_valid_guesses(merged)
    puts "Updated lib/word_data/valid_guesses.rb (+#{new_words.length} words)"

    wl_write_client_js(WordData::AnswerList::WORDS, merged)
  end

  desc "Append new puzzle answers. Arg: comma-separated words or path to .json/.yml file"
  task :add_answers, [:input] do |_t, args|
    require "set"
    require_relative "lib/word_data/answer_list"
    require_relative "lib/word_data/valid_guesses"

    raw = wl_parse_input(args)
    valid_input, rejected = wl_validate(raw)

    existing_answers = WordData::AnswerList::WORDS
    existing_guesses = WordData::ValidGuesses::WORDS

    # Preserve caller order; skip words already in the answer list
    new_answers = valid_input.each_with_object([]) do |w, arr|
      arr << w unless existing_answers.include?(w) || arr.include?(w)
    end
    skipped = valid_input.uniq.select { |w| existing_answers.include?(w) }
    to_add_to_guesses = new_answers.reject { |w| existing_guesses.include?(w) }

    puts
    puts "=== word_lists:add_answers ==="
    puts "  Rejected (not 5 lowercase ASCII letters): #{rejected.any? ? rejected.join(", ") : "none"}"
    puts "  Already in answer list (skipped): #{skipped.any? ? skipped.join(", ") : "none"}"
    puts

    if new_answers.empty?
      puts "No new answers to append. Nothing to do."
      next
    end

    puts "New answers to append to answer_list.rb (#{new_answers.length} total, in order given):"
    wl_show_preview(new_answers, ordered: true)

    if to_add_to_guesses.any?
      puts
      puts "Also adding #{to_add_to_guesses.length} answer word(s) to valid_guesses.rb:"
      puts "  #{to_add_to_guesses.join(", ")}"
    end

    next unless wl_confirm

    updated_answers = existing_answers.to_a + new_answers
    wl_write_answer_list(updated_answers)
    puts "Updated lib/word_data/answer_list.rb (+#{new_answers.length} answers)"

    merged_guesses = existing_guesses | Set.new(to_add_to_guesses)
    if to_add_to_guesses.any?
      wl_write_valid_guesses(merged_guesses)
      puts "Updated lib/word_data/valid_guesses.rb (+#{to_add_to_guesses.length} words)"
    end

    wl_write_client_js(updated_answers, merged_guesses)
  end
end

namespace :client do
  desc "Regenerate client/src/valid_guesses.js from answer_list + valid_guesses word data"
  task :generate_word_list do
    require_relative "lib/word_data/answer_list"
    require_relative "lib/word_data/valid_guesses"

    combined = (WordData::AnswerList::WORDS.to_a + WordData::ValidGuesses::WORDS.to_a).uniq.sort

    output = File.expand_path("../../client/src/valid_guesses.js", __FILE__)
    lines = combined.map { |w| "    #{w.to_s.inspect}" }
    File.write(output, "var valid_guesses = [\n#{lines.join(",\n")}\n];\n")

    puts "Wrote #{combined.length} words to #{output}"
  end
end

task default: :test
