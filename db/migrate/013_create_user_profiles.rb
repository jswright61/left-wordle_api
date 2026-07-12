# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:user_profiles) do
      foreign_key :user_id, :users, type: :uuid, null: false, primary_key: true, on_delete: :cascade
      # Mirror the client's StorageController namespaces verbatim as
      # opaque blobs. Schema evolution stays entirely client-side (see the
      # client's own SCHEMA_VERSION) -- the API only enforces "valid JSON
      # object under a size limit", never internal shape.
      column :preferences, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      column :game_state, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      # Stored directly, not derived from played_games -- history can be
      # incomplete or lag behind stats, so recomputing stats from history
      # would risk repeating the prior stats-migration data-loss bug.
      column :statistics, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false
    end

    create_trigger(:user_profiles, :set_updated_at, :set_updated_at, events: :update, each_row: true)
  end

  down do
    drop_trigger(:user_profiles, :set_updated_at)
    drop_table(:user_profiles)
  end
end
