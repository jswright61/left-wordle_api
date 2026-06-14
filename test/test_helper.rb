# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

require "minitest/autorun"
require "rack/test"

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
