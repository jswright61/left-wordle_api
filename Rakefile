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

task default: :test
