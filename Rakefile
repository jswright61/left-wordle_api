# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "lib"
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

task test: "db:test:prepare"

namespace :db do
  desc "Run pending Sequel migrations (optionally to a specific [version])"
  task :migrate, [:version] do |_t, args|
    require "sequel"
    require_relative "lib/db"
    Sequel.extension :migration

    target = args[:version].nil? ? nil : Integer(args[:version])
    Sequel::Migrator.run(DB, File.join(__dir__, "db/migrate"), target: target)
    puts "Migrated to #{target || "latest"}."
  end

  desc "Roll back to the given migration [version] (0 rolls back everything)"
  task :rollback, [:version] do |_t, args|
    Rake::Task["db:migrate"].invoke(args[:version] || "0")
  end

  desc "Seed answers/legal_words from the checked-in db/seeds files. Safe to rerun."
  task :seed do
    require_relative "lib/db"
    require_relative "lib/models/answer"
    require_relative "lib/models/legal_word"

    answers = File.readlines(File.join(__dir__, "db/seeds/answers.txt"), chomp: true).reject(&:empty?)
    answers.each_with_index do |word, position|
      answer = Answer.first(position: position) || Answer.new(position: position)
      answer.set(word: word).save
    end
    puts "Seeded #{answers.length} answer(s)"

    legal_words = File.readlines(File.join(__dir__, "db/seeds/legal_words.txt"), chomp: true).reject(&:empty?)
    legal_words.each { |word| LegalWord.find_or_create(word: word) }
    puts "Seeded #{legal_words.length} legal word(s)"
  end

  namespace :test do
    desc "Migrate and seed the test database"
    task :prepare do
      ENV["RACK_ENV"] = "test"
      ENV["DATABASE_URL"] ||= "postgres:///left_wordle_api_test"
      Rake::Task["db:migrate"].invoke
      Rake::Task["db:seed"].invoke
    end
  end
end

namespace :users do
  desc "Add or update a guesser user interactively"
  task :add do
    require "io/console"
    require_relative "lib/db"
    require_relative "lib/models/guesser_user"

    print "Username: "
    username = $stdin.gets.chomp.strip
    abort "Username cannot be blank." if username.empty?

    user = GuesserUser.first(username: username)
    if user
      print "User '#{username}' already exists. Update password? (y/n): "
      abort "Cancelled." unless $stdin.gets.chomp.strip.downcase == "y"
    else
      user = GuesserUser.new(username: username)
    end

    print "Password: "
    password = $stdin.noecho(&:gets).chomp
    puts

    abort "Password cannot be blank." if password.empty?

    print "Confirm password: "
    confirm = $stdin.noecho(&:gets).chomp
    puts

    abort "Passwords do not match." unless password == confirm

    user.password = password
    user.approved_at = Time.now
    user.save
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

def wl_write_client_js(answer_words, valid_guess_words)
  combined = (answer_words.to_a + valid_guess_words.to_a).uniq.sort
  output = File.expand_path("../../client/src/valid_guesses.js", __FILE__)
  lines = combined.map { |w| "    #{w.inspect}" }
  File.write(output, "var valid_guesses = [\n#{lines.join(",\n")}\n];\n")
  puts "Wrote #{combined.length} words to #{output}"
end

def wl_write_seed_files(answers_ordered, legal_words_sorted)
  seeds_dir = File.join(__dir__, "db/seeds")
  File.write(File.join(seeds_dir, "answers.txt"), "#{answers_ordered.join("\n")}\n")
  File.write(File.join(seeds_dir, "legal_words.txt"), "#{legal_words_sorted.to_a.sort.join("\n")}\n")
  puts "Updated db/seeds/answers.txt and db/seeds/legal_words.txt"
end

namespace :word_lists do
  desc "Add allowable-guess words (not answers). Arg: comma-separated words or path to .json/.yml file"
  task :add_legal_words, [:input] do |_t, args|
    require_relative "lib/db"
    require_relative "lib/models/answer"
    require_relative "lib/models/legal_word"

    raw = wl_parse_input(args)
    valid_input, rejected = wl_validate(raw)

    existing = Set.new(LegalWord.select_map(:word))
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

    puts "New words to add to the legal_words table (#{new_words.length} total, alphabetical):"
    wl_show_preview(new_words, ordered: false)

    next unless wl_confirm

    new_words.each { |word| LegalWord.find_or_create(word: word) }
    puts "Inserted #{new_words.length} word(s) into legal_words"

    answers = Answer.order(:position).select_map(:word)
    merged_guesses = Set.new(LegalWord.select_map(:word))
    wl_write_client_js(answers, merged_guesses)
    wl_write_seed_files(answers, merged_guesses)
  end

  desc "Append new puzzle answers. Arg: comma-separated words or path to .json/.yml file"
  task :add_answers, [:input] do |_t, args|
    require_relative "lib/db"
    require_relative "lib/models/answer"
    require_relative "lib/models/legal_word"

    raw = wl_parse_input(args)
    valid_input, rejected = wl_validate(raw)

    existing_answers = Answer.order(:position).select_map(:word)
    existing_guesses = Set.new(LegalWord.select_map(:word))

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

    puts "New answers to append (#{new_answers.length} total, in order given):"
    wl_show_preview(new_answers, ordered: true)

    if to_add_to_guesses.any?
      puts
      puts "Also adding #{to_add_to_guesses.length} answer word(s) to legal_words:"
      puts "  #{to_add_to_guesses.join(", ")}"
    end

    next unless wl_confirm

    new_answers.each_with_index do |word, offset|
      Answer.create(position: existing_answers.length + offset, word: word)
    end
    puts "Inserted #{new_answers.length} answer(s) into answers"

    if to_add_to_guesses.any?
      to_add_to_guesses.each { |word| LegalWord.find_or_create(word: word) }
      puts "Inserted #{to_add_to_guesses.length} word(s) into legal_words"
    end

    answers = Answer.order(:position).select_map(:word)
    merged_guesses = Set.new(LegalWord.select_map(:word))
    wl_write_client_js(answers, merged_guesses)
    wl_write_seed_files(answers, merged_guesses)
  end
end

namespace :client do
  desc "Regenerate client/src/valid_guesses.js from the answers + legal_words tables"
  task :generate_word_list do
    require_relative "lib/db"
    require_relative "lib/models/answer"
    require_relative "lib/models/legal_word"

    wl_write_client_js(Answer.order(:position).select_map(:word), LegalWord.select_map(:word))
  end
end

namespace :stats do
  desc "Email a daily summary of DAU, avg completion time, country breakdown, and abandoned games"
  task :daily_summary do
    require "mail"
    require "yaml"
    require_relative "lib/db"

    app_cfg_file = File.join(__dir__, "config", "app_config.yml")
    app_cfg = File.exist?(app_cfg_file) ? (YAML.load_file(app_cfg_file) || {}) : {}
    smtp_username = app_cfg["smtp_username"].to_s.strip
    smtp_password = app_cfg["smtp_password"].to_s.strip
    smtp_from = app_cfg["smtp_from"].to_s.strip
    smtp_from = smtp_username if smtp_from.empty?

    if smtp_username.empty? || smtp_password.empty?
      abort "SMTP is not configured (smtp_username/smtp_password missing in config/app_config.yml)."
    end

    dau = DB[:played_games]
      .where(Sequel.lit("initiated_at IS NOT NULL"))
      .group(:date)
      .select(:date, Sequel.function(:count, Sequel.lit("DISTINCT client_device_id")).as(:dau))
      .order(Sequel.desc(:date))
      .limit(14)
      .all

    completion = DB[:played_games]
      .where(Sequel.lit("initiated_at IS NOT NULL AND completed_at IS NOT NULL AND completed_at - initiated_at < INTERVAL '30 minutes'"))
      .group(:date)
      .select(
        :date,
        Sequel.function(:avg, Sequel.lit("completed_at - initiated_at")).as(:avg_completion),
        Sequel.function(:count, Sequel.lit("*")).as(:included_games)
      )
      .order(Sequel.desc(:date))
      .limit(14)
      .all

    abandoned = DB[:played_games]
      .where(Sequel.lit("initiated_at IS NOT NULL AND completed_at IS NULL AND date < CURRENT_DATE - INTERVAL '1 day'"))
      .count

    # Country is captured per-game (a device's country can change game to game --
    # travel, VPN, mobile network), so this counts games, not distinct devices.
    countries = DB[:played_games]
      .exclude(country_code: nil)
      .group(:country_code)
      .select(:country_code, Sequel.function(:count, Sequel.lit("*")).as(:game_count))
      .order(Sequel.desc(:game_count))
      .all

    body = +"Left Wordle -- Daily Stats Summary\n\n"
    body << "== Daily Active Users (last 14 days) ==\n"
    dau.each { |row| body << "#{row[:date]}: #{row[:dau]}\n" }
    body << "\n== Avg Completion Time, under 30min (last 14 days) ==\n"
    completion.each { |row| body << "#{row[:date]}: #{row[:avg_completion]} (#{row[:included_games]} games)\n" }
    body << "\n== Abandoned Games (initiated, never completed, puzzle date elapsed) ==\n#{abandoned}\n"
    body << "\n== Games by Country ==\n"
    countries.each { |row| body << "#{row[:country_code]}: #{row[:game_count]}\n" }

    mail = Mail.new
    mail.from = smtp_from
    mail.to = "left.wordle@wrightzone.com"
    mail.subject = "Left Wordle Daily Stats Summary -- #{Date.today.iso8601}"
    mail.body = body

    if ENV["RACK_ENV"] == "test"
      mail.delivery_method :test
    else
      mail.delivery_method :smtp, {
        address: "smtp.fastmail.com",
        port: 587,
        user_name: smtp_username,
        password: smtp_password,
        authentication: :login,
        enable_starttls_auto: true
      }
    end

    mail.deliver!
    puts "Sent daily stats summary email."
  end
end

load File.join(__dir__, "lib/tasks/scheduler.rake")
load File.join(__dir__, "lib/tasks/storage_snapshots.rake")
load File.join(__dir__, "lib/tasks/cloudflare_cache_rules.rake")

task default: :test
