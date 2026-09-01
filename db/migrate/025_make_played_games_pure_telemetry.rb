# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:played_games) do
      # Replaces user_id for analysis. The logged-in/logged-out cut is often
      # the interesting dimension ("do account holders play differently"),
      # and it survives without any linkage back to who the account is.
      add_column :authenticated, TrueClass, null: false, default: false
    end

    # Backfill before dropping the column it is derived from.
    from(:played_games).where(Sequel.~(user_id: nil)).update(authenticated: true)

    alter_table(:played_games) do
      # The privacy win this whole rework exists for: telemetry can no longer
      # be joined to accounts, because the join column is gone. Authenticated
      # play lives in `games`, which is keyed (user_id, puzzle_num) and owns
      # its rows outright.
      #
      # This is the one step that cannot be reversed by redeploying. The
      # down block below recreates the columns, but nothing can recreate the
      # values -- every row/account association is destroyed here, which is
      # the point. Do not run this until `games` has been serving reads in
      # production long enough that going back is off the table.
      drop_column :user_id

      # Transitional since Phase 1; it existed only so the Phase 2 backfill
      # could carry real client-minted ids into games.client_game_id. Kept
      # here it would re-create a played_games -> games -> users join path
      # and hand back part of the privacy win.
      drop_column :game_id
    end
  end

  down do
    alter_table(:played_games) do
      add_foreign_key :user_id, :users, type: :uuid, null: true, on_delete: :set_null
      add_index :user_id
      add_column :game_id, :uuid, null: true
      drop_column :authenticated
    end
  end
end
