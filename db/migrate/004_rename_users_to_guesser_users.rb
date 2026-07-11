# frozen_string_literal: true

Sequel.migration do
  change do
    rename_table :users, :guesser_users
    add_column :guesser_users, :approved_at, DateTime
    add_column :guesser_users, :deactivated_at, DateTime
  end
end
