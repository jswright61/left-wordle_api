# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV["DATABASE_URL"] ||= "postgres:///left_wordle_api_test"

require "minitest/autorun"
require "rack/test"
require "mail"

Mail.defaults { delivery_method :test }

require_relative "../app"

module ApiTest
  include Rack::Test::Methods

  # Origins the suites treat as browser-allowed. The app builds its real list
  # from config/app_config.yml only, so each setup overrides
  # settings.allowed_origins with these -- they just have to be stable and
  # obviously not a real deployment.
  #
  # Named here rather than passed through ENV["CORS_ORIGINS"], which is what
  # this was before: an environment variable that looked like app
  # configuration but was read only by the tests themselves. That
  # misdirection is why removing it as "dead" quietly broke four tests
  # instead of failing loudly at the place it was set.
  TEST_ALLOWED_ORIGINS = %w[https://left-wordle.example https://alternate.example].freeze

  def app
    LeftWordleApi
  end

  def json_response
    JSON.parse(last_response.body)
  end

  def post_json(path, payload, env = {})
    post path, JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}.merge(env)
  end

  def put_json(path, payload, env = {})
    put path, JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}.merge(env)
  end

  def patch_json(path, payload, env = {})
    patch path, JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}.merge(env)
  end

  def csrf_env(token)
    {"HTTP_X_CSRF_TOKEN" => token}
  end

  def with_smtp_configured
    LeftWordleApi.set :smtp_username, "sender@example.com"
    LeftWordleApi.set :smtp_password, "test-password"
    LeftWordleApi.set :smtp_from, "sender@example.com"
    yield
  ensure
    LeftWordleApi.set :smtp_username, nil
    LeftWordleApi.set :smtp_password, nil
    LeftWordleApi.set :smtp_from, nil
  end

  def with_smtp_not_configured
    orig_username = LeftWordleApi.smtp_username
    orig_password = LeftWordleApi.smtp_password
    orig_from = LeftWordleApi.smtp_from
    LeftWordleApi.set :smtp_username, nil
    LeftWordleApi.set :smtp_password, nil
    LeftWordleApi.set :smtp_from, nil
    yield
  ensure
    LeftWordleApi.set :smtp_username, orig_username
    LeftWordleApi.set :smtp_password, orig_password
    LeftWordleApi.set :smtp_from, orig_from
  end
end
