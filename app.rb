# frozen_string_literal: true

require "json"
require "sinatra/base"

require_relative "lib/left_wordle/game"

class LeftWordleApi < Sinatra::Base
  configure do
    set :protection, except: :json_csrf
    set :show_exceptions, false
  end

  before do
    content_type :json
    headers cors_headers.merge("Cache-Control" => "no-store")
  end

  options "*" do
    status :no_content
  end

  get "/api/health" do
    json_response({status: "ok"})
  end

  get "/api/game/today" do
    puzzle = LeftWordle::Game.today

    json_response({
      puzzle_num: puzzle[:number],
      date: puzzle[:date].iso8601,
      word_length: LeftWordle::Game::WORD_LENGTH
    })
  end

  post "/api/game/guess" do
    payload = request_payload
    guess = payload.fetch("guess", "").to_s.downcase

    unless guess.match?(/\A[a-z]{#{LeftWordle::Game::WORD_LENGTH}}\z/o)
      halt_json(:bad_request, "Guess must be #{LeftWordle::Game::WORD_LENGTH} letters")
    end

    unless LeftWordle::Game.valid_guess?(guess)
      halt_json(:bad_request, "Not in word list")
    end

    row_index = row_index_from(payload)
    puzzle = LeftWordle::Game.today
    answer = LeftWordle::Game.answer_for(puzzle[:number])
    evaluation = LeftWordle::Game.evaluate(guess, answer)
    game_status = game_status_for(evaluation, row_index)

    json_response({
      evaluation: evaluation,
      game_status: game_status,
      row_index: row_index + 1,
      solution: (answer if game_status != "IN_PROGRESS")
    })
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
      {
        "Access-Control-Allow-Headers" => "Content-Type",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Origin" => ENV.fetch("CORS_ORIGIN", "*")
      }
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

    def halt_json(status, message)
      halt Rack::Utils.status_code(status), JSON.generate(detail: message)
    end

    def json_response(payload, status: :ok)
      status(status)
      JSON.generate(payload)
    end

    def request_payload
      body = request.body.read
      return {} if body.empty?

      JSON.parse(body)
    end

    def row_index_from(payload)
      row_index = Integer(payload.fetch("row_index", 0))
      return row_index if row_index.between?(0, LeftWordle::Game::MAX_GUESSES - 1)

      halt_json(:bad_request, "Row index must be between 0 and #{LeftWordle::Game::MAX_GUESSES - 1}")
    rescue ArgumentError, TypeError
      halt_json(:bad_request, "Row index must be an integer")
    end
  end
end
