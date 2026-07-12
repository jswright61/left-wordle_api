# frozen_string_literal: true

class Session < Sequel::Model(:sessions)
  many_to_one :user

  def active?
    revoked_at.nil? && expires_at > Time.now
  end
end
