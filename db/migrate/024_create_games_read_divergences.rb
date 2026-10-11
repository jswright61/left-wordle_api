# frozen_string_literal: true

Sequel.migration do
  up do
    # Phase 3 of docs/ownership_rework.md. Every read that will
    # move to `games` is computed both ways and compared; when the two
    # disagree, the disagreement is recorded here rather than only in the
    # log. The soak's go/no-go question is "has this gone quiet for real
    # traffic", which is a query -- grepping journalctl across puma workers
    # is not, and log rotation loses the history the decision depends on.
    #
    # Rows are written only on divergence. If the tables agree, as expected,
    # this table stays empty and costs nothing.
    create_table(:games_read_divergences) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)

      # Which read disagreed -- "history" or "stats_canonical". Not an enum:
      # a new comparison site should not need a migration to start
      # reporting.
      String :read_name, null: false

      # No foreign key on purpose. This is diagnostic evidence about a
      # decision the app already made; it must survive the account being
      # deleted long enough to be investigated, and must never be the reason
      # a delete fails.
      column :user_id, :uuid, null: false
      # NOT NULL so the unique index below dedupes without depending on
      # NULLS NOT DISTINCT (Sequel's index options silently drop it). Every
      # comparison site is per-puzzle, so there is nothing to express with a
      # null here.
      Integer :puzzle_num, null: false

      # The two answers, as JSON, plus a short machine-readable reason.
      # Whole values rather than a diff: the point is to reconstruct what
      # each side actually said, months later, without the row that produced
      # it still being around.
      String :detail
      column :played_games_value, :jsonb
      column :games_value, :jsonb

      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      # Bumped every time the same disagreement is seen again, so a single
      # user reloading history does not multiply rows.
      Integer :seen_count, null: false, default: 1
      DateTime :last_seen_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      # One row per disagreeing (read, user, puzzle). The soak asks "which
      # user/puzzle pairs disagree", not "how many times was the page
      # loaded" -- and without this, one user with a broken history could
      # write a row per puzzle on every request and bury the signal.
      index [:read_name, :user_id, :puzzle_num], unique: true
      index :last_seen_at
    end
  end

  down do
    drop_table(:games_read_divergences)
  end
end
