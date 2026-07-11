# frozen_string_literal: true

require "base64"

require_relative "test_helper"

class GuesserTest < Minitest::Test
  include ApiTest

  def setup
    @original_engine = LeftWordleApi.settings.engine
    LeftWordleApi.set :engine, SolveEngine.new(StubGuesser.new)
    @test_user = GuesserUser.find_or_create(username: "test") { |u|
      u.password = "secret"
      u.approved_at = Time.now
    }
    authorize "test", "secret"
  end

  def teardown
    LeftWordleApi.set :engine, @original_engine
    @test_user.destroy
  end

  def test_guesser_requires_auth
    header "Authorization", nil
    get "/guesser"
    assert_equal 401, last_response.status
  end

  def test_guesser_rejects_wrong_password
    authorize "test", "wrong"
    get "/guesser"
    assert_equal 401, last_response.status
  end

  def test_guesser_rejects_unapproved_user
    @test_user.update(approved_at: nil)
    authorize "test", "secret"
    get "/guesser"
    assert_equal 401, last_response.status
  end

  def test_guesser_rejects_not_yet_approved_user
    @test_user.update(approved_at: Time.now + 3600)
    authorize "test", "secret"
    get "/guesser"
    assert_equal 401, last_response.status
  end

  def test_guesser_rejects_deactivated_user
    @test_user.update(deactivated_at: Time.now - 3600)
    authorize "test", "secret"
    get "/guesser"
    assert_equal 401, last_response.status
  end

  def test_guesser_allows_user_deactivated_in_the_future
    @test_user.update(deactivated_at: Time.now + 3600)
    authorize "test", "secret"
    get "/guesser"
    assert last_response.ok?
  end

  def test_home_page_loads
    get "/guesser"
    assert last_response.ok?
    assert_includes last_response.body, "Wordle Guesser"
  end

  def test_starter_choices_are_returned_as_json
    get "/guesser/api/starter-choices"
    body = json_response

    assert last_response.ok?
    assert_equal "SOARE", body.fetch("starter_choices").first.fetch("word")
  end

  def test_start_rejects_an_illegal_starter
    post_guesser_json("/guesser/api/start", starter: "XXXXX")

    assert_equal 422, last_response.status
    assert_includes json_response.fetch("error"), "legal"
  end

  def test_start_returns_browser_owned_game_state
    post_guesser_json("/guesser/api/start", starter: "soare")
    body = json_response

    assert last_response.ok?
    assert_equal "SOARE", body.fetch("current_guess")
    assert_equal 3, body.fetch("remaining_count")
    assert_equal %w[BLIND CHUNK FIGHT], body.fetch("remaining")
    assert_equal %w[CHUNK FIGHT], body.fetch("unused_possibilities")
  end

  def test_evaluate_returns_evaluation_string_for_valid_guess
    post_guesser_json("/guesser/api/evaluate", guess: "crane", date: "2021-06-19")
    body = json_response

    assert last_response.ok?
    assert_match(/\A[012]{5}\z/, body.fetch("evaluation"))
  end

  def test_evaluate_rejects_an_illegal_guess
    post_guesser_json("/guesser/api/evaluate", guess: "zzzzz", date: "2021-06-19")

    assert_equal 422, last_response.status
    assert_includes json_response.fetch("error"), "legal"
  end

  def test_validate_word_reports_legal_and_remaining_membership
    post_guesser_json("/guesser/api/validate-word", word: "chunk", remaining: %w[BLIND CHUNK])
    body = json_response

    assert_equal true, body.fetch("valid")
    assert_equal true, body.fetch("in_remaining")
  end

  def test_turn_returns_next_suggestions
    post_guesser_json(
      "/guesser/api/turn",
      attempt: 1,
      guess: "SOARE",
      pattern: "00000",
      remaining: %w[BLIND CHUNK FIGHT]
    )
    body = json_response

    assert last_response.ok?
    assert_equal "continue", body.fetch("status")
    assert_equal 2, body.fetch("attempt")
    assert_equal "CHUNK", body.fetch("suggestions").first.fetch("word")
    assert_equal true, body.fetch("suggestions").first.fetch("unused_answer")
    assert_equal true, body.fetch("suggestions")[1].fetch("unused_answer")
    assert_equal false, body.fetch("suggestions").last.fetch("unused_answer")
    assert_equal ["CHUNK"], body.fetch("unused_possibilities")
  end

  def test_turn_applies_late_game_unused_bonus_when_few_answers_remain
    post_guesser_json(
      "/guesser/api/turn",
      attempt: 1,
      guess: "SOARE",
      pattern: "00000",
      remaining: %w[BLIND CHUNK FIGHT]
    )
    opts = LeftWordleApi.settings.engine.guesser.weighted_guess_options

    assert_equal 0.2, opts.fetch(:preferred_answer_bonus)
    assert_equal %w[CHUNK FIGHT], opts.fetch(:preferred_answers)
  end

  def test_solved_turn_returns_terminal_state
    post_guesser_json(
      "/guesser/api/turn",
      attempt: 1,
      guess: "SOARE",
      pattern: "22222",
      remaining: %w[BLIND CHUNK FIGHT]
    )
    body = json_response

    assert last_response.ok?
    assert_equal "solved", body.fetch("status")
    assert_equal 0, body.fetch("remaining_count")
  end

  def test_existing_api_routes_are_unaffected
    header "Authorization", "Bearer 1234"
    get "/api/v1/health"
    assert last_response.ok?
    assert_equal({"status" => "ok"}, json_response)
  end

  private

  def post_guesser_json(path, payload)
    post path, JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}
  end

  class StubGuesser < WordleGuesser
    def legal_words(force: false)
      %w[SOARE BLIND CHUNK FIGHT CRANE]
    end

    def orig_answers(force: false)
      %w[BLIND CHUNK FIGHT]
    end

    def unused
      %w[CHUNK FIGHT]
    end

    def starter_choices(today: Date.today)
      [{word: "SOARE", entropy: 5.8, group: :legal_words}]
    end

    def filter_words(words, guess, pattern)
      return words if pattern == [2, 2, 2, 2, 2]
      words.first(2)
    end

    attr_reader :weighted_guess_options

    def find_weighted_guesses(*, **opts)
      @weighted_guess_options = opts
      [
        {word: "CHUNK", entropy: 1.5, weighted_entropy: 1.6, in_answer: true},
        {word: "FIGHT", entropy: 1.45, weighted_entropy: 1.45, in_answer: false},
        {word: "CRANE", entropy: 1.4, weighted_entropy: 1.4, in_answer: false}
      ]
    end
  end
end
