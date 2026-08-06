class Current < ActiveSupport::CurrentAttributes
  attribute :session, :hotel
  delegate :user, to: :session, allow_nil: true
end
