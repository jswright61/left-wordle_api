# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"
require "securerandom"

# Sinatra helper methods for passkey sessions and CSRF, mixed into
# LeftWordleApi via `helpers AuthHelpers`. See api/docs/security_architecture.md
# for the session/CSRF model this implements: an HttpOnly session cookie
# (never exposed to JS) plus a CSRF token returned in JSON response bodies
# and echoed back as a request header on state-changing calls.
module AuthHelpers
  SESSION_COOKIE_NAME = "left_wordle_session"
  # Holds a signed, single-use WebAuthn challenge between /begin and
  # /finish. Signed (not just stored client-side) so the challenge, target
  # user, and any device-link token it's scoped to can't be tampered with,
  # while avoiding a throwaway DB table for something this short-lived.
  PENDING_COOKIE_NAME = "left_wordle_pending"
  PENDING_CEREMONY_TTL_SECONDS = 300

  # -- Sessions ---------------------------------------------------------

  def current_session
    return @current_session if defined?(@current_session)

    raw_token = request.cookies[SESSION_COOKIE_NAME]
    @current_session = nil
    return @current_session unless raw_token

    session = Session.first(token_digest: Digest::SHA256.hexdigest(raw_token))
    if session&.active?
      session.update(last_seen_at: Sequel::CURRENT_TIMESTAMP)
      @current_session = session
    end
    @current_session
  end

  def current_user
    current_session&.user
  end

  def require_authenticated_user!
    halt_json(:unauthorized, "Not authorized") unless current_user
    current_user
  end

  def issue_session_cookie!(user, client_device_id)
    raw_token = SecureRandom.hex(32)
    expires_at = Time.now + settings.session_token_ttl_days.to_i * 86_400

    session = Session.create(
      user_id: user.id,
      token_digest: Digest::SHA256.hexdigest(raw_token),
      client_device_id: client_device_id,
      expires_at: expires_at
    )

    response.set_cookie(SESSION_COOKIE_NAME, {
      value: raw_token,
      path: "/",
      httponly: true,
      secure: production?,
      same_site: :lax,
      expires: expires_at
    })

    @current_session = session
  end

  def clear_session_cookie!
    current_session&.update(revoked_at: Sequel::CURRENT_TIMESTAMP)
    response.delete_cookie(SESSION_COOKIE_NAME, path: "/")
    @current_session = nil
  end

  # -- CSRF ---------------------------------------------------------------
  # Double-submit pattern: the token is an HMAC of the session's own
  # token_digest, so it's stable for the life of the session without a
  # dedicated column, and can only be produced by someone who already
  # holds a valid response body (never the cookie alone, which is
  # HttpOnly and unreadable by JS).

  def current_csrf_token
    session = current_session
    return nil unless session
    csrf_token_for(session)
  end

  def require_csrf!
    require_authenticated_user!
    session = current_session
    supplied = request.env["HTTP_X_CSRF_TOKEN"].to_s
    valid = supplied.length.positive? && Rack::Utils.secure_compare(csrf_token_for(session), supplied)
    halt_json(:forbidden, "Invalid or missing CSRF token") unless valid
  end

  def csrf_token_for(session)
    OpenSSL::HMAC.hexdigest("SHA256", session_secret, session.token_digest)
  end

  # -- WebAuthn pending-ceremony challenge -------------------------------

  def issue_pending_ceremony!(purpose:, challenge:, user_id: nil, device_link_token_digest: nil)
    payload = {
      purpose: purpose,
      challenge: challenge,
      user_id: user_id,
      device_link_token_digest: device_link_token_digest,
      issued_at: Time.now.to_i
    }

    response.set_cookie(PENDING_COOKIE_NAME, {
      value: sign_pending_payload(payload),
      path: "/",
      httponly: true,
      secure: production?,
      same_site: :lax,
      max_age: PENDING_CEREMONY_TTL_SECONDS
    })
  end

  def consume_pending_ceremony!(purpose:)
    raw = request.cookies[PENDING_COOKIE_NAME]
    response.delete_cookie(PENDING_COOKIE_NAME, path: "/")
    halt_json(:bad_request, "No pending passkey ceremony") unless raw

    payload = verify_pending_payload(raw)
    halt_json(:bad_request, "Passkey ceremony expired or invalid") unless payload
    if Time.now.to_i - payload["issued_at"].to_i > PENDING_CEREMONY_TTL_SECONDS
      halt_json(:bad_request, "Passkey ceremony expired")
    end
    halt_json(:bad_request, "Unexpected passkey ceremony") unless payload["purpose"] == purpose

    payload
  end

  # -- Device-link tokens (QR / email) -----------------------------------

  def issue_device_link_token_for!(user, delivery)
    raw_token = SecureRandom.hex(32)
    ttl_minutes = settings.device_link_token_ttl_minutes.to_i

    token = DeviceLinkToken.create(
      user_id: user.id,
      token_digest: Digest::SHA256.hexdigest(raw_token),
      delivery: delivery,
      expires_at: Time.now + ttl_minutes * 60
    )

    [raw_token, token]
  end

  def redeem_device_link_token(raw_token)
    return nil unless raw_token.is_a?(String) && !raw_token.empty?

    token = DeviceLinkToken.first(token_digest: Digest::SHA256.hexdigest(raw_token))
    token if token&.redeemable?
  end

  # Atomic single-use guard: only one caller's UPDATE can match
  # consumed_at: nil, so a raced double-redemption of the same token
  # can't both succeed.
  def consume_device_link_token!(token)
    DeviceLinkToken.where(id: token.id, consumed_at: nil).update(consumed_at: Sequel::CURRENT_TIMESTAMP) == 1
  end

  # -- Shared helpers -----------------------------------------------------

  def production?
    ENV["RACK_ENV"] == "production"
  end

  private

  def session_secret
    configured = settings.session_secret.to_s.strip
    return configured unless configured.empty?

    raise "session_secret must be configured (config/app_config.yml) in production" if production?
    "insecure-development-only-session-secret"
  end

  def sign_pending_payload(payload)
    encoded = Base64.urlsafe_encode64(JSON.generate(payload))
    "#{encoded}.#{OpenSSL::HMAC.hexdigest("SHA256", session_secret, encoded)}"
  end

  def verify_pending_payload(raw)
    encoded, signature = raw.split(".", 2)
    return nil unless encoded && signature

    expected = OpenSSL::HMAC.hexdigest("SHA256", session_secret, encoded)
    return nil unless Rack::Utils.secure_compare(expected, signature)

    JSON.parse(Base64.urlsafe_decode64(encoded))
  rescue ArgumentError, TypeError, JSON::ParserError
    nil
  end
end
