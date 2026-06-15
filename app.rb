# frozen_string_literal: true

require "json"
require "sinatra/base"

require_relative "lib/left_wordle/game"

class LeftWordleApi < Sinatra::Base
  DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/

  configure do
    set :allowed_origins, ENV.fetch("CORS_ORIGINS", "").split(",").map(&:strip).reject(&:empty?).freeze
    set :protection, except: :json_csrf
    set :show_exceptions, false
  end

  before do
    content_type :json
    validate_request_origin!
    headers cors_headers.merge("Cache-Control" => "no-store")
  end

  options "*" do
    status :no_content
  end

  get "/api/health" do
    mark_deprecated!("/api/v1/health")
    health_response
  end

  get "/api/game/today" do
    mark_deprecated!("/api/v1/game/puzzle")
    puzzle_response
  end

  post "/api/game/guess" do
    mark_deprecated!("/api/v1/game/guess")
    guess_response
  end

  get "/api/v1/health" do
    health_response
  end

  get "/api/v1/game/puzzle" do
    puzzle_response
  end

  post "/api/v1/game/guess" do
    guess_response
  end

  not_found do
    json_response({detail: "Not found"}, status: :not_found)
  end

  error JSON::ParserError do
    json_response({detail: "Request body must be valid JSON"}, status: :bad_request)
  end

  error do
    json_response({detail: "Internal server error"}, status: :internal_server_error)
  end

  helpers do
    def cors_headers
      origin = request.env["HTTP_ORIGIN"]
      headers = {
        "Access-Control-Allow-Headers" => "Content-Type",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Vary" => "Origin"
      }

      headers["Access-Control-Allow-Origin"] = origin if settings.allowed_origins.include?(origin)
      headers
    end

    def game_status_for(evaluation, row_index)
      if evaluation.all?(LeftWordle::Game::CORRECT)
        "WIN"
      elsif row_index >= LeftWordle::Game::MAX_GUESSES - 1
        "FAIL"
      else
        "IN_PROGRESS"
      end
    end

    def guess_response
      payload = request_payload
      date = requested_date(payload["date"])
      guess = payload.fetch("guess", "").to_s.downcase

      unless guess.match?(/\A[a-z]{#{LeftWordle::Game::WORD_LENGTH}}\z/o)
        halt_json(:bad_request, "Guess must be #{LeftWordle::Game::WORD_LENGTH} letters")
      end

      unless LeftWordle::Game.valid_guess?(guess)
        halt_json(:bad_request, "Not in word list")
      end

      row_index = row_index_from(payload)
      puzzle_number = LeftWordle::Game.puzzle_number_for(date)
      answer = LeftWordle::Game.answer_for(puzzle_number)
      evaluation = LeftWordle::Game.evaluate(guess, answer)
      game_status = game_status_for(evaluation, row_index)

      json_response({
        date: date.iso8601,
        evaluation: evaluation,
        game_status: game_status,
        puzzle_num: puzzle_number,
        row_index: row_index + 1,
        solution: (answer if game_status != "IN_PROGRESS")
      })
    end

    def halt_json(status, message)
      halt Rack::Utils.status_code(status), JSON.generate(detail: message)
    end

    def health_response
      json_response({status: "ok"})
    end

    def json_response(payload, status: :ok)
      status(status)
      JSON.generate(payload)
    end

    def mark_deprecated!(successor_path)
      headers(
        "Deprecation" => "true",
        "Link" => %(<#{successor_path}>; rel="successor-version")
      )
    end

    def puzzle_response
      date = requested_date(params["date"])
      puzzle_number = LeftWordle::Game.puzzle_number_for(date)

      json_response({
        puzzle_num: puzzle_number,
        date: date.iso8601,
        word_length: LeftWordle::Game::WORD_LENGTH
      })
    end

    def request_payload
      body = request.body.read
      return {} if body.empty?

      payload = JSON.parse(body)
      halt_json(:bad_request, "Request body must be a JSON object") unless payload.is_a?(Hash)

      payload
    end

    def requested_date(value)
      halt_json(:bad_request, "Date is required") if value.nil?
      halt_json(:bad_request, "Date must use YYYY-MM-DD format") unless value.is_a?(String) && value.match?(DATE_PATTERN)

      date = Date.iso8601(value)
      latest_date = LeftWordle::Game.latest_available_date

      halt_json(:bad_request, "Date cannot be later than #{latest_date.iso8601}") if date > latest_date

      date
    rescue Date::Error
      halt_json(:bad_request, "Date must be a valid calendar date")
    end

    def row_index_from(payload)
      row_index = Integer(payload.fetch("row_index", 0))
      return row_index if row_index.between?(0, LeftWordle::Game::MAX_GUESSES - 1)

      halt_json(:bad_request, "Row index must be between 0 and #{LeftWordle::Game::MAX_GUESSES - 1}")
    rescue ArgumentError, TypeError
      halt_json(:bad_request, "Row index must be an integer")
    end

    def validate_request_origin!
      origin = request.env["HTTP_ORIGIN"]
      return if origin.nil? || settings.allowed_origins.include?(origin)

      halt_json(:forbidden, "Origin not allowed")
    end
  end
end
