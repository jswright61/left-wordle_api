# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:played_games) do
      # Nullable -- anonymous play keeps inserting with user_id: nil
      # exactly as today. Set once a device with an active session
      # completes/initiates a game. Historical pre-link rows are not
      # retroactively claimed when a device later joins an account.
      add_foreign_key :user_id, :users, type: :uuid, null: true, on_delete: :set_null
      add_index :user_id
    end
  end

  down do
    alter_table(:played_games) do
      drop_index :user_id
      drop_foreign_key :user_id
    end
  end
end
