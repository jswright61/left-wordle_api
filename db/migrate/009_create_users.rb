# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:users) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      # Nullable -- passkey accounts are anonymous by default. Only present
      # when the user opts in to email-based device-link delivery.
      String :email
      DateTime :email_verified_at
      # Set the one time this account's local storage is uploaded on first
      # login (see POST /api/v2/import/local_data). Enforces the one-time
      # rule server-side, not just client-side.
      DateTime :imported_at
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false

      index :email, unique: true, where: Sequel.lit("email IS NOT NULL")
    end

    create_trigger(:users, :set_updated_at, :set_updated_at, events: :update, each_row: true)
  end

  down do
    drop_trigger(:users, :set_updated_at)
    drop_table(:users)
  end
end
