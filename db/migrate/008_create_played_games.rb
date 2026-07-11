# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:played_games) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      foreign_key :device_id, :devices, type: :uuid, null: false
      Date :date, null: false
      Integer :puzzle_num, null: false
      DateTime :initiated_at
      DateTime :completed_at
      String :mode
      String :game_status
      column :guesses, :jsonb
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false

      index [:device_id, :date], unique: true
    end

    create_trigger(:played_games, :set_updated_at, :set_updated_at, events: :update, each_row: true)
  end

  down do
    drop_trigger(:played_games, :set_updated_at)
    drop_table(:played_games)
  end
end
