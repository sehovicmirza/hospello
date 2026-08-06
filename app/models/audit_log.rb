class AuditLog < ApplicationRecord
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :hotel, optional: true
  belongs_to :target, polymorphic: true, optional: true

  validates :action, presence: true

  def self.record!(actor:, action:, hotel: nil, target: nil, metadata: {})
    create!(actor_user: actor, hotel: hotel, action: action, target: target, metadata: metadata)
  end
end
