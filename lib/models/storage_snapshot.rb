# frozen_string_literal: true

class StorageSnapshot < Sequel::Model(:storage_snapshots)
  many_to_one :user
end
