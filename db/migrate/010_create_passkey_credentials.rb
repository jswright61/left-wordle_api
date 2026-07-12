# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:passkey_credentials) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      foreign_key :user_id, :users, type: :uuid, null: false, on_delete: :cascade
      # base64url WebAuthn credential id. Text, not a bounded varchar --
      # length varies by authenticator.
      String :external_id, text: true, null: false
      # base64url COSE public key.
      String :public_key, text: true, null: false
      # WebAuthn signature counter, used to detect cloned-authenticator
      # replay. Many platform authenticators always report 0; treat two
      # zero counts as non-replay (see auth_helpers.rb).
      Bignum :sign_count, null: false, default: 0
      # User-facing label, e.g. "iPhone" -- set at registration, editable
      # later.
      String :nickname
      String :aaguid
      DateTime :last_used_at
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false

      index :external_id, unique: true
      index :user_id
    end

    create_trigger(:passkey_credentials, :set_updated_at, :set_updated_at, events: :update, each_row: true)
  end

  down do
    drop_trigger(:passkey_credentials, :set_updated_at)
    drop_table(:passkey_credentials)
  end
end
