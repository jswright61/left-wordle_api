# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:played_games) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      # The raw, client-supplied device id (not a foreign key -- there is no
      # devices table). Deliberately not unique on its own: a device plays
      # many games, one row per (client_device_id, date).
      column :client_device_id, :uuid, null: false
      Date :date, null: false
      Integer :puzzle_num, null: false
      # Captured per-game (via Cloudflare's CF-IPCountry header), not on a
      # separate per-device record -- a device's country can legitimately
      # differ game to game (travel, VPN, mobile network changes), so there
      # is no single stable "device country" to store elsewhere.
      String :country_code, size: 2
      DateTime :initiated_at
      DateTime :completed_at
      String :mode
      String :game_status
      column :guesses, :jsonb
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false

      index [:client_device_id, :date], unique: true
    end

    create_trigger(:played_games, :set_updated_at, :set_updated_at, events: :update, each_row: true)
  end

  down do
    drop_trigger(:played_games, :set_updated_at)
    drop_table(:played_games)
  end
end
