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

  def test_register_rejects_an_email_already_in_use
    register_new_device!(email: "taken@example.com")

    with_second_device do
      post_json "/api/v2/auth/register/begin", {email: "taken@example.com"}

      assert_equal 409, last_response.status
      assert_match(/already in use/, json_response.fetch("detail"))
    end
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

  # -- Passkey review / revoke -----------------------------------------------

  def test_list_passkeys_requires_authentication
    get "/api/v2/account/passkeys"
    assert_equal 401, last_response.status
  end

  def test_cannot_revoke_your_only_passkey_without_an_email
    body = register_new_device!
    get "/api/v2/account/passkeys"
    passkey_id = json_response["passkeys"].first["id"]

    delete "/api/v2/account/passkeys/#{passkey_id}", {}, csrf_env(body["csrf_token"])
    assert_equal 400, last_response.status
  end

  def test_can_revoke_your_only_passkey_when_an_email_is_set
    body = register_new_device!(email: "lastkey@example.com")
    get "/api/v2/account/passkeys"
    passkey_id = json_response["passkeys"].first["id"]

    delete "/api/v2/account/passkeys/#{passkey_id}", {}, csrf_env(body["csrf_token"])
    assert last_response.ok?
    assert_equal "revoked", json_response["status"]
  end

  def test_revoking_a_passkey_excludes_it_from_list_and_login
    first_body = register_new_device!
    add_second_passkey!(first_body["csrf_token"])

    get "/api/v2/account/passkeys"
    device_a_id = json_response["passkeys"].find { |pk| pk["nickname"] == "Test Device" }["id"]

    delete "/api/v2/account/passkeys/#{device_a_id}", {}, csrf_env(first_body["csrf_token"])
    assert last_response.ok?
    assert_equal "revoked", json_response["status"]

    get "/api/v2/account/passkeys"
    remaining_nicknames = json_response["passkeys"].map { |pk| pk["nickname"] }
    refute_includes remaining_nicknames, "Test Device"
    assert_includes remaining_nicknames, "Second"

    post "/api/v2/auth/logout"
    post_json "/api/v2/auth/login/begin", {}
    challenge = json_response["options"]["challenge"]
    cred = @fake_client.get(challenge: challenge) # first-created credential on this client -- the one just revoked
    post_json "/api/v2/auth/login/finish", {credential: cred}
    assert_equal 401, last_response.status
  end

  def test_register_begin_excludes_only_active_passkeys
    first_body = register_new_device!
    passkey = PasskeyCredential.first(user_id: first_body["user_id"])
    passkey.update(revoked_at: Time.now)

    post_json "/api/v2/auth/device_link", {delivery: "qr"}, csrf_env(first_body["csrf_token"])
    link_token = json_response["url"][/link_token=(.+)/, 1]

    with_second_device do
      post_json "/api/v2/auth/register/begin", {device_link_token: link_token}
      assert_equal [], json_response["options"]["excludeCredentials"]
    end
  end

  # -- Account recovery -------------------------------------------------------

  def test_recover_sends_an_email_when_the_account_exists
    register_new_device!(email: "recover@example.com")

    with_smtp_configured do
      Mail::TestMailer.deliveries.clear
      post_json "/api/v2/auth/recover", {email: "recover@example.com"}

      assert last_response.ok?
      assert_equal "sent", json_response["status"]
      assert_equal 1, Mail::TestMailer.deliveries.length

      mail = Mail::TestMailer.deliveries.first
      assert_equal "Recover access to your Left Wordle account", mail.subject
      assert_equal ["recover@example.com"], mail.to
    end
  end

  def test_recover_responds_identically_when_no_account_matches
    with_smtp_configured do
      Mail::TestMailer.deliveries.clear
      post_json "/api/v2/auth/recover", {email: "nobody@example.com"}

      assert last_response.ok?
      assert_equal "sent", json_response["status"]
      assert_equal 0, Mail::TestMailer.deliveries.length
    end
  end

  def test_recover_link_registers_a_new_passkey_without_an_existing_session
    first_body = register_new_device!(email: "recover2@example.com")
    post "/api/v2/auth/logout"

    link_token = nil
    with_smtp_configured do
      Mail::TestMailer.deliveries.clear
      post_json "/api/v2/auth/recover", {email: "recover2@example.com"}
      mail = Mail::TestMailer.deliveries.first
      link_token = mail.body.to_s[/link_token=(\S+)/, 1]
    end
    refute_nil link_token

    with_second_device do
      post_json "/api/v2/auth/register/begin", {device_link_token: link_token}
      assert last_response.ok?
      challenge = json_response["options"]["challenge"]
      cred = @fake_client.create(challenge: challenge)

      post_json "/api/v2/auth/register/finish", {credential: cred, nickname: "Recovered Device"}
      assert_equal 201, last_response.status
      assert json_response["joined_existing_account"]
      assert_equal first_body["user_id"], json_response["user_id"]
    end
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
    # Statistics are server-derived (see app.rb's apply_played_game_to_statistics!),
    # not settable via a client PUT -- seed the "before" value directly.
    # register_new_device! doesn't create a user_profiles row on its own, so this is
    # a create, not an update.
    UserProfile.create(user_id: body["user_id"], statistics: Sequel.pg_json({currentStreak: 2}))

    post_json "/api/v2/stats/adjust", {currentStreak: 9}, csrf_env(body["csrf_token"])
    assert last_response.ok?
    assert_equal 9, json_response["statistics"]["currentStreak"]

    user = User[body["user_id"]]
    snapshot = StatsAdjustment.where(user_id: user.id).order(:created_at).last
    refute_nil snapshot
    assert_equal 2, snapshot.before["currentStreak"]
    assert_equal 9, snapshot.after["currentStreak"]
  end

  # -- Stats/streak derivation from played_games events -----------------------

  def test_history_import_extends_streak_for_contiguous_wins
    body = register_new_device!
    device_id = SecureRandom.uuid
    import_history!([
      {puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_id},
      {puzzle_num: 501, date: "2026-01-02", game_status: "WIN", guesses: n_guesses(4), device_id: device_id}
    ], body["csrf_token"])

    stats = get_profile!["statistics"]
    assert_equal 2, stats["gamesPlayed"]
    assert_equal 2, stats["gamesWon"]
    assert_equal 2, stats["currentStreak"]
    assert_equal 2, stats["maxStreak"]
    assert_equal 501, stats["currentStreakAnchorPuzzleNum"]
    assert_equal 1, stats["guesses"]["3"]
    assert_equal 1, stats["guesses"]["4"]
  end

  def test_history_import_gap_is_archival_only_and_does_not_move_stats
    body = register_new_device!
    csrf = body["csrf_token"]
    device_id = SecureRandom.uuid
    import_history!([{puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_id}], csrf)
    # Puzzle 501 never arrives -- 502 lands with a gap behind it.
    import_history!([{puzzle_num: 502, date: "2026-01-03", game_status: "WIN", guesses: n_guesses(2), device_id: device_id}], csrf)

    stats = get_profile!["statistics"]
    assert_equal 1, stats["gamesPlayed"], "the gapped puzzle must not count toward stats"
    assert_equal 500, stats["currentStreakAnchorPuzzleNum"]

    history = json_get("/api/v2/history")
    assert history.key?("502"), "the gapped game must still be preserved in history"
  end

  def test_fail_at_anchor_plus_one_resets_current_streak_but_keeps_max_streak
    body = register_new_device!
    device_id = SecureRandom.uuid
    import_history!([
      {puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_id},
      {puzzle_num: 501, date: "2026-01-02", game_status: "FAIL", guesses: n_guesses(6), device_id: device_id}
    ], body["csrf_token"])

    stats = get_profile!["statistics"]
    assert_equal 0, stats["currentStreak"]
    assert_equal 1, stats["maxStreak"]
    assert_equal 501, stats["currentStreakAnchorPuzzleNum"]
    assert_equal 2, stats["gamesPlayed"]
    assert_equal 1, stats["guesses"]["fail"]
  end

  def test_multi_device_same_puzzle_first_arrival_wins_and_loser_is_preserved
    body = register_new_device!
    csrf = body["csrf_token"]
    device_a = SecureRandom.uuid
    device_b = SecureRandom.uuid

    import_history!([{puzzle_num: 700, date: "2026-03-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_a}], csrf)
    import_history!([{puzzle_num: 700, date: "2026-03-01", game_status: "FAIL", guesses: n_guesses(6), device_id: device_b}], csrf)

    stats = get_profile!["statistics"]
    assert_equal 1, stats["gamesPlayed"], "only the canonical (first-arrival) row should count"
    assert_equal 1, stats["gamesWon"]
    assert_equal 1, stats["currentStreak"]

    history = json_get("/api/v2/history")
    assert_equal "WIN", history["700"]["game_status"], "history should surface the first-arriving (canonical) row"

    rows = PlayedGame.where(user_id: body["user_id"], puzzle_num: 700).all
    assert_equal 2, rows.length, "the losing device's row must be preserved, not discarded"
    assert(rows.any? { |r| r.client_device_id == device_b && r.game_status == "FAIL" })
  end

  private

  def import_history!(entries, csrf_token)
    post_json "/api/v2/history/import", {history: entries}, csrf_env(csrf_token)
    assert last_response.ok?, last_response.body
    json_response
  end

  def get_profile!
    get "/api/v2/profile"
    assert last_response.ok?, last_response.body
    json_response
  end

  def json_get(path)
    get path
    assert last_response.ok?, last_response.body
    json_response
  end

  # played_games.guesses isn't format-validated on import -- only its
  # length matters to the stats/streak derivation under test here.
  def n_guesses(count)
    Array.new(count) { ["crane", "01001"] }
  end

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

  def add_second_passkey!(csrf_token, nickname: "Second")
    post_json "/api/v2/auth/device_link", {delivery: "qr"}, csrf_env(csrf_token)
    link_token = json_response["url"][/link_token=(.+)/, 1]

    with_second_device do
      post_json "/api/v2/auth/register/begin", {device_link_token: link_token}
      challenge = json_response["options"]["challenge"]
      cred = @fake_client.create(challenge: challenge)
      post_json "/api/v2/auth/register/finish", {credential: cred, nickname: nickname}
      assert_equal 201, last_response.status, last_response.body
    end
  end
end
