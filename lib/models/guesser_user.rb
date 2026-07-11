# frozen_string_literal: true

require "bcrypt"

class GuesserUser < Sequel::Model(:guesser_users)
  def self.authenticate(username, password)
    user = first(username: username)
    return nil unless user&.approved_and_active? && BCrypt::Password.new(user.password_digest) == password

    user
  end

  def approved_and_active?
    !approved_at.nil? && approved_at <= Time.now &&
      (deactivated_at.nil? || deactivated_at > Time.now)
  end

  def password=(new_password)
    self.password_digest = BCrypt::Password.create(new_password).to_s
  end
end
