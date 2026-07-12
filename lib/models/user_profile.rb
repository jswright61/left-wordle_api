# frozen_string_literal: true

class UserProfile < Sequel::Model(:user_profiles)
  unrestrict_primary_key
  many_to_one :user
end
