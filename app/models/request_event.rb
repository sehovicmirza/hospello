# One thing that happened to a service request: a status change, an
# assignment, or a note somebody wrote.
#
# All three share a table because to the receptionist reading the history they
# are one list, in order, of what happened. `kind` is what decides whether the
# guest may be told: a `status_change` becomes a guest-visible update (Slice 4
# Task 3), a `note` never does.
class RequestEvent < ApplicationRecord
  include TenantScoped

  enum :kind, { status_change: 0, assignment: 1, note: 2 }, prefix: true

  belongs_to :service_request
  belongs_to :user, optional: true

  validates :note, presence: true, if: :kind_note?

  scope :chronological, -> { order(:id) }

  # What a guest may see. Not a scope over `kind` alone, because an assignment
  # names a member of staff and "your request was given to Amila" is the
  # hotel's internal business, not the guest's.
  scope :guest_visible, -> { kind_status_change }

  def from_status_name = from_status && ServiceRequest.statuses.key(from_status)

  def to_status_name = to_status && ServiceRequest.statuses.key(to_status)
end
