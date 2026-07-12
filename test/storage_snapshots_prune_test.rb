# frozen_string_literal: true

require "rake"

require_relative "test_helper"
require_relative "../lib/models/storage_snapshot"
require_relative "../lib/models/user"

class StorageSnapshotsPruneTest < Minitest::Test
  def setup
    Rake.application = Rake::Application.new
    load File.expand_path("../lib/tasks/storage_snapshots.rake", __dir__)
    @user = User.create
  end

  def teardown
    @user.destroy
  end

  def test_prune_deletes_snapshots_older_than_30_days
    stale = create_snapshot!
    DB[:storage_snapshots].where(id: stale.id).update(created_at: Time.now - (31 * 24 * 60 * 60))
    fresh = create_snapshot!

    Rake::Task["storage_snapshots:prune"].invoke

    assert_nil StorageSnapshot[stale.id]
    refute_nil StorageSnapshot[fresh.id]
  end

  def test_prune_keeps_snapshots_within_the_retention_window
    recent = create_snapshot!
    DB[:storage_snapshots].where(id: recent.id).update(created_at: Time.now - (29 * 24 * 60 * 60))

    Rake::Task["storage_snapshots:prune"].invoke

    refute_nil StorageSnapshot[recent.id]
  end

  private

  def create_snapshot!
    StorageSnapshot.create(user_id: @user.id, event: "new user creation", local_storage: Sequel.pg_json({}))
  end
end
