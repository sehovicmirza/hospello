class Current < ActiveSupport::CurrentAttributes
  attribute :session, :hotel, :guest_session
  delegate :user, to: :session, allow_nil: true
end
