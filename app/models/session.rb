class Session < ApplicationRecord
  belongs_to :user

  # The cookie carries this token, not the row id, so a session identifier is
  # never guessable from a sequence.
  has_secure_token :token
end
