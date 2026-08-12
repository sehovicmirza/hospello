# One message template a hotel has registered with Meta, and where that
# registration got to.
#
# **This table records Meta's decisions; it does not make them.** Outside the
# 24-hour customer service window (see Whatsapp::WindowClosedError) a
# pre-approved template is the only thing a hotel may send, and only Meta
# decides what is approved. A row saying `approved` is a hotel's note of what
# Meta told them — useful for answering "is our welcome message usable yet?"
# without logging into Meta's dashboard, and never a permission this app
# grants. `#usable?` is a cheap pre-check that saves a doomed API call, not a
# gate: Meta refuses an unapproved template whatever this row says.
#
# Slice 6 ships no send path for templates at all and deliberately no
# bulk-send UI — an un-opted-in send risks the hotel's number, which is the
# hotel's asset and not ours (see docs/plan/slice-6-tasks.md).
class WhatsappTemplate < ApplicationRecord
  include TenantScoped

  # Meta's own three, which decide both the pricing and the rules a template
  # is judged under. Not cosmetic: a `marketing` template sent to someone who
  # did not explicitly opt in is what actually gets a number restricted, and
  # the welcome message this slice cares about is `utility`.
  enum :category, { utility: 0, marketing: 1, authentication: 2 }, prefix: true

  # What Meta said. `prefix: true` because `approved?`/`rejected?` read as
  # claims this app is making otherwise, and it is making none of them.
  enum :status, { pending: 0, approved: 1, rejected: 2 }, prefix: true

  # Meta's rule, not ours: lowercase letters, digits and underscores. Checked
  # here so a hotel finds out while typing rather than from a send that fails
  # hours later against a name Meta never had.
  NAME_FORMAT = /\A[a-z0-9_]+\z/

  MAX_NAME_LENGTH = 512

  validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH },
                   format: { with: NAME_FORMAT, message: "may use only lowercase letters, numbers and underscores" }
  validates :locale, presence: true
  # A template is identified by name AND language at Meta — "welcome" in bs
  # and "welcome" in de are two separately-approved objects. The composite
  # unique index is the guarantee; this is the friendly error.
  validates :name, uniqueness: { scope: %i[hotel_id locale], case_sensitive: false }

  scope :ordered, -> { order(:name, :locale) }

  # The only state in which sending can possibly work. Deliberately narrow:
  # `pending` is not "probably fine" — Meta rejects it — and this is the
  # predicate any future send path should consult before spending a request.
  def usable? = status_approved?
end
