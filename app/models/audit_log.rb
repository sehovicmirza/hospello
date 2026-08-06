class AuditLog < ApplicationRecord
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :hotel, optional: true
  belongs_to :target, polymorphic: true, optional: true

  validates :action, presence: true

  # AuditLog is exempt from acts_as_tenant (platform actions may have no hotel),
  # so a bare AuditLog relation crosses hotels without raising. Inside a hotel
  # context read entries through this scope.
  scope :for_hotel, ->(hotel) { where(hotel: hotel) }

  def self.record!(actor:, action:, hotel: nil, target: nil, metadata: {})
    create!(actor_user: actor, hotel: hotel, action: action, target: target, metadata: metadata)
  end
end
