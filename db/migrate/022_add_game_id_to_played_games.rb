# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:played_games) do
      # Transitional (Phase 1 of docs/played_games_ownership_rework.md):
      # accumulates the client-minted UUIDv7 so the Phase 2 games backfill
      # can carry real ids instead of minting backdated ones. Dropped again
      # in Phase 4 alongside user_id -- long-term this table keeps no join
      # path to accounts. Nullable: old clients never send one, and no
      # behavior depends on it. Deliberately not unique -- it is a
      # client-supplied value (see the rework doc's authorization decision)
      # and identity here stays (client_device_id, date).
      add_column :game_id, :uuid, null: true
    end
  end

  down do
    alter_table(:played_games) do
      drop_column :game_id
    end
  end
end
