# One thing a hotel has written down about itself. Collectively, these are
# the *only* source the Slice 3 concierge may answer a hotel question from —
# it never invents a price, an opening time, an availability, or a policy —
# so this model's job is to make "what may a guest be told" an explicit,
# deliberate decision rather than a side effect.
#
# Two properties matter more than they look:
#
# - **Unpublished by default.** An entry reaches guests only when someone
#   says so. See the migration.
# - **Deterministic ordering.** The hotel's knowledge is a cached prompt
#   prefix, and the cache only hits on an exact match, so `ordered` must
#   produce the same sequence on every build — hence the id tiebreak, which
#   is load-bearing rather than tidy (Postgres promises nothing for ties).
class KbEntry < ApplicationRecord
  include TenantScoped

  # Kept deliberately short and guest-shaped. These are the buckets a hotel
  # manager can sort their own knowledge into without thinking, and they
  # travel into the prompt as an attribute on each entry, so adding one is
  # a prompt change as well as a UI change.
  enum :category, {
    facilities: 0, dining: 1, rooms: 2, policies: 3,
    local_area: 4, transport: 5, other: 6
  }

  MAX_CONTENT_LENGTH = 2000

  normalizes :title, with: ->(title) { title.strip }

  validates :title, presence: true, uniqueness: { scope: :hotel_id }
  validates :content, presence: true, length: {
    maximum: MAX_CONTENT_LENGTH,
    message: "is too long — please keep an entry under #{MAX_CONTENT_LENGTH} characters, " \
             "and split long topics into separate entries"
  }

  scope :published, -> { where(published: true) }
  scope :drafts, -> { where(published: false) }
  scope :ordered, -> { order(:position, :id) }
end
