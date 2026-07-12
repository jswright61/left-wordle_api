# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:stats_adjustments) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      foreign_key :user_id, :users, type: :uuid, null: false, on_delete: :cascade
      # Append-only audit trail of manual "Adjust Stats" edits while
      # logged in. Rows are never updated after creation.
      column :before, :jsonb, null: false
      column :after, :jsonb, null: false
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false

      index :user_id
    end

    create_trigger(:stats_adjustments, :set_updated_at, :set_updated_at, events: :update, each_row: true)
  end

  down do
    drop_trigger(:stats_adjustments, :set_updated_at)
    drop_table(:stats_adjustments)
  end
end
