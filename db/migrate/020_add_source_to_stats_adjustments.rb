# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:stats_adjustments) do
      # Which flow produced this adjustment -- see app.rb's
      # STATS_ADJUSTMENT_SOURCES. Nullable: existing rows predate this
      # column and their source can't be reconstructed after the fact.
      add_column :source, String
    end
  end

  down do
    alter_table(:stats_adjustments) do
      drop_column :source
    end
  end
end
