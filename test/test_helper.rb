# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV["CORS_ORIGINS"] = "https://left-wordle.example, https://alternate.example"
ENV["DATABASE_URL"] ||= "postgres:///left_wordle_api_test"

require "minitest/autorun"
require "rack/test"
require "mail"

Mail.defaults { delivery_method :test }

require_relative "../app"

module ApiTest
  include Rack::Test::Methods

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
end
