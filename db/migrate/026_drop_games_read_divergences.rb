# frozen_string_literal: true

Sequel.migration do
  up do
    # Phase 3's evidence table. It existed to answer one question -- "do the
    # two reads agree on real traffic" -- and reaching Phase 4 means that
    # question was answered yes and the old read no longer exists to
    # disagree. Kept around it would only accumulate rows nothing writes.
    #
    # Deliberately a separate migration from 025: dropping this is
    # housekeeping and safe to run whenever, while 025 destroys the
    # row/account mapping and is the irreversible step.
    drop_table(:games_read_divergences)
  end

  down do
    create_table(:games_read_divergences) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      String :read_name, null: false
      column :user_id, :uuid, null: false
      Integer :puzzle_num, null: false
      String :detail
      column :played_games_value, :jsonb
      column :games_value, :jsonb
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      Integer :seen_count, null: false, default: 1
      DateTime :last_seen_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:read_name, :user_id, :puzzle_num], unique: true
      index :last_seen_at
    end
  end
end
