# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:answers) do
      primary_key :id, type: :uuid, default: Sequel.function(:uuidv7)
      Integer :position, null: false
      String :word, size: 5, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      # :include makes this a covering index for the only query that hits
      # this table (load all answers ordered by position) — Postgres can
      # satisfy it as an index-only scan without touching the heap. Table
      # is tiny either way, but it's free.
      index :position, unique: true, include: [:word]
    end
  end
end
