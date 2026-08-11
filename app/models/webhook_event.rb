# The webhook boundary's own durable record: one row per distinct provider
# message/status delivery, written by Webhooks::WhatsappController the
# instant a signature verifies — before anything downstream is known,
# including which hotel this belongs to.
#
# Deliberately NOT TenantScoped/acts_as_tenant, unlike every other model in
# this app (see test/tenancy/tenant_declaration_test.rb's EXEMPT list, which
# names this class with the same reasoning written there). #hotel_id starts
# nil and is filled in once Slice 6 Task 3's Whatsapp::InboundRouter resolves
# a phone_number_id to a WhatsappChannel/Hotel — there is no tenant to scope
# this table to until that lookup has happened, and the lookup itself has to
# read this row *to do its job*, so acts_as_tenant's own require_tenant guard
# would make that lookup impossible even in principle, not merely
# inconvenient. See db/migrate/*_create_webhook_events.rb for the same note
# from the schema's side.
class WebhookEvent < ApplicationRecord
  belongs_to :hotel, optional: true

  # meta_cloud: 0, three_sixty_dialog: 1, twilio: 2 — mirrors
  # WhatsappChannel#provider's own numbering (see that model), even though
  # this Slice only ever writes meta_cloud rows here: this table sits one
  # layer below any single channel's adapter, at the webhook boundary
  # itself, so its own vocabulary for "which provider sent this" should not
  # quietly drift from the channel model's.
  enum :provider, { meta_cloud: 0, three_sixty_dialog: 1, twilio: 2 }

  # received: 0 (stored, nothing has looked at it yet) · processed: 1
  # (routed and handled) · ignored: 2 (parsed fine but had nowhere to go —
  # an unknown phone_number_id, e.g. — Slice 6 Task 3's Whatsapp::InboundRouter
  # sets this, and only this, never raising) · failed: 3 (routed but
  # something downstream broke; #error carries why).
  enum :status, { received: 0, processed: 1, ignored: 2, failed: 3 }

  # scope: :provider, not a bare uniqueness: true — the guarantee this table
  # exists to prove is that the same (provider, external_id) *pair* never
  # repeats, not that external_id is globally unique on its own (two
  # different providers' ids live in different namespaces and could
  # coincide by chance; see the migration's composite unique index, which
  # this mirrors). This validation is the friendly error a caller that
  # builds a WebhookEvent the ordinary way (.create!) would see; the
  # composite unique index is what actually makes the collision impossible
  # — Webhooks::WhatsappController itself never goes through this
  # validation at all, since it writes with insert_all, which bypasses
  # every Rails validation by design (see that controller).
  validates :provider, presence: true
  validates :external_id, presence: true, uniqueness: { scope: :provider }
  validates :payload, presence: true
end
