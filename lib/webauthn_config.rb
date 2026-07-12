# frozen_string_literal: true

require "webauthn"

module LeftWordle
  module WebauthnConfig
    module_function

    # rp_id defaults to the origin's host when not given explicitly, which
    # is correct for this app's same-origin (frontend + API share one host)
    # deployments on both staging and production. See
    # api/docs/security_architecture.md for the full RP ID/origin model.
    def configure!(origin:, rp_name:, rp_id: nil)
      WebAuthn.configure do |config|
        config.allowed_origins = [origin]
        config.rp_name = rp_name
        config.rp_id = rp_id if rp_id
      end
    end
  end
end
