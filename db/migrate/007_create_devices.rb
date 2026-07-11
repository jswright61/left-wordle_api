# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:devices) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      column :client_device_id, :uuid, null: false
      String :country_code, size: 2
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false

      index :client_device_id, unique: true
    end

    create_trigger(:devices, :set_updated_at, :set_updated_at, events: :update, each_row: true)
  end

  down do
    drop_trigger(:devices, :set_updated_at)
    drop_table(:devices)
  end
end
