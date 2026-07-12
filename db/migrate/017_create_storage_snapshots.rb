# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:storage_snapshots) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      foreign_key :user_id, :users, type: :uuid, null: false, on_delete: :cascade
      # The client_device_id (from X-Device-Id) the snapshot was captured
      # on. Not a foreign key -- there is no devices table (see sessions).
      column :client_device_id, :uuid
      # e.g. "new user creation" (first-login upload), "update client
      # local storage" (profile download to hydrate client storage).
      String :event, null: false
      column :local_storage, :jsonb, null: false
      # Append-only debug/audit trail -- rows are never updated, so there's
      # no updated_at. created_at doubles as the event timestamp a future
      # pruner will key off of to remove stale rows.
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      index :user_id
      index :created_at
    end
  end

  down do
    drop_table(:storage_snapshots)
  end
end
