# frozen_string_literal: true

require_relative "test_helper"

require "webauthn/fake_client"

class WebauthnTest < Minitest::Test
  include ApiTest

  def setup
    origins = ENV["CORS_ORIGINS"].to_s.split(",").map(&:strip).reject(&:empty?)
    LeftWordleApi.set :allowed_origins, origins.freeze
    header "Authorization", "Bearer 1234"
    @created_user_ids = []
    @fake_client = WebAuthn::FakeClient.new(LeftWordleApi.settings.webauthn_origin)
  end

  def teardown
    User.where(id: @created_user_ids).destroy if @created_user_ids.any?
  end

  # -- Registration -------------------------------------------------------

  def test_register_new_account_without_email
    body = register_new_device!
    refute body["joined_existing_account"]
    assert body["user_id"]
    assert body["csrf_token"]

    get "/api/v2/profile"
    assert last_response.ok?
  end

  def test_register_rejects_an_invalid_email
    post_json "/api/v2/auth/register/begin", {email: "not-an-email"}

    assert_equal 400, last_response.status
  end

  def test_register_finish_rejects_a_forged_credential
    post_json "/api/v2/auth/register/begin", {}
    challenge = json_response["options"]["challenge"]
    track_pending_user!

    # Sign with a client whose origin doesn't match the configured RP origin.
    forged_client = WebAuthn::FakeClient.new("https://evil.example")
    forged_cred = forged_client.create(challenge: challenge)

    post_json "/api/v2/auth/register/finish", {credential: forged_cred}

    assert_equal 400, last_response.status
  end

  # -- Login ----------------------------------------------------------------

  def test_login_with_a_registered_passkey
    register_new_device!
    post "/api/v2/auth/logout"

    post_json "/api/v2/auth/login/begin", {}
    assert last_response.ok?
    challenge = json_response["options"]["challenge"]

    cred = @fake_client.get(challenge: challenge)
    post_json "/api/v2/auth/login/finish", {credential: cred}

    assert last_response.ok?
    assert json_response["csrf_token"]
  end

  def test_login_rejects_an_unknown_credential
    unregistered_client = WebAuthn::FakeClient.new(LeftWordleApi.settings.webauthn_origin)
    # The fake authenticator needs at least one credential to sign an
    # assertion with -- create one locally, but never register it with our
    # server, so the server genuinely has no matching PasskeyCredential.
    unregistered_client.create

    post_json "/api/v2/auth/login/begin", {}
    challenge = json_response["options"]["challenge"]
    cred = unregistered_client.get(challenge: challenge)

    post_json "/api/v2/auth/login/finish", {credential: cred}

    assert_equal 401, last_response.status
  end

  # -- Sessions and CSRF ----------------------------------------------------

  def test_state_changing_requests_require_a_valid_csrf_token
    register_new_device!

    put_json "/api/v2/profile/preferences", {darkTheme: true}
    assert_equal 403, last_response.status, "missing CSRF token should be rejected"

    put_json "/api/v2/profile/preferences", {darkTheme: true}, csrf_env("wrong-token")
    assert_equal 403, last_response.status, "wrong CSRF token should be rejected"
  end

  def test_logout_revokes_the_session
    register_new_device!
    post "/api/v2/auth/logout"
    assert last_response.ok?

    get "/api/v2/profile"
    assert_equal 401, last_response.status
  end

  def test_auth_endpoints_are_rate_limited_outside_test_env
    LeftWordleApi::RATE_LIMIT_BUCKETS.clear
    ENV["RACK_ENV"] = "development" # rate_limit! is a no-op under "test"
    LeftWordleApi::RATE_LIMIT_MAX_REQUESTS.times do
      post_json "/api/v2/auth/register/begin", {}
      refute_equal 429, last_response.status
      track_pending_user!
    end

    post_json "/api/v2/auth/register/begin", {}
    assert_equal 429, last_response.status
  ensure
    ENV["RACK_ENV"] = "test"
    LeftWordleApi::RATE_LIMIT_BUCKETS.clear
  end

  def test_unauthenticated_requests_are_rejected
    get "/api/v2/profile"
    assert_equal 401, last_response.status
  end

  # -- Device linking (QR / email) -------------------------------------------

  def test_device_link_qr_token_lets_a_second_device_join_the_account
    first_body = register_new_device!
    first_csrf = first_body["csrf_token"]

    post_json "/api/v2/auth/device_link", {delivery: "qr"}, csrf_env(first_csrf)
    assert last_response.ok?
    link_token = json_response["url"][/link_token=(.+)/, 1]
    refute_nil link_token

    with_second_device do
      post_json "/api/v2/auth/register/begin", {device_link_token: link_token}
      assert last_response.ok?
      challenge = json_response["options"]["challenge"]
      cred = @fake_client.create(challenge: challenge)

      post_json "/api/v2/auth/register/finish", {credential: cred, nickname: "Second"}
      assert_equal 201, last_response.status
      assert json_response["joined_existing_account"]
      assert_equal first_body["user_id"], json_response["user_id"]
    end
  end

  def test_device_link_token_is_single_use
    first_body = register_new_device!
    post_json "/api/v2/auth/device_link", {delivery: "qr"}, csrf_env(first_body["csrf_token"])
    link_token = json_response["url"][/link_token=(.+)/, 1]

    with_second_device do
      post_json "/api/v2/auth/register/begin", {device_link_token: link_token}
      challenge = json_response["options"]["challenge"]
      cred = @fake_client.create(challenge: challenge)
      post_json "/api/v2/auth/register/finish", {credential: cred}
      assert_equal 201, last_response.status, "first redemption should succeed"
    end

    with_second_device do
      post_json "/api/v2/auth/register/begin", {device_link_token: link_token}
      assert_equal 400, last_response.status, "a consumed link token must be rejected on reuse"
    end
  end

  def test_device_link_requires_email_for_email_delivery
    body = register_new_device!
    post_json "/api/v2/auth/device_link", {delivery: "email"}, csrf_env(body["csrf_token"])
    assert_equal 400, last_response.status
  end

  # -- Local data import (one-time) ------------------------------------------

  def test_import_local_data_is_one_time_only
    body = register_new_device!
    payload = {
      history: [
        {puzzle_num: 1, date: "2024-01-01", mode: "regular", game_status: "WIN",
         guesses: [["crane", "22222"]], device_id: "11111111-1111-1111-1111-111111111111"}
      ],
      preferences: {darkTheme: true},
      statistics: {currentStreak: 1, gamesPlayed: 1, gamesWon: 1}
    }

    post_json "/api/v2/import/local_data", payload, csrf_env(body["csrf_token"])
    assert last_response.ok?
    assert_equal 1, json_response["imported_games"]

    post_json "/api/v2/import/local_data", payload, csrf_env(body["csrf_token"])
    assert_equal 409, last_response.status

    get "/api/v2/history"
    assert_equal ["1"], json_response.keys
  end

  def test_import_local_data_records_a_new_user_creation_snapshot
    body = register_new_device!
    payload = {
      preferences: {darkTheme: true},
      statistics: {currentStreak: 1},
      # Not restored into any account column -- just along for the ride
      # into the snapshot as an extra safety net (see auth.js importLocalData).
      settings_backup: {"v1.0.0" => {ts: "2026-01-01T00:00:00Z"}}
    }

    post_json "/api/v2/import/local_data", payload, csrf_env(body["csrf_token"])
    assert last_response.ok?

    snapshot = StorageSnapshot.where(user_id: body["user_id"]).order(:created_at).last
    refute_nil snapshot
    assert_equal "new user creation", snapshot.event
    assert_equal true, snapshot.local_storage["preferences"]["darkTheme"]
    assert_equal "2026-01-01T00:00:00Z", snapshot.local_storage["settings_backup"]["v1.0.0"]["ts"]
  end

  # -- Storage snapshots (audit trail) -----------------------------------------

  def test_profile_download_records_an_update_client_local_storage_snapshot
    body = register_new_device!
    put_json "/api/v2/profile/preferences", {darkTheme: true}, csrf_env(body["csrf_token"])

    get "/api/v2/profile"
    assert last_response.ok?

    snapshot = StorageSnapshot.where(user_id: body["user_id"]).order(:created_at).last
    refute_nil snapshot
    assert_equal "update client local storage", snapshot.event
    assert_equal true, snapshot.local_storage["preferences"]["darkTheme"]
  end

  # -- Stats adjustment audit trail -------------------------------------------

  def test_stats_adjust_records_a_before_and_after_snapshot
    body = register_new_device!
    put_json "/api/v2/profile/statistics", {currentStreak: 2}, csrf_env(body["csrf_token"])

    post_json "/api/v2/stats/adjust", {currentStreak: 9}, csrf_env(body["csrf_token"])
    assert last_response.ok?
    assert_equal 9, json_response["statistics"]["currentStreak"]

    user = User[body["user_id"]]
    snapshot = StatsAdjustment.where(user_id: user.id).order(:created_at).last
    refute_nil snapshot
    assert_equal 2, snapshot.before["currentStreak"]
    assert_equal 9, snapshot.after["currentStreak"]
  end

  private

  def register_new_device!(email: nil)
    post_json "/api/v2/auth/register/begin", email ? {email: email} : {}
    assert last_response.ok?, last_response.body
    challenge = json_response["options"]["challenge"]
    track_pending_user!

    cred = @fake_client.create(challenge: challenge)
    post_json "/api/v2/auth/register/finish", {credential: cred, nickname: "Test Device"}
    assert_equal 201, last_response.status, last_response.body

    body = json_response
    @created_user_ids << body["user_id"]
    body
  end

  # register/begin already created the User row even though /finish hasn't
  # run yet -- track it defensively so a test that stops short of /finish
  # (e.g. the forged-credential test) still gets cleaned up.
  def track_pending_user!
    pending_user_id = json_response["options"]["user"]["id"]
    user = User.first(webauthn_user_id: pending_user_id)
    @created_user_ids << user.id if user
  end

  # Rack::Test's built-in named-session support: a fresh cookie jar,
  # exactly what simulating a second physical device needs.
  def with_second_device(&block)
    with_session(:second_device) do
      header "Authorization", "Bearer 1234"
      block.call
    end
  end
end
