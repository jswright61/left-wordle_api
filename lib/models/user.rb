# frozen_string_literal: true

class User < Sequel::Model(:users)
  one_to_many :passkey_credentials
  one_to_many :sessions
  one_to_many :device_link_tokens
  one_to_many :stats_adjustments
  one_to_one :user_profile

  def before_create
    self.webauthn_user_id ||= WebAuthn.generate_user_id
    super
  end
end
