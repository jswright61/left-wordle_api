# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:legal_words) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      String :word, size: 5, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :word, unique: true
    end
  end
end
