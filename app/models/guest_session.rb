# A guest's identity for the duration of their stay: created once at the
# entry form (this task) or by the WhatsApp `set_guest_room` tool (Slice 6),
# then read back on every later request via a signed, httponly cookie
# (`hospello_guest`, set by Guest::EntriesController) so a guest never
# re-enters their name and room. Always TenantScoped — see #authenticate_by_token
# below for the one deliberate, narrow exception this requires.
class GuestSession < ApplicationRecord
  include TenantScoped

  # web: 0, whatsapp: 1 — Slice 6 adds whatsapp sessions; this task only
  # ever creates :web ones (Guest::EntriesController never sets channel
  # explicitly, so every session it creates gets the column default).
  enum :channel, { web: 0, whatsapp: 1 }

  # unverified: 0, staff_verified: 1. Every session is created unverified —
  # #force_unverified_identity_on_create below is what actually makes that
  # true regardless of what a request or a caller assigns; there is no
  # staff-verification workflow in this slice.
  enum :identity_status, { unverified: 0, staff_verified: 1 }

  # active: 0, blocked: 1
  enum :status, { active: 0, blocked: 1 }

  belongs_to :room, optional: true

  # Review round 1, IMPORTANT 9: this used to run `on: :create` only, so
  # `session.update(identity_status: :staff_verified)` silently succeeded —
  # the guard was scoped to "at creation," but nothing stopped a later
  # write from flipping it. Running on every save (no `on:` restriction)
  # makes "a guest session is always unverified" hold on the write path in
  # general, not just at the moment of construction: there is no staff-
  # verification workflow in this slice, but a future one now has to reach
  # for something more deliberate than a plain attribute update to trip
  # over this by accident — e.g. `update_column`/`update_columns`, which
  # bypass callbacks entirely and so are visibly a different, more
  # deliberate kind of write than an ordinary `update`.
  before_validation :force_unverified_identity

  validates :guest_name, presence: true
  validates :locale, inclusion: { in: GuestLocaleHelper::SUPPORTED_LOCALES }
  validates :privacy_accepted_at, presence: true
  validates :expires_at, presence: true
  validate :room_must_belong_to_the_same_hotel

  class << self
    # Digest, never the raw token — the cookie carries the raw value, only
    # its digest is ever written to the database, so a database leak does
    # not hand over live guest sessions.
    def digest(raw_token)
      Digest::SHA256.hexdigest(raw_token.to_s)
    end

    # A guest's cookie carries only the raw token — no hotel context — so
    # this is the one legitimate place GuestSession must be looked up
    # *before* its tenant is known (Guest::BaseController calls this first,
    # then sets Current.hotel / ActsAsTenant.current_tenant from the
    # *result* — see that controller for why a guest request is never
    # allowed to name its own hotel).
    #
    # Deliberately none of the four blanket tenant-scope escape hatches this
    # codebase reserves for app/controllers/platform/ alone (see the ESCAPES
    # list in test/tenancy/without_tenant_grep_test.rb — each one is a
    # "stop enforcing the tenant scope here" switch, exactly the kind of
    # thing that is dangerous to reach for casually outside that one
    # namespace). find_by_sql never touches acts_as_tenant's default_scope
    # at all (it builds records straight from a raw SQL row, bypassing
    # Relation/scope construction entirely), so it needs no escape hatch and
    # sets no tenant anywhere — this is a
    # single index lookup keyed on an unguessable 32-byte random digest, the
    # same shape as Session.find_by(token:) for staff sign-in (Session
    # carries no hotel_id and so sits outside acts_as_tenant altogether), not
    # a general-purpose cross-tenant query.
    def authenticate_by_token(raw_token)
      return nil if raw_token.blank?

      session = find_by_sql(
        [ "SELECT * FROM guest_sessions WHERE token_digest = ? LIMIT 1", digest(raw_token) ]
      ).first
      return nil unless session
      return nil unless session.active?
      return nil if session.expired?

      session
    end
  end

  def expired?
    expires_at.blank? || expires_at.past?
  end

  # Bumps last_seen_at to now and extends expires_at 7 days out from now —
  # but never past 21 days from creation, so a guest who chats every day for
  # months can't roll the session forward indefinitely.
  #
  # update_columns, not update!: this runs on essentially every guest
  # interaction (Task 2's chat calls it on every message), so it skips
  # re-validating the whole record — including #room_must_belong_to_the_same_hotel,
  # which needs an ambient tenant a routine "bump the timestamps" call has no
  # business requiring — and writes the two columns directly instead.
  def touch_activity!
    now = Time.current
    update_columns(last_seen_at: now, expires_at: [ now + 7.days, created_at + 21.days ].min)
  end

  private
    # There is no code path — staff-initiated, mass-assigned, or otherwise —
    # that can produce a verified session through a normal save, at
    # creation or later. Runs after mass assignment (attributes are already
    # set from whatever new/create/update was handed) and immediately
    # before the row is validated/saved, so it overwrites any
    # identity_status a caller tried to set.
    def force_unverified_identity
      self.identity_status = :unverified
    end

    # Same defense RequestCategory#department_must_belong_to_the_same_hotel
    # documents in full: acts_as_tenant's own belongs_to validation only
    # covers associations declared before `include TenantScoped` runs, and
    # even then only catches an *id* assignment, not an *object* assignment
    # (`session.room = some_other_hotels_room` hands back the exact object
    # with no query at all). Re-querying Room by id — itself tenant-scoped —
    # closes both gaps: a foreign room_id looks exactly like a nonexistent
    # one from here, which is exactly the property wanted.
    def room_must_belong_to_the_same_hotel
      return if room_id.blank?

      errors.add(:room, "must belong to the same hotel") unless Room.where(id: room_id).exists?
    end
end
