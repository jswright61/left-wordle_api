# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:device_link_tokens) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      foreign_key :user_id, :users, type: :uuid, null: false, on_delete: :cascade
      # SHA-256 hex digest of the opaque link token -- same storage
      # principle as sessions.token_digest.
      String :token_digest, size: 64, null: false
      String :delivery, null: false # "qr" or "email"
      DateTime :expires_at, null: false
      # Single-use: set atomically on redemption (WHERE consumed_at IS
      # NULL) to prevent replay.
      DateTime :consumed_at
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false

      index :token_digest, unique: true
      index :user_id
    end

    create_trigger(:device_link_tokens, :set_updated_at, :set_updated_at, events: :update, each_row: true)
  end

  down do
    drop_trigger(:device_link_tokens, :set_updated_at)
    drop_table(:device_link_tokens)
  end
end
