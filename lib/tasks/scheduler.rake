# frozen_string_literal: true

namespace :scheduler do
  desc "Ensure known scheduled tasks exist (safe to rerun; never overwrites an existing row)"
  task :seed do
    require_relative "../db"
    require_relative "../models/scheduled_task"

    ScheduledTask.find_or_create(name: "stats:daily_summary") do |t|
      t.run_at = "05:15:00"
      t.enabled = true
    end
    puts "Ensured scheduled_tasks row for 'stats:daily_summary'"

    ScheduledTask.find_or_create(name: "storage_snapshots:prune") do |t|
      t.run_at = "04:00:00"
      t.enabled = true
    end
    puts "Ensured scheduled_tasks row for 'storage_snapshots:prune'"
  end

  desc "Run any scheduled tasks that are due (invoked periodically by a systemd timer)"
  task :tick do
    require_relative "../db"

    due_sql = <<~SQL
      enabled
      AND now() >= ((now() AT TIME ZONE 'UTC')::date + run_at) AT TIME ZONE 'UTC'
      AND (last_run_at IS NULL OR last_run_at < ((now() AT TIME ZONE 'UTC')::date + run_at) AT TIME ZONE 'UTC')
    SQL
    due = DB[:scheduled_tasks].where(Sequel.lit(due_sql)).all

    if due.empty?
      puts "No tasks due."
      next
    end

    due.each do |row|
      puts "Running scheduled task: #{row[:name]}"
      begin
        Rake::Task[row[:name]].invoke
        DB[:scheduled_tasks].where(id: row[:id]).update(last_run_at: Sequel::CURRENT_TIMESTAMP)
        puts "  OK"
      rescue StandardError, SystemExit => e
        # SystemExit is caught too: some tasks (e.g. stats:daily_summary) call
        # `abort` on misconfiguration, which must not stop other due tasks in this tick.
        warn "  FAILED: #{e.class}: #{e.message}"
      end
    end
  end
end
