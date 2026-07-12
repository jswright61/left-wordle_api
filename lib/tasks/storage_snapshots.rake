# frozen_string_literal: true

namespace :storage_snapshots do
  desc "Delete storage_snapshots rows older than the retention window"
  task :prune do
    require_relative "../db"

    retention_days = 30
    deleted = DB[:storage_snapshots]
      .where(Sequel.lit("created_at < now() - (? * interval '1 day')", retention_days))
      .delete
    puts "Pruned #{deleted} storage_snapshots row(s) older than #{retention_days} days."
  end
end
