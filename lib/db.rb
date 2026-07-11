# frozen_string_literal: true

require "sequel"
require "yaml"

module LeftWordle
  module DB
    module_function

    # Same config/app_config.yml app.rb already loads. Precedence: an
    # explicit DATABASE_URL env var (used by test/test_helper.rb to point at
    # the _test database) wins, then the per-environment app_config.yml
    # value (how staging/production set real credentials), then a
    # zero-config local default so `createdb left_wordle_api_development`
    # is all a fresh dev machine needs.
    def connection_string
      cfg_file = File.join(__dir__, "..", "config", "app_config.yml")
      app_cfg = File.exist?(cfg_file) ? (YAML.load_file(cfg_file) || {}) : {}

      ENV["DATABASE_URL"] ||
        app_cfg["database_url"] ||
        "postgres:///left_wordle_api_#{ENV.fetch("RACK_ENV", "development")}"
    end
  end
end

DB = Sequel.connect(LeftWordle::DB.connection_string)
DB.extension :pg_json

Sequel::Model.plugin :timestamps, update_on_create: true
