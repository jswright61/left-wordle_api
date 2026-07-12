# frozen_string_literal: true

class PasskeyCredential < Sequel::Model(:passkey_credentials)
  many_to_one :user
end
