# frozen_string_literal: true

require_relative "test_helper"

require "webauthn/fake_client"

class WebauthnTest < Minitest::Test
  include ApiTest

  def setup
    LeftWordleApi.set :allowed_origins, TEST_ALLOWED_ORIGINS
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

  def test_local_storage_snapshot_records_a_new_user_creation_event
    body = register_new_device!
    post_json "/api/v2/profile/local_storage_snapshot",
      {event: "new user creation", local_storage: {statistics: {gamesPlayed: 3}}},
      csrf_env(body["csrf_token"])

    assert last_response.ok?, last_response.body

    snapshot = StorageSnapshot.where(user_id: body["user_id"]).order(:created_at).last
    refute_nil snapshot
    assert_equal "new user creation", snapshot.event
    assert_equal 3, snapshot.local_storage["statistics"]["gamesPlayed"]
  end

  def test_local_storage_snapshot_rejects_an_unrecognized_event
    body = register_new_device!
    post_json "/api/v2/profile/local_storage_snapshot",
      {event: "made up event", local_storage: {}},
      csrf_env(body["csrf_token"])

    assert_equal 400, last_response.status
  end

  def test_local_storage_snapshot_rejects_a_non_object_local_storage
    body = register_new_device!
    post_json "/api/v2/profile/local_storage_snapshot",
      {event: "new user creation", local_storage: "not an object"},
      csrf_env(body["csrf_token"])

    assert_equal 400, last_response.status
  end

  def test_local_storage_snapshot_requires_authentication
    post_json "/api/v2/profile/local_storage_snapshot", {event: "new user creation", local_storage: {}}
    assert_equal 401, last_response.status
  end

  def test_local_storage_snapshot_requires_csrf
    body = register_new_device!
    post_json "/api/v2/profile/local_storage_snapshot", {event: "new user creation", local_storage: {}}
    assert_equal 403, last_response.status
  end

  # -- Stats adjustment audit trail -------------------------------------------

  def test_stats_adjust_records_a_before_and_after_snapshot
    body = register_new_device!
    # Statistics are server-derived (see app.rb's apply_played_game_to_statistics!),
    # not settable via a client PUT -- seed the "before" value directly.
    # register_new_device! doesn't create a user_profiles row on its own, so this is
    # a create, not an update.
    UserProfile.create(user_id: body["user_id"], statistics: Sequel.pg_json({currentStreak: 2}))

    adjust_stats!({currentStreak: 9}, "manual", body["csrf_token"])
    assert_equal 9, json_response["statistics"]["currentStreak"]

    user = User[body["user_id"]]
    snapshot = StatsAdjustment.where(user_id: user.id).order(:created_at).last
    refute_nil snapshot
    assert_equal 2, snapshot.before["currentStreak"]
    assert_equal 9, snapshot.after["currentStreak"]
    assert_equal "manual", snapshot.source
    assert_equal "Manual adjustment via Tools > Adjust Stats", snapshot.event_desc
  end

  def test_stats_adjust_records_the_signup_reconciliation_source
    body = register_new_device!
    adjust_stats!({currentStreak: 12}, "signup_reconciliation", body["csrf_token"])

    snapshot = StatsAdjustment.where(user_id: body["user_id"]).order(:created_at).last
    assert_equal "signup_reconciliation", snapshot.source
    assert_equal "Post-signup local-totals reconciliation", snapshot.event_desc
  end

  def test_stats_adjust_rejects_an_unrecognized_source
    body = register_new_device!
    post_json "/api/v2/stats/adjust", {statistics: {currentStreak: 9}, source: "made_up"}, csrf_env(body["csrf_token"])
    assert_equal 400, last_response.status
  end

  def test_stats_adjust_rejects_a_missing_statistics_object
    body = register_new_device!
    post_json "/api/v2/stats/adjust", {source: "manual"}, csrf_env(body["csrf_token"])
    assert_equal 400, last_response.status
  end

  def test_stats_adjust_rejects_game_completion_as_a_client_supplied_source
    body = register_new_device!
    post_json "/api/v2/stats/adjust", {statistics: {currentStreak: 9}, source: "game_completion"}, csrf_env(body["csrf_token"])
    assert_equal 400, last_response.status, "game_completion is recorded internally only, never by a client"
  end

  def test_stats_adjust_preserves_the_existing_streak_anchor
    body = register_new_device!
    csrf = body["csrf_token"]
    device_id = SecureRandom.uuid
    import_history!([{puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_id}], csrf)
    assert_equal 500, get_profile!["statistics"]["currentStreakAnchorPuzzleNum"]

    # The client has no concept of the anchor and never sends one -- this
    # mirrors the real payload shape from Adjust Stats / the post-signup
    # "carry over local totals" reconciliation, neither of which includes it.
    adjust_stats!({currentStreak: 50, maxStreak: 50, gamesPlayed: 50, gamesWon: 50}, "manual", csrf)

    stats = get_profile!["statistics"]
    assert_equal 50, stats["currentStreak"], "the adjusted totals must land exactly as sent -- no surprise numbers"
    assert_equal 500, stats["currentStreakAnchorPuzzleNum"], "the anchor must survive an adjustment that never mentions it"
  end

  def test_play_immediately_after_an_adjustment_still_continues_the_adjusted_streak
    body = register_new_device!
    csrf = body["csrf_token"]
    device_id = SecureRandom.uuid
    import_history!([{puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_id}], csrf)

    adjust_stats!({currentStreak: 50, maxStreak: 50, gamesPlayed: 50, gamesWon: 50}, "manual", csrf)

    # Puzzle 501 is exactly anchor + 1 -- a real continuation, not a gap.
    import_history!([{puzzle_num: 501, date: "2026-01-02", game_status: "WIN", guesses: n_guesses(3), device_id: device_id}], csrf)

    stats = get_profile!["statistics"]
    assert_equal 51, stats["currentStreak"], "consecutive play must build on the adjusted total, not reset it"
    assert_equal 51, stats["maxStreak"]
  end

  def test_gap_after_an_adjustment_resets_the_streak_instead_of_jumping_it
    body = register_new_device!
    csrf = body["csrf_token"]
    device_id = SecureRandom.uuid
    import_history!([{puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_id}], csrf)

    adjust_stats!({currentStreak: 50, maxStreak: 50, gamesPlayed: 50, gamesWon: 50}, "manual", csrf)

    # Puzzle 550 is nowhere near anchor + 1 -- without the anchor surviving
    # the adjustment, this would apply unconditionally (nil anchor accepts
    # any puzzle_num) and blindly increment the adjusted 50 to 51, exactly
    # the bug that prompted this fix.
    import_history!([{puzzle_num: 550, date: "2026-02-19", game_status: "WIN", guesses: n_guesses(4), device_id: device_id}], csrf)

    stats = get_profile!["statistics"]
    assert_equal 1, stats["currentStreak"], "a real gap must reset the streak, not extend the adjusted total"
    assert_equal 50, stats["maxStreak"], "maxStreak must not rise just because a gapped game was played"
    assert_equal 550, stats["currentStreakAnchorPuzzleNum"]
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

  def test_history_import_records_a_game_completion_event_for_each_puzzle_that_moves_stats
    body = register_new_device!
    device_id = SecureRandom.uuid
    import_history!([
      {puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_id},
      {puzzle_num: 501, date: "2026-01-02", game_status: "FAIL", guesses: n_guesses(6), device_id: device_id}
    ], body["csrf_token"])

    events = StatsAdjustment.where(user_id: body["user_id"], source: "game_completion").order(:created_at).all
    assert_equal 2, events.length
    assert_equal "Puzzle #500 completed (WIN)", events[0].event_desc
    assert_equal "Puzzle #501 completed (FAIL)", events[1].event_desc
    assert_equal 1, events[0].after["gamesPlayed"]
    assert_equal 2, events[1].after["gamesPlayed"]
  end

  def test_history_import_does_not_record_an_event_for_a_puzzle_that_did_not_move_stats
    body = register_new_device!
    csrf = body["csrf_token"]
    device_id = SecureRandom.uuid
    import_history!([{puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_id}], csrf)
    # Behind the anchor -- archival only, no stats change.
    import_history!([{puzzle_num: 499, date: "2025-12-31", game_status: "WIN", guesses: n_guesses(2), device_id: device_id}], csrf)

    events = StatsAdjustment.where(user_id: body["user_id"], source: "game_completion").all
    assert_equal 1, events.length, "only the puzzle that actually moved stats should be recorded"
  end

  def test_history_import_gap_resets_current_streak_but_still_counts
    body = register_new_device!
    csrf = body["csrf_token"]
    device_id = SecureRandom.uuid
    import_history!([{puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_id}], csrf)
    # Puzzle 501 never arrives -- 502 lands with a gap behind it. A gap must
    # not leave stats frozen forever (nothing else ever advances the anchor
    # once it's set) -- it should count and reset the streak instead.
    import_history!([{puzzle_num: 502, date: "2026-01-03", game_status: "WIN", guesses: n_guesses(2), device_id: device_id}], csrf)

    stats = get_profile!["statistics"]
    assert_equal 2, stats["gamesPlayed"], "the gapped puzzle must still count toward stats"
    assert_equal 1, stats["currentStreak"], "a gap breaks the streak instead of continuing it"
    assert_equal 1, stats["maxStreak"]
    assert_equal 502, stats["currentStreakAnchorPuzzleNum"], "the anchor must advance so future plays aren't compared against a stale gap forever"

    history = json_get("/api/v2/history")
    assert history.key?("502"), "the gapped game must still be preserved in history"
  end

  def test_history_import_at_or_behind_anchor_is_archival_only_and_does_not_move_stats
    body = register_new_device!
    csrf = body["csrf_token"]
    device_id = SecureRandom.uuid
    import_history!([{puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_id}], csrf)
    # A duplicate of the anchor's own puzzle, and an older backfill behind
    # it, must never move stats or rewind the anchor.
    import_history!([
      {puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: SecureRandom.uuid},
      {puzzle_num: 499, date: "2025-12-31", game_status: "WIN", guesses: n_guesses(2), device_id: device_id}
    ], csrf)

    stats = get_profile!["statistics"]
    assert_equal 1, stats["gamesPlayed"]
    assert_equal 500, stats["currentStreakAnchorPuzzleNum"]

    history = json_get("/api/v2/history")
    assert history.key?("499"), "the archival-only game must still be preserved in history"
  end

  def test_history_import_response_reports_why_each_entry_did_or_did_not_move_stats
    body = register_new_device!
    csrf = body["csrf_token"]
    device_a = SecureRandom.uuid
    device_b = SecureRandom.uuid
    import_history!([{puzzle_num: 500, date: "2026-01-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_a}], csrf)

    result = import_history!([
      {puzzle_num: 501, date: "2026-01-02", game_status: "WIN", guesses: n_guesses(3), device_id: device_a}, # applied
      {puzzle_num: 499, date: "2025-12-31", game_status: "WIN", guesses: n_guesses(2), device_id: device_a}, # archival: behind the anchor
      {puzzle_num: 501, date: "2026-01-02", game_status: "FAIL", guesses: n_guesses(6), device_id: device_b} # non_canonical: loses to device_a's earlier-arriving WIN
    ], csrf)

    assert_equal 1, result["stats_applied"]
    assert_equal({"archival" => 1, "non_canonical" => 1}, result["stats_skip_reasons"])
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

  def test_history_import_cannot_reassign_a_row_already_attached_to_another_user
    device_id = SecureRandom.uuid

    first_body = register_new_device!
    import_history!([{puzzle_num: 800, date: "2026-04-01", game_status: "WIN", guesses: n_guesses(3), device_id: device_id}], first_body["csrf_token"])
    owner_id = first_body["user_id"]

    with_second_device do
      second_body = register_new_device!
      import_history!([{puzzle_num: 800, date: "2026-04-01", game_status: "FAIL", guesses: n_guesses(6), device_id: device_id}], second_body["csrf_token"])

      row = PlayedGame.first(client_device_id: device_id, date: Date.new(2026, 4, 1))
      assert_equal owner_id, row.user_id, "an import must never re-assign a row already attached to another user"

      history = json_get("/api/v2/history")
      assert_nil history["800"], "the row must not surface in the second user's history"
    end
  end

  def test_live_play_cannot_take_over_another_users_row
    device_id = SecureRandom.uuid
    date = "2026-04-03"

    owner = register_new_device!
    post_json "/api/v1/game/progress",
      {date: date, mode: "regular", guesses: [["crane", "01001"]]},
      {"HTTP_X_DEVICE_ID" => device_id}

    row = PlayedGame.first(client_device_id: device_id, date: Date.parse(date))
    assert_equal owner["user_id"], row.user_id, "precondition: the row belongs to the first user"

    with_second_device do
      register_new_device!
      # Same device id and date, from a different authenticated account --
      # the takeover attempt this scoping exists to stop.
      post_json "/api/v1/game/progress",
        {date: date, mode: "regular", guesses: [["stole", "22222"], ["plate", "11111"]]},
        {"HTTP_X_DEVICE_ID" => device_id}

      row = PlayedGame.first(client_device_id: device_id, date: Date.parse(date))
      assert_equal owner["user_id"], row.user_id, "a second user must never take ownership of an existing row"
      assert_equal 1, row.guesses.length, "the other user's guesses must not be overwritten either"

      history = json_get("/api/v2/history")
      assert_empty history, "the row must not surface in the second user's history"
    end
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  # Phase 0.5 (docs/ownership_rework.md): anonymous updates are
  # scoped to unclaimed rows. Anyone can send a claimed row's device id and
  # date without a session, so an anonymous "completion" used to poison the
  # canonical row and bounce the owner's real win as :non_canonical.
  def test_anonymous_play_cannot_alter_a_row_attached_to_a_user
    device_id = SecureRandom.uuid
    date = "2026-04-04"

    owner = register_new_device!
    post_json "/api/v1/game/progress",
      {date: date, mode: "regular", guesses: [["crane", "01001"]]},
      {"HTTP_X_DEVICE_ID" => device_id}

    with_second_device do
      post_json "/api/v1/game/complete",
        {date: date, mode: "regular", game_status: "FAIL", guesses: n_guesses(6)},
        {"HTTP_X_DEVICE_ID" => device_id}
    end

    row = PlayedGame.first(client_device_id: device_id, date: Date.parse(date))
    assert_equal owner["user_id"], row.user_id, "the row must stay attached to its owner"
    assert_nil row.game_status, "an anonymous write must not set game_status on a claimed row"
    assert_equal 1, row.guesses.length, "an anonymous write must not overwrite a claimed row's guesses"

    # And the owner's real completion still counts -- the poison this
    # scoping exists to prevent.
    post_json "/api/v1/game/complete",
      {date: date, mode: "regular", game_status: "WIN", guesses: [["crane", "01001"], ["stole", "22222"]]},
      {"HTTP_X_DEVICE_ID" => device_id}
    assert_equal 1, get_profile!["statistics"]["gamesWon"]
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  def test_anonymous_play_still_updates_its_own_unclaimed_row
    device_id = SecureRandom.uuid
    date = "2026-04-04"

    with_second_device do
      post_json "/api/v1/game/progress",
        {date: date, mode: "regular", guesses: [["crane", "01001"]]},
        {"HTTP_X_DEVICE_ID" => device_id}
      post_json "/api/v1/game/complete",
        {date: date, mode: "regular", game_status: "WIN", guesses: [["crane", "01001"], ["stole", "22222"]]},
        {"HTTP_X_DEVICE_ID" => device_id}
    end

    row = PlayedGame.first(client_device_id: device_id, date: Date.parse(date))
    assert_equal "WIN", row.game_status, "anonymous telemetry must keep flowing to unclaimed rows"
    assert_equal 2, row.guesses.length
    assert_nil row.user_id
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  # Phase 0.5's canonical-prefers-completed rule: start on one device, finish
  # on another. The first device's never-finished row used to be canonical
  # (earliest arrival), so the second device's WIN bounced as :non_canonical
  # and was lost forever.
  def test_win_on_second_device_counts_when_first_device_left_the_game_unfinished
    device_a = SecureRandom.uuid
    device_b = SecureRandom.uuid
    date = "2026-04-05"

    register_new_device!
    post_json "/api/v1/game/progress",
      {date: date, mode: "regular", guesses: [["crane", "01001"]]},
      {"HTTP_X_DEVICE_ID" => device_a}
    post_json "/api/v1/game/complete",
      {date: date, mode: "regular", game_status: "WIN", guesses: [["crane", "01001"], ["stole", "22222"]]},
      {"HTTP_X_DEVICE_ID" => device_b}

    stats = get_profile!["statistics"]
    assert_equal 1, stats["gamesWon"], "the phone's win must count despite the desktop's unfinished row arriving first"
    assert_equal 1, stats["currentStreak"]

    puzzle_num = PlayedGame.first(client_device_id: device_b, date: Date.parse(date)).puzzle_num
    history = json_get("/api/v2/history")
    assert_equal "WIN", history[puzzle_num.to_s]["game_status"], "history must surface the completed row, not the abandoned one"
  ensure
    [device_a, device_b].compact.each { |d| DB[:played_games].where(client_device_id: d).delete }
  end

  def test_history_import_attaches_a_previously_anonymous_row
    device_id = SecureRandom.uuid
    DB[:played_games].insert(
      client_device_id: device_id, date: Date.new(2026, 4, 2), puzzle_num: 801,
      updated_at: Sequel::CURRENT_TIMESTAMP
    )

    body = register_new_device!
    import_history!([{puzzle_num: 801, date: "2026-04-02", game_status: "WIN", guesses: n_guesses(4), device_id: device_id}], body["csrf_token"])

    row = PlayedGame.first(client_device_id: device_id, date: Date.new(2026, 4, 2))
    assert_equal body["user_id"], row.user_id, "an import should claim the importer's own anonymous pre-account rows"
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  # Phase 1 (docs/ownership_rework.md): import entries carry the
  # client-minted game_id local history has accumulated since client 3c67a32,
  # stored keep-first and surfaced back through the history read.
  def test_history_import_stores_a_game_id_and_history_returns_it
    body = register_new_device!
    device_id = SecureRandom.uuid
    game_id = SecureRandom.uuid

    import_history!([{puzzle_num: 810, date: "2026-04-06", game_status: "WIN", guesses: n_guesses(3), device_id: device_id, game_id: game_id}], body["csrf_token"])

    assert_equal game_id, PlayedGame.first(client_device_id: device_id, date: Date.new(2026, 4, 6)).game_id
    assert_equal game_id, json_get("/api/v2/history")["810"]["game_id"]
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  def test_history_reimport_keeps_the_first_game_id
    body = register_new_device!
    device_id = SecureRandom.uuid
    first_id = SecureRandom.uuid

    entry = {puzzle_num: 811, date: "2026-04-07", game_status: "WIN", guesses: n_guesses(3), device_id: device_id}
    import_history!([entry.merge(game_id: first_id)], body["csrf_token"])
    import_history!([entry.merge(game_id: SecureRandom.uuid)], body["csrf_token"])

    assert_equal first_id, PlayedGame.first(client_device_id: device_id, date: Date.new(2026, 4, 7)).game_id
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
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

  # -- games dual-write (Phase 2 of docs/ownership_rework.md) --
  #
  # Nothing reads games yet; these pin that the table accumulates correctly
  # alongside played_games, so Phase 3 has something trustworthy to cut over
  # to.

  def test_live_play_dual_writes_a_game_owned_by_the_user
    body = register_new_device!
    device_id = SecureRandom.uuid
    game_id = SecureRandom.uuid
    date = "2026-05-01"

    post_json "/api/v1/game/progress",
      {date: date, mode: "hard", guesses: [["crane", "01001"]], game_id: game_id},
      {"HTTP_X_DEVICE_ID" => device_id}
    post_json "/api/v1/game/complete",
      {date: date, mode: "hard", game_status: "WIN", guesses: [["crane", "01001"], ["stole", "22222"]], game_id: game_id},
      {"HTTP_X_DEVICE_ID" => device_id}

    game = Game.first(user_id: body["user_id"])
    refute_nil game, "an authenticated game must be mirrored into games"
    assert_equal game_id, game.client_game_id
    assert_equal "WIN", game.game_status
    assert_equal "hard", game.mode
    assert_equal 2, game.guesses.length
    refute_nil game.completed_at
    assert_equal Date.parse(date), game.date
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  # The headline fix. Two devices, one puzzle: played_games still records two
  # rows keyed by device, games records one keyed by (user_id, puzzle_num) --
  # and the WIN lands on it even though the unfinished row arrived first,
  # which is precisely the shape that used to lose the win entirely.
  def test_two_devices_one_puzzle_produce_a_single_game_carrying_the_win
    body = register_new_device!
    device_a = SecureRandom.uuid
    device_b = SecureRandom.uuid
    date = "2026-05-02"
    first_id = SecureRandom.uuid

    post_json "/api/v1/game/progress",
      {date: date, mode: "regular", guesses: [["crane", "01001"]], game_id: first_id},
      {"HTTP_X_DEVICE_ID" => device_a}
    post_json "/api/v1/game/complete",
      {date: date, mode: "regular", game_status: "WIN", guesses: [["crane", "01001"], ["stole", "22222"]], game_id: SecureRandom.uuid},
      {"HTTP_X_DEVICE_ID" => device_b}

    games = Game.where(user_id: body["user_id"]).all
    assert_equal 1, games.length, "one user playing one puzzle must be one game, whatever the device count"
    assert_equal "WIN", games.first.game_status
    assert_equal first_id, games.first.client_game_id, "first id wins, so the client converges on a stable value"
    assert_equal 2, PlayedGame.where(user_id: body["user_id"], puzzle_num: games.first.puzzle_num).count,
      "played_games still keeps both device rows -- only games collapses them"
  ensure
    [device_a, device_b].compact.each { |d| DB[:played_games].where(client_device_id: d).delete }
  end

  def test_a_lagging_progress_retry_cannot_reset_a_recorded_win
    body = register_new_device!
    device_id = SecureRandom.uuid
    date = "2026-05-03"

    post_json "/api/v1/game/complete",
      {date: date, mode: "regular", game_status: "WIN", guesses: [["crane", "01001"], ["stole", "22222"]]},
      {"HTTP_X_DEVICE_ID" => device_id}
    post_json "/api/v1/game/progress",
      {date: date, mode: "regular", guesses: [["crane", "01001"]]},
      {"HTTP_X_DEVICE_ID" => device_id}

    game = Game.first(user_id: body["user_id"])
    assert_equal "WIN", game.game_status, "keep-first game_status must survive an out-of-order progress write"
    assert_equal 2, game.guesses.length, "and the longer board must survive the shorter retry"
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  def test_anonymous_play_writes_nothing_to_games
    device_id = SecureRandom.uuid
    games_before = Game.count

    with_second_device do
      post_json "/api/v1/game/complete",
        {date: "2026-05-04", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]], game_id: SecureRandom.uuid},
        {"HTTP_X_DEVICE_ID" => device_id}
    end

    assert_equal games_before, Game.count, "games is user-owned; anonymous telemetry belongs only to played_games"
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  def test_an_older_client_sending_no_game_id_still_gets_one_minted
    body = register_new_device!
    device_id = SecureRandom.uuid

    post_json "/api/v1/game/complete",
      {date: "2026-05-05", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]]},
      {"HTTP_X_DEVICE_ID" => device_id}

    game = Game.first(user_id: body["user_id"])
    refute_nil game
    refute_nil game.client_game_id, "client_game_id is NOT NULL -- the server mints one when the client sends none"
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  def test_history_import_dual_writes_and_does_not_blank_a_live_board
    body = register_new_device!
    device_id = SecureRandom.uuid
    date = "2026-05-06"

    post_json "/api/v1/game/complete",
      {date: date, mode: "regular", game_status: "WIN", guesses: [["crane", "01001"], ["stole", "22222"]]},
      {"HTTP_X_DEVICE_ID" => device_id}
    puzzle_num = Game.first(user_id: body["user_id"]).puzzle_num

    # A history entry for the same puzzle carrying no guesses at all, which
    # is the common shape of the client's import payload.
    import_history!([{puzzle_num: puzzle_num, date: date, game_status: "WIN", device_id: SecureRandom.uuid}], body["csrf_token"])

    games = Game.where(user_id: body["user_id"], puzzle_num: puzzle_num).all
    assert_equal 1, games.length
    assert_equal 2, games.first.guesses.length, "a guess-less import must not blank out a real board"
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  def test_an_import_aimed_at_another_users_row_writes_no_game
    device_id = SecureRandom.uuid
    first_body = register_new_device!
    import_history!([{puzzle_num: 900, date: "2026-05-07", game_status: "WIN", guesses: n_guesses(3), device_id: device_id}], first_body["csrf_token"])

    with_second_device do
      second_body = register_new_device!
      import_history!([{puzzle_num: 900, date: "2026-05-07", game_status: "FAIL", guesses: n_guesses(6), device_id: device_id}], second_body["csrf_token"])

      assert_equal 0, Game.where(user_id: second_body["user_id"]).count,
        "the dual-write sits behind owned_row_scope, so a refused import creates no game either"
    end

    assert_equal "WIN", Game.first(user_id: first_body["user_id"], puzzle_num: 900).game_status
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  # -- Phase 3 dual-read (docs/played_games_ownership_rework.md) ------------
  #
  # With the flag off every read is computed both ways and compared but the
  # played_games answer is still served; with it on the games answer is
  # served. Divergences are recorded rather than logged so the soak's
  # go/no-go is a query.

  def test_agreeing_reads_record_no_divergence
    body = register_new_device!
    device_id = SecureRandom.uuid

    post_json "/api/v1/game/complete",
      {date: "2026-06-01", mode: "regular", game_status: "WIN", guesses: [["crane", "01001"], ["stole", "22222"]], game_id: SecureRandom.uuid},
      {"HTTP_X_DEVICE_ID" => device_id}
    json_get("/api/v2/history")

    assert_equal 0, GamesReadDivergence.where(user_id: body["user_id"]).count,
      "the tables agree, so the soak signal must stay clean"
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  def test_history_divergence_is_recorded_with_both_sides
    body = register_new_device!
    device_id = SecureRandom.uuid

    post_json "/api/v1/game/complete",
      {date: "2026-06-02", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]]},
      {"HTTP_X_DEVICE_ID" => device_id}

    # Force disagreement the only way that matters: make the games row say
    # something the played_games row does not.
    Game.where(user_id: body["user_id"]).update(game_status: "FAIL")
    json_get("/api/v2/history")

    row = GamesReadDivergence.first(user_id: body["user_id"], read_name: "history")
    refute_nil row, "a disagreeing history read must be recorded"
    assert_includes row.detail, "game_status"
    assert_equal "WIN", row.played_games_value["game_status"]
    assert_equal "FAIL", row.games_value["game_status"]
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  def test_repeat_reads_bump_the_same_divergence_rather_than_multiplying_rows
    body = register_new_device!
    device_id = SecureRandom.uuid

    post_json "/api/v1/game/complete",
      {date: "2026-06-03", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]]},
      {"HTTP_X_DEVICE_ID" => device_id}
    Game.where(user_id: body["user_id"]).update(game_status: "FAIL")

    3.times { json_get("/api/v2/history") }

    rows = GamesReadDivergence.where(user_id: body["user_id"], read_name: "history").all
    assert_equal 1, rows.length, "one row per disagreeing (read, user, puzzle), however often it is read"
    assert_equal 3, rows.first.seen_count
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  # The one difference that is expected rather than alarming: a multi-device
  # user's played_games canonical row can carry a different id than the games
  # row, which keeps the first id it ever saw. Counting that as divergence
  # would bury the signal the soak depends on.
  def test_a_differing_game_id_alone_is_not_treated_as_divergence
    body = register_new_device!
    device_id = SecureRandom.uuid

    post_json "/api/v1/game/complete",
      {date: "2026-06-04", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]], game_id: SecureRandom.uuid},
      {"HTTP_X_DEVICE_ID" => device_id}
    Game.where(user_id: body["user_id"]).update(client_game_id: SecureRandom.uuid)

    json_get("/api/v2/history")

    assert_equal 0, GamesReadDivergence.where(user_id: body["user_id"]).count
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  def test_the_flag_decides_which_history_is_served
    body = register_new_device!
    device_id = SecureRandom.uuid

    post_json "/api/v1/game/complete",
      {date: "2026-06-05", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]]},
      {"HTTP_X_DEVICE_ID" => device_id}
    puzzle_num = Game.first(user_id: body["user_id"]).puzzle_num
    Game.where(user_id: body["user_id"]).update(game_status: "FAIL")

    assert_equal "WIN", json_get("/api/v2/history")[puzzle_num.to_s]["game_status"],
      "flag off must still serve the played_games answer"

    with_games_reads do
      assert_equal "FAIL", json_get("/api/v2/history")[puzzle_num.to_s]["game_status"],
        "flag on must serve the games answer"
    end
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  def test_with_the_flag_on_the_response_id_comes_from_games
    body = register_new_device!
    device_id = SecureRandom.uuid
    played_games_id = SecureRandom.uuid
    games_id = SecureRandom.uuid

    post_json "/api/v1/game/progress",
      {date: "2026-06-06", mode: "regular", guesses: [["crane", "01001"]], game_id: played_games_id},
      {"HTTP_X_DEVICE_ID" => device_id}
    Game.where(user_id: body["user_id"]).update(client_game_id: games_id)

    post_json "/api/v1/game/progress",
      {date: "2026-06-06", mode: "regular", guesses: [["crane", "01001"], ["stole", "11111"]], game_id: played_games_id},
      {"HTTP_X_DEVICE_ID" => device_id}
    assert_equal played_games_id, json_response["game_id"], "flag off keeps the played_games id"

    with_games_reads do
      post_json "/api/v1/game/progress",
        {date: "2026-06-06", mode: "regular", guesses: [["crane", "01001"]], game_id: played_games_id},
        {"HTTP_X_DEVICE_ID" => device_id}
      assert_equal games_id, json_response["game_id"],
        "flag on returns the games row's id, so every device converges on one value"
    end
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  def test_anonymous_play_keeps_the_played_games_id_even_with_the_flag_on
    device_id = SecureRandom.uuid
    game_id = SecureRandom.uuid

    with_games_reads do
      with_second_device do
        post_json "/api/v1/game/complete",
          {date: "2026-06-07", mode: "regular", game_status: "WIN", guesses: [["crane", "22222"]], game_id: game_id},
          {"HTTP_X_DEVICE_ID" => device_id}
        assert_equal game_id, json_response["game_id"], "an anonymous caller has no games row to converge on"
      end
    end
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  # A divergence that can really happen rather than one staged by deleting a
  # row: played_games overwrites guesses unconditionally, while games keeps
  # the longest array it has seen. A completion carrying fewer guesses than
  # the progress before it — an out-of-order arrival — leaves the two sides
  # disagreeing about the guess count, which is what picks the histogram
  # bucket. Deleting the games row first would prove nothing, since the
  # dual-write recreates it before the stats read happens.
  def test_a_stats_canonical_divergence_is_recorded
    body = register_new_device!
    device_id = SecureRandom.uuid

    post_json "/api/v1/game/progress",
      {date: "2026-06-08", mode: "regular", guesses: [["crane", "01001"], ["stole", "11111"]]},
      {"HTTP_X_DEVICE_ID" => device_id}
    post_json "/api/v1/game/complete",
      {date: "2026-06-08", mode: "regular", game_status: "WIN", guesses: [["stole", "22222"]]},
      {"HTTP_X_DEVICE_ID" => device_id}

    row = GamesReadDivergence.first(user_id: body["user_id"], read_name: "stats_canonical")
    refute_nil row, "a disagreeing stats-canonical read must be recorded"
    assert_equal "guess_count", row.detail
    assert_equal 1, row.played_games_value["guess_count"]
    assert_equal 2, row.games_value["guess_count"]
  ensure
    DB[:played_games].where(client_device_id: device_id).delete if device_id
  end

  private

  def import_history!(entries, csrf_token)
    post_json "/api/v2/history/import", {history: entries}, csrf_env(csrf_token)
    assert last_response.ok?, last_response.body
    json_response
  end

  def adjust_stats!(statistics, source, csrf_token)
    post_json "/api/v2/stats/adjust", {statistics: statistics, source: source}, csrf_env(csrf_token)
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

  # Phase 3's per-deployment read flag (config/app_config.yml's
  # read_games_enabled). Off by default everywhere, including here, so the
  # rest of the suite proves the dual-read comparison changes nothing.
  def with_games_reads(&block)
    LeftWordleApi.set :read_games_enabled, true
    block.call
  ensure
    LeftWordleApi.set :read_games_enabled, false
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
