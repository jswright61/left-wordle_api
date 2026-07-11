# frozen_string_literal: true

Sequel.migration do
  up do
    create_function(:set_updated_at, <<~SQL, language: :plpgsql, returns: :trigger)
      BEGIN
        IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
          NEW.updated_at = clock_timestamp();
        END IF;

        RETURN NEW;
      END;
    SQL

    [:guesser_users, :answers, :legal_words].each do |table|
      create_trigger(table, :set_updated_at, :set_updated_at, events: :update, each_row: true)
    end
  end

  down do
    [:guesser_users, :answers, :legal_words].each do |table|
      drop_trigger(table, :set_updated_at)
    end

    drop_function(:set_updated_at)
  end
end
