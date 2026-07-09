# frozen_string_literal: true

require "bcrypt"

class User < Sequel::Model(:users)
  def self.authenticate(username, password)
    user = first(username: username)
    return nil unless user && BCrypt::Password.new(user.password_digest) == password

    user
  end

  def password=(new_password)
    self.password_digest = BCrypt::Password.create(new_password).to_s
  end
end
