# frozen_string_literal: true

Sequel.migration do
  up do
    [:guesser_users, :answers, :legal_words].each do |table|
      alter_table(table) do
        set_column_default :created_at, Sequel::CURRENT_TIMESTAMP
      end
    end
  end

  down do
    [:guesser_users, :answers, :legal_words].each do |table|
      alter_table(table) do
        set_column_default :created_at, nil
      end
    end
  end
end
