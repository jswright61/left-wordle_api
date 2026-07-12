# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:sessions) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      foreign_key :user_id, :users, type: :uuid, null: false, on_delete: :cascade
      # SHA-256 hex digest of the opaque session cookie value. The raw
      # token is bearer-equivalent to a password and is never persisted or
      # logged.
      String :token_digest, size: 64, null: false
      # The client_device_id (from X-Device-Id) this session was
      # established on, for correlation with played_games. Not a foreign
      # key -- there is no devices table.
      column :client_device_id, :uuid
      DateTime :expires_at, null: false
      DateTime :revoked_at
      DateTime :last_seen_at
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false

      index :token_digest, unique: true
      index :user_id
    end

    create_trigger(:sessions, :set_updated_at, :set_updated_at, events: :update, each_row: true)
  end

  down do
    drop_trigger(:sessions, :set_updated_at)
    drop_table(:sessions)
  end
end
