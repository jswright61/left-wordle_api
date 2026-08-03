# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:users) do
      drop_column :imported_at
    end
  end

  down do
    alter_table(:users) do
      add_column :imported_at, DateTime
    end
  end
end
