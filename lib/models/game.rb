# frozen_string_literal: true

class Game < Sequel::Model(:games)
  many_to_one :user
end
