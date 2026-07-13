# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:passkey_credentials) do
      # Soft-disable, same pattern as device_link_tokens.consumed_at and
      # sessions.revoked_at -- keeps created_at/last_used_at history intact
      # instead of hard-deleting the row.
      add_column :revoked_at, DateTime
    end
  end

  down do
    alter_table(:passkey_credentials) do
      drop_column :revoked_at
    end
  end
end
