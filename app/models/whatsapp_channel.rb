# One hotel, one WhatsApp number, one row — the hotel's own branded second
# channel (Slice 6) alongside the QR web chat. A row existing says nothing
# about whether the number actually works yet; #status does (see the enum
# below and the Task 4 staff settings screen).
#
# phone_number_id — Meta's own opaque routing id, not the displayed number —
# is the column Slice 6 Task 3's inbound webhook actually keys off of, and it
# is globally unique across every hotel this app serves, not merely unique
# within one: see db/migrate/*_create_whatsapp_channels.rb for why a
# collision there is the worst failure available in this slice, and this
# model's uniqueness validations (backed by the migration's plain,
# non-partial unique indexes) for how it is refused twice over — once with a
# friendly validation error, and once, unconditionally, by Postgres itself
# (see test/models/whatsapp_channel_test.rb's "the database itself refuses…"
# tests, which switch validation off to prove the index is what is really
# doing the work).
class WhatsappChannel < ApplicationRecord
  include TenantScoped

  # meta_cloud: 0, three_sixty_dialog: 1, twilio: 2 — Slice 6 ships exactly
  # one adapter (see Whatsapp::Provider.for). The BSP decision is still open
  # (see the plan's blocking questions), so the other two exist here now
  # precisely so that choice is a config/adapter swap later, never a
  # migration.
  enum :provider, { meta_cloud: 0, three_sixty_dialog: 1, twilio: 2 }

  # pending: 0 (registered but not yet confirmed working), active: 1
  # (sending and receiving), disabled: 2 (deliberately turned off).
  enum :status, { pending: 0, active: 1, disabled: 2 }

  # The inbound routing lookup, and the one query in this app that has to
  # find a WhatsappChannel *before* a tenant is known — because the answer is
  # what picks the tenant. Called by Whatsapp::InboundRouter, which runs from
  # a TenantFree job with no ambient hotel at all.
  #
  # Deliberately none of the four blanket tenant-scope escape hatches this
  # codebase reserves for app/controllers/platform/ (see the ESCAPES list in
  # test/tenancy/without_tenant_grep_test.rb — each is a "stop enforcing the
  # tenant scope here" switch, and reaching for one casually outside that
  # namespace is exactly what that tripwire exists to prevent). find_by_sql
  # never touches acts_as_tenant's default_scope at all — it builds records
  # straight from a raw SQL row, bypassing Relation/scope construction —
  # so it needs no escape hatch and sets no tenant anywhere. The same
  # reasoning, and the same shape, as GuestSession.authenticate_by_token,
  # which is the only other query in this app with the same problem; both are
  # named individually in that test's ALLOWLIST rather than exempted by file.
  #
  # Safe to do unscoped precisely because phone_number_id is globally unique
  # (a plain, non-partial index — see the migration): there is exactly one
  # row this can return, so "which hotel" has one answer and the caller
  # cannot be handed a near-miss belonging to somebody else.
  def self.route(phone_number_id)
    return nil if phone_number_id.blank?

    find_by_sql(
      [ "SELECT * FROM whatsapp_channels WHERE phone_number_id = ? LIMIT 1", phone_number_id ]
    ).first
  end

  validates :phone_number_e164, presence: true, uniqueness: true
  validates :phone_number_id, presence: true, uniqueness: true
  # The has_one side of the association: at most one channel per hotel.
  # Race-prone the same way any "is there already one?" check is, which is
  # exactly why the migration backs it with a real unique index too — this
  # validation is the friendly error; the index is the guarantee.
  validates :hotel_id, uniqueness: true
  validate :phone_number_e164_must_be_a_valid_number

  private
    # Phonelib, not a hand-rolled regex — a real phone-number library knows
    # which country codes and lengths actually exist. Declared in the
    # Gemfile ahead of this slice specifically for this ("Phone
    # normalization ... WhatsApp routing"); this is its first use.
    def phone_number_e164_must_be_a_valid_number
      return if phone_number_e164.blank?

      unless Phonelib.valid?(phone_number_e164)
        errors.add(:phone_number_e164, "must be a valid phone number in E.164 format (e.g. +38761234567)")
      end
    end
end
