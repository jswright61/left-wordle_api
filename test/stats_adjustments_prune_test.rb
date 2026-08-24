# frozen_string_literal: true

require "rake"

require_relative "test_helper"
require_relative "../lib/models/stats_adjustment"
require_relative "../lib/models/user"

class StatsAdjustmentsPruneTest < Minitest::Test
  def setup
    Rake.application = Rake::Application.new
    load File.expand_path("../lib/tasks/stats_adjustments.rake", __dir__)
    @user = User.create
  end

  def teardown
    @user.destroy
  end

  def test_prune_deletes_adjustments_older_than_90_days
    stale = create_adjustment!
    DB[:stats_adjustments].where(id: stale.id).update(created_at: Time.now - (91 * 24 * 60 * 60))
    fresh = create_adjustment!

    Rake::Task["stats_adjustments:prune"].invoke

    assert_nil StatsAdjustment[stale.id]
    refute_nil StatsAdjustment[fresh.id]
  end

  def test_prune_keeps_adjustments_within_the_retention_window
    recent = create_adjustment!
    DB[:stats_adjustments].where(id: recent.id).update(created_at: Time.now - (89 * 24 * 60 * 60))

    Rake::Task["stats_adjustments:prune"].invoke

    refute_nil StatsAdjustment[recent.id]
  end

  private

  def create_adjustment!
    StatsAdjustment.create(
      user_id: @user.id, before: Sequel.pg_json({}), after: Sequel.pg_json({}),
      source: "manual", event_desc: "test"
    )
  end
end
