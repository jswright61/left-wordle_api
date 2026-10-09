# frozen_string_literal: true

Sequel.migration do
  up do
    # Phase 2 of docs/ownership_rework.md. Authenticated play
    # moves here, where a user owns their rows outright: identity is
    # (user_id, puzzle_num), not (device, date), so the same user finishing
    # one puzzle on two devices can no longer produce two rows that need
    # canonicalizing. played_games stays behind as anonymous telemetry.
    create_table(:games) do
      # Server-minted surrogate. Deliberately NOT the client's id: a
      # client-supplied value as the global primary key would carry
      # structural weight across every account -- an import replaying
      # someone else's id (a shared or copied backup) would hard-error on a
      # PK conflict the (user_id, puzzle_num) upsert can't absorb, and ids
      # are visible in every exported backup, so they'd be squattable.
      # Authorization never reads any of these columns anyway; the session
      # decides ownership.
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)

      # The client-minted UUIDv7 (wire field "game_id", minted at game start
      # since client 3c67a32). Named to match played_games.client_device_id:
      # "the client's id for a game", as that is "the client's id for a
      # device". Unique per user, never globally -- that's all identity,
      # dedup and import idempotency ever needed. NOT NULL: when a request
      # arrives without one (older clients), the server mints it.
      column :client_game_id, :uuid, null: false

      foreign_key :user_id, :users, type: :uuid, null: false, on_delete: :cascade

      Integer :puzzle_num, null: false
      Date :date, null: false
      String :mode
      String :game_status
      column :guesses, :jsonb

      DateTime :completed_at
      # Server clock, for audit. The client's UUIDv7 timestamp orders play
      # (which is the point of v7 -- an import keeps true play order rather
      # than collapsing to server-arrival order), but client clocks are
      # untrusted, so this stays as the trustworthy record of when the row
      # actually reached us.
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false

      # A user plays a given puzzle once. This is the whole rework: the
      # duplicate row becomes unrepresentable instead of reconciled at read
      # time, and a second device's write self-heals into an update of the
      # first one rather than a competing row.
      index [:user_id, :puzzle_num], unique: true
      index [:user_id, :client_game_id], unique: true
    end

    create_trigger(:games, :set_updated_at, :set_updated_at, events: :update, each_row: true)
  end

  down do
    drop_trigger(:games, :set_updated_at)
    drop_table(:games)
  end
end
