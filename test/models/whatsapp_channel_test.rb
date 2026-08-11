require "test_helper"

# whatsapp_channels is one row per hotel — the hotel's own branded WhatsApp
# number and the Meta Cloud status that goes with it (Slice 6). The
# guarantee this file exists to prove: phone_number_id (Meta's own routing
# id, not the displayed number — see that column's comment in the migration)
# is how Slice 6 Task 3's inbound webhook finds its tenant, so a collision
# between two hotels would route one hotel's guests into another's
# dashboard — the worst failure available in this slice. That has to be the
# database's guarantee, not merely a Rails validation's: a validation can be
# raced (two concurrent requests, both SELECTs clean, both INSERTs proceed)
# or bypassed (`save(validate: false)`); a unique index cannot.
#
# Deliberately does NOT build channels on hotels(:stari_grad)/(:vrelo) for
# most of these — those fixtures already own a whatsapp_channel fixture
# (whatsapp_channels(:stari_grad_whatsapp)/(:vrelo_whatsapp), used by the
# association-read tests at the bottom and reserved for later tasks that
# want a hotel with a ready-made channel), which would pre-occupy the
# one-channel-per-hotel slot these tests are specifically about — the same
# reasoning test/models/conversation_test.rb documents for why it uses
# #fresh_guest_session instead of the shared conversation fixtures.
# #fresh_hotel below builds an otherwise-identical throwaway hotel with no
# channel yet.
class WhatsappChannelTest < ActiveSupport::TestCase
  test "hotel, phone_number_e164 and phone_number_id are all required" do
    hotel = fresh_hotel

    with_tenant(hotel) do
      channel = hotel.build_whatsapp_channel

      assert_not channel.valid?
      assert_includes channel.errors[:phone_number_e164], "can't be blank"
      assert_includes channel.errors[:phone_number_id], "can't be blank"
    end
  end

  test "phone_number_e164 must be a real, parseable phone number" do
    hotel = fresh_hotel

    with_tenant(hotel) do
      channel = hotel.build_whatsapp_channel(phone_number_e164: "not-a-number", phone_number_id: "1")

      assert_not channel.valid?
      assert_includes channel.errors[:phone_number_e164],
        "must be a valid phone number in E.164 format (e.g. +38761234567)"
    end
  end

  test "a plausible E.164 number is accepted" do
    hotel = fresh_hotel

    with_tenant(hotel) do
      channel = hotel.build_whatsapp_channel(phone_number_e164: "+38761234567", phone_number_id: "1")

      assert channel.valid?, channel.errors.full_messages.to_sentence
    end
  end

  test "a hotel may have at most one whatsapp channel" do
    hotel = fresh_hotel

    with_tenant(hotel) do
      hotel.create_whatsapp_channel!(phone_number_e164: "+38762100100", phone_number_id: "id-100")

      # WhatsappChannel.new directly, not hotel.build_whatsapp_channel: on an
      # already-loaded has_one, Rails' own build_ helper tries to be
      # "helpful" by orphaning the existing associated row first (nilling
      # its foreign key) rather than leaving it alone — the opposite of what
      # this test is trying to prove is refused. Building the second row by
      # hand is what actually exercises "can a hotel end up with two."
      second = WhatsappChannel.new(hotel: hotel, phone_number_e164: "+38762100200", phone_number_id: "id-200")

      assert_not second.valid?
      assert_includes second.errors[:hotel_id], "has already been taken"
    end
  end

  # The guarantee the brief calls the single worst failure available in this
  # slice: two different hotels must never be able to register the same
  # phone_number_id, because that id — not the displayed number — is what
  # Slice 6 Task 3's webhook uses to decide whose dashboard a guest's
  # message lands on.
  test "phone_number_id must be globally unique, not merely unique per hotel" do
    hotel_a = fresh_hotel
    hotel_b = fresh_hotel

    with_tenant(hotel_a) do
      hotel_a.create_whatsapp_channel!(phone_number_e164: "+38762100100", phone_number_id: "shared-routing-id")
    end

    with_tenant(hotel_b) do
      collider = hotel_b.build_whatsapp_channel(phone_number_e164: "+38762200200", phone_number_id: "shared-routing-id")

      assert_not collider.valid?
      assert_includes collider.errors[:phone_number_id], "has already been taken"
    end
  end

  # The validation above can be raced or bypassed; only a real unique index
  # makes the collision this table exists to prevent actually impossible.
  # Proven here by switching validation off entirely — save!(validate:
  # false) skips every one of this model's own checks, so if this still
  # raises, nothing but Postgres itself is refusing the duplicate.
  test "the database itself refuses a duplicate phone_number_id, independent of the Rails validation" do
    hotel_a = fresh_hotel
    hotel_b = fresh_hotel

    with_tenant(hotel_a) do
      hotel_a.create_whatsapp_channel!(phone_number_e164: "+38762100100", phone_number_id: "shared-routing-id")
    end

    with_tenant(hotel_b) do
      collider = hotel_b.build_whatsapp_channel(phone_number_e164: "+38762200200", phone_number_id: "shared-routing-id")

      assert_raises(ActiveRecord::RecordNotUnique) { collider.save!(validate: false) }
    end
  end

  # The displayed number is not the routing key (phone_number_id is — see
  # above), but Task 4's guest-facing "Chat on WhatsApp" link is built from
  # it, so two hotels sharing one would send a guest's very first message to
  # the wrong hotel before any webhook routing ever happens.
  test "phone_number_e164 must also be globally unique" do
    hotel_a = fresh_hotel
    hotel_b = fresh_hotel

    with_tenant(hotel_a) do
      hotel_a.create_whatsapp_channel!(phone_number_e164: "+38762100100", phone_number_id: "id-100")
    end

    with_tenant(hotel_b) do
      collider = hotel_b.build_whatsapp_channel(phone_number_e164: "+38762100100", phone_number_id: "id-200")

      assert_not collider.valid?
      assert_includes collider.errors[:phone_number_e164], "has already been taken"
    end
  end

  test "the database itself refuses a duplicate phone_number_e164, independent of the Rails validation" do
    hotel_a = fresh_hotel
    hotel_b = fresh_hotel

    with_tenant(hotel_a) do
      hotel_a.create_whatsapp_channel!(phone_number_e164: "+38762100100", phone_number_id: "id-100")
    end

    with_tenant(hotel_b) do
      collider = hotel_b.build_whatsapp_channel(phone_number_e164: "+38762100100", phone_number_id: "id-200")

      assert_raises(ActiveRecord::RecordNotUnique) { collider.save!(validate: false) }
    end
  end

  test "two hotels may each register their own distinct number with no conflict at all" do
    hotel_a = fresh_hotel
    hotel_b = fresh_hotel

    with_tenant(hotel_a) do
      hotel_a.create_whatsapp_channel!(phone_number_e164: "+38762100100", phone_number_id: "id-100")
    end

    with_tenant(hotel_b) do
      channel = hotel_b.build_whatsapp_channel(phone_number_e164: "+38762200200", phone_number_id: "id-200")

      assert channel.valid?, channel.errors.full_messages.to_sentence
    end
  end

  test "provider defaults to meta_cloud" do
    hotel = fresh_hotel

    with_tenant(hotel) do
      channel = hotel.create_whatsapp_channel!(phone_number_e164: "+38762100100", phone_number_id: "id-100")

      assert channel.meta_cloud?
    end
  end

  test "status defaults to pending" do
    hotel = fresh_hotel

    with_tenant(hotel) do
      channel = hotel.create_whatsapp_channel!(phone_number_e164: "+38762100100", phone_number_id: "id-100")

      assert channel.pending?
    end
  end

  test "Hotel#whatsapp_channel returns this hotel's own channel, never another hotel's" do
    with_tenant(hotels(:stari_grad)) do
      assert_equal whatsapp_channels(:stari_grad_whatsapp), hotels(:stari_grad).whatsapp_channel
    end

    with_tenant(hotels(:vrelo)) do
      assert_equal whatsapp_channels(:vrelo_whatsapp), hotels(:vrelo).whatsapp_channel
      assert_not_equal whatsapp_channels(:stari_grad_whatsapp), hotels(:vrelo).whatsapp_channel
    end
  end

  test "a hotel with no channel yet answers nil, not an error" do
    hotel = fresh_hotel

    with_tenant(hotel) do
      assert_nil hotel.whatsapp_channel
    end
  end

  private
    def fresh_hotel
      Hotel.create!(name: "Fixture-free Hotel #{SecureRandom.hex(4)}")
    end
end
