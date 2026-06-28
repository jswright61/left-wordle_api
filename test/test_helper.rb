# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV["CORS_ORIGINS"] = "https://left-wordle.example, https://alternate.example"

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

  def post_json(path, payload)
    post path, JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}
  end
end
