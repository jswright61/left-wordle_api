# frozen_string_literal: true

source "https://rubygems.org"

ruby File.read(".ruby-version").strip

gem "sinatra", "~> 4.2"
gem "bcrypt", "~> 3.1"

gem "yaml", "~> 0.4.0"

gem "date", "~> 3.5"
gem "rake", "~> 13.3"

gem "rackup", "~> 2.3"
gem "puma", "~> 8.0"
gem "mail", "~> 2.8"

gem "sequel", "~> 5.9"
gem "pg", "~> 1.5"

group :development do
  gem "pry", "~> 0.16.0", require: false
  gem "standard", "~> 1.50", require: false
  gem "capistrano", "~> 3.19", require: false
  gem "capistrano-bundler", "~> 2.1", require: false
end

group :test do
  gem "minitest", "~> 6.0"
  gem "rack-test", "~> 2.2"
end
