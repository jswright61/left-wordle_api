# frozen_string_literal: true

class DeviceLinkToken < Sequel::Model(:device_link_tokens)
  many_to_one :user

  def redeemable?
    consumed_at.nil? && expires_at > Time.now
  end
end
