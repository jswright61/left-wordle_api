# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:scheduled_tasks) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      String :name, null: false
      # Time-of-day only (no date component), interpreted as UTC.
      Time :run_at, null: false, only_time: true
      DateTime :last_run_at
      column :enabled, :boolean, null: false, default: true
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false

      index :name, unique: true
    end

    create_trigger(:scheduled_tasks, :set_updated_at, :set_updated_at, events: :update, each_row: true)
  end

  down do
    drop_trigger(:scheduled_tasks, :set_updated_at)
    drop_table(:scheduled_tasks)
  end
end
