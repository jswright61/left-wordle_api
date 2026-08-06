# frozen_string_literal: true

require "rake"

require_relative "test_helper"
require_relative "../lib/models/scheduled_task"

class SchedulerTest < Minitest::Test
  DUMMY_TASK_NAME = "scheduler_test:dummy_task"

  REAL_TASK_NAMES = %w[stats:daily_summary storage_snapshots:prune].freeze

  def setup
    ScheduledTask.where(name: DUMMY_TASK_NAME).delete

    # These rows are real production task names seeded via `scheduler:seed`.
    # scheduler:tick pulls every due row from the table, not just the ones a
    # test creates, and the fresh Rake::Application below only loads
    # scheduler.rake -- so if these are left in place and due, tick tries to
    # invoke tasks that were never loaded and warns "Don't know how to build
    # task" on every run. Remove them for the duration of the test and
    # restore in teardown.
    @original_real_tasks = REAL_TASK_NAMES.map { |name| ScheduledTask.first(name: name) }
    ScheduledTask.where(name: REAL_TASK_NAMES).delete

    Rake.application = Rake::Application.new
    load File.expand_path("../lib/tasks/scheduler.rake", __dir__)
  end

  def teardown
    ScheduledTask.where(name: DUMMY_TASK_NAME).delete

    REAL_TASK_NAMES.zip(@original_real_tasks).each do |name, original|
      restore_scheduled_task_row(name, original)
    end
  end

  def test_tick_runs_a_due_task_and_records_last_run_at
    calls = 0
    Rake::Task.define_task(DUMMY_TASK_NAME) { calls += 1 }
    task = ScheduledTask.create(name: DUMMY_TASK_NAME, run_at: "00:00:00", enabled: true)

    Rake::Task["scheduler:tick"].invoke

    assert_equal 1, calls
    refute_nil task.refresh.last_run_at
  end

  def test_tick_skips_a_task_not_yet_due_today
    calls = 0
    Rake::Task.define_task(DUMMY_TASK_NAME) { calls += 1 }
    task = ScheduledTask.create(name: DUMMY_TASK_NAME, run_at: "23:59:59", enabled: true)

    Rake::Task["scheduler:tick"].invoke

    assert_equal 0, calls
    assert_nil task.refresh.last_run_at
  end

  def test_tick_skips_a_task_already_run_today
    calls = 0
    Rake::Task.define_task(DUMMY_TASK_NAME) { calls += 1 }
    ScheduledTask.create(name: DUMMY_TASK_NAME, run_at: "00:00:00", enabled: true, last_run_at: Time.now)

    Rake::Task["scheduler:tick"].invoke

    assert_equal 0, calls
  end

  def test_tick_reruns_a_task_that_last_ran_before_todays_scheduled_instant
    calls = 0
    Rake::Task.define_task(DUMMY_TASK_NAME) { calls += 1 }
    task = ScheduledTask.create(
      name: DUMMY_TASK_NAME, run_at: "00:00:00", enabled: true, last_run_at: Time.now - 90_000
    )
    original_last_run_at = task.last_run_at

    Rake::Task["scheduler:tick"].invoke

    assert_equal 1, calls
    assert task.refresh.last_run_at > original_last_run_at
  end

  def test_tick_skips_a_disabled_task
    calls = 0
    Rake::Task.define_task(DUMMY_TASK_NAME) { calls += 1 }
    ScheduledTask.create(name: DUMMY_TASK_NAME, run_at: "00:00:00", enabled: false)

    Rake::Task["scheduler:tick"].invoke

    assert_equal 0, calls
  end

  def test_tick_does_not_record_last_run_at_when_the_task_raises
    Rake::Task.define_task(DUMMY_TASK_NAME) { raise "boom" }
    task = ScheduledTask.create(name: DUMMY_TASK_NAME, run_at: "00:00:00", enabled: true)

    Rake::Task["scheduler:tick"].invoke

    assert_nil task.refresh.last_run_at
  end

  def test_tick_continues_past_a_task_that_calls_abort
    Rake::Task.define_task(DUMMY_TASK_NAME) { abort "misconfigured" }
    other_calls = 0
    Rake::Task.define_task("scheduler_test:other_dummy_task") { other_calls += 1 }
    task = ScheduledTask.create(name: DUMMY_TASK_NAME, run_at: "00:00:00", enabled: true)
    ScheduledTask.create(name: "scheduler_test:other_dummy_task", run_at: "00:00:00", enabled: true)

    Rake::Task["scheduler:tick"].invoke

    assert_nil task.refresh.last_run_at
    assert_equal 1, other_calls
  ensure
    ScheduledTask.where(name: "scheduler_test:other_dummy_task").delete
  end

  def test_seed_creates_the_stats_daily_summary_row
    original = ScheduledTask.first(name: "stats:daily_summary")
    ScheduledTask.where(name: "stats:daily_summary").delete

    Rake::Task["scheduler:seed"].invoke

    task = ScheduledTask.first(name: "stats:daily_summary")
    refute_nil task
    assert_equal true, task.enabled
    assert_equal Sequel::SQLTime.parse("05:15:00"), task.run_at
  ensure
    restore_stats_daily_summary_row(original)
  end

  def test_seed_does_not_overwrite_an_existing_row
    original = ScheduledTask.first(name: "stats:daily_summary")
    ScheduledTask.where(name: "stats:daily_summary").delete
    ScheduledTask.create(name: "stats:daily_summary", run_at: "12:00:00", enabled: false)

    Rake::Task["scheduler:seed"].invoke

    task = ScheduledTask.first(name: "stats:daily_summary")
    assert_equal Sequel::SQLTime.parse("12:00:00"), task.run_at
    assert_equal false, task.enabled
  ensure
    restore_stats_daily_summary_row(original)
  end

  def test_seed_creates_the_storage_snapshots_prune_row
    original = ScheduledTask.first(name: "storage_snapshots:prune")
    ScheduledTask.where(name: "storage_snapshots:prune").delete

    Rake::Task["scheduler:seed"].invoke

    task = ScheduledTask.first(name: "storage_snapshots:prune")
    refute_nil task
    assert_equal true, task.enabled
    assert_equal Sequel::SQLTime.parse("04:00:00"), task.run_at
  ensure
    restore_scheduled_task_row("storage_snapshots:prune", original)
  end

  private

  def restore_stats_daily_summary_row(original)
    restore_scheduled_task_row("stats:daily_summary", original)
  end

  def restore_scheduled_task_row(name, original)
    ScheduledTask.where(name: name).delete
    return unless original

    ScheduledTask.create(
      name: name, run_at: original.run_at,
      enabled: original.enabled, last_run_at: original.last_run_at
    )
  end
end
