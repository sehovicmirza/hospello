require "test_helper"

# webhook_events is the one table in this app that is deliberately NOT
# tenant-scoped (see this model's own class comment and
# db/migrate/*_create_webhook_events.rb for why) — so, unlike almost every
# other model test in this suite, none of these need a with_tenant block at
# all: WebhookEvent.create! works the same everywhere, with no ambient
# tenant required or even possible.
#
# The guarantee this file exists to prove, the same way
# test/models/whatsapp_channel_test.rb proves phone_number_id's global
# uniqueness: two deliveries of the same (provider, external_id) pair must
# produce exactly one row, and that has to be the database's guarantee, not
# merely a Rails validation's — a validation can be raced (two concurrent
# requests, both SELECTs clean, both INSERTs proceed) or bypassed (this
# app's own Webhooks::WhatsappController writes rows with insert_all, which
# skips every Rails validation entirely — see that controller).
class WebhookEventTest < ActiveSupport::TestCase
  test "provider, external_id and payload are all required" do
    event = WebhookEvent.new

    assert_not event.valid?
    assert_includes event.errors[:provider], "can't be blank"
    assert_includes event.errors[:external_id], "can't be blank"
    assert_includes event.errors[:payload], "can't be blank"
  end

  # Hash#blank? is true for {} — an empty payload is exactly as useless as a
  # missing one: there is no legitimate "received an event with no body."
  test "an empty payload hash is invalid, not merely a missing one" do
    event = WebhookEvent.new(provider: :meta_cloud, external_id: "wamid.TEST1", payload: {})

    assert_not event.valid?
    assert_includes event.errors[:payload], "can't be blank"
  end

  test "a fully-formed event is valid, hotel included" do
    event = WebhookEvent.new(
      provider: :meta_cloud, external_id: "wamid.TEST1", payload: { "object" => "whatsapp_business_account" }
    )

    assert event.valid?, event.errors.full_messages.to_sentence
  end

  test "status defaults to received" do
    event = WebhookEvent.create!(provider: :meta_cloud, external_id: "wamid.TEST1", payload: { "a" => 1 })

    assert event.received?
  end

  test "hotel starts nil — there is no tenant to assign until routing resolves one" do
    event = WebhookEvent.create!(provider: :meta_cloud, external_id: "wamid.TEST1", payload: { "a" => 1 })

    assert_nil event.hotel_id
    assert event.valid?
  end

  test "a hotel may be attached once routing resolves one" do
    event = WebhookEvent.create!(
      provider: :meta_cloud, external_id: "wamid.TEST1", payload: { "a" => 1 }, hotel: hotels(:stari_grad)
    )

    assert_equal hotels(:stari_grad), event.hotel
  end

  # The pairing that matters: the SAME external_id must be free to recur
  # under a DIFFERENT provider (two providers' ids are different namespaces
  # and could coincide by chance) while being refused under the SAME
  # provider (a genuine replay).
  test "the same external_id may recur under a different provider with no conflict" do
    WebhookEvent.create!(provider: :meta_cloud, external_id: "shared-id", payload: { "a" => 1 })
    other_provider = WebhookEvent.new(provider: :twilio, external_id: "shared-id", payload: { "a" => 2 })

    assert other_provider.valid?, other_provider.errors.full_messages.to_sentence
  end

  test "the same (provider, external_id) pair may not repeat" do
    WebhookEvent.create!(provider: :meta_cloud, external_id: "shared-id", payload: { "a" => 1 })
    duplicate = WebhookEvent.new(provider: :meta_cloud, external_id: "shared-id", payload: { "a" => 2 })

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:external_id], "has already been taken"
  end

  # The validation above can be raced or bypassed (Webhooks::WhatsappController
  # itself bypasses it on every real request, via insert_all) — only a real
  # unique index makes the collision this table exists to prevent actually
  # impossible. Proven here the same way whatsapp_channel_test.rb proves its
  # own equivalent: save!(validate: false) skips every one of this model's
  # own checks, so if this still raises, nothing but Postgres itself is
  # refusing the duplicate.
  test "the database itself refuses a duplicate (provider, external_id) pair, independent of the Rails validation" do
    WebhookEvent.create!(provider: :meta_cloud, external_id: "shared-id", payload: { "a" => 1 })
    duplicate = WebhookEvent.new(provider: :meta_cloud, external_id: "shared-id", payload: { "a" => 2 })

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end
end
