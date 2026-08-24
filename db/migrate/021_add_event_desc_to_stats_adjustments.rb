# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:stats_adjustments) do
      # Human-readable specifics for this row (e.g. "Puzzle #1892 completed
      # (WIN)"), alongside the already-narrow `source` category -- see
      # app.rb's STATS_ADJUSTMENT_SOURCES. Nullable: existing rows predate
      # this column.
      add_column :event_desc, String
    end
  end

  down do
    alter_table(:stats_adjustments) do
      drop_column :event_desc
    end
  end
end
