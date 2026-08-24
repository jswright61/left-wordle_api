# frozen_string_literal: true

namespace :stats_adjustments do
  desc "Delete stats_adjustments rows older than the retention window"
  task :prune do
    require_relative "../db"

    retention_days = 90
    deleted = DB[:stats_adjustments]
      .where(Sequel.lit("created_at < now() - (? * interval '1 day')", retention_days))
      .delete
    puts "Pruned #{deleted} stats_adjustments row(s) older than #{retention_days} days."
  end
end
