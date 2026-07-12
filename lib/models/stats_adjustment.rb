# frozen_string_literal: true

class StatsAdjustment < Sequel::Model(:stats_adjustments)
  many_to_one :user
end
