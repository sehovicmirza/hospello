require "test_helper"

# Deliberately does NOT reuse guest_sessions(:stari_guest)/(:vrelo_guest) for
# most of these — those fixtures already own a live conversation fixture
# (conversations(:stari_conversation)/(:vrelo_conversation), used by
# controller/view tests that want "a conversation with history already in
# it"), which would pre-occupy the one-live-conversation-per-guest slot
# these tests are specifically about, and pre-seed staff_unread_count /
# last_guest_message_at away from the blank-slate values several
# assertions below need. #fresh_guest_session builds an otherwise-identical
# throwaway session with no conversation yet.
class ConversationTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  test "live_for returns the same conversation twice in a row" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    with_tenant(hotel) do
      first = Conversation.live_for(session)
      second = Conversation.live_for(session)

      assert_equal first.id, second.id
      assert_equal 1, Conversation.where(guest_session: session).count
    end
  end

  test "live_for creates a new conversation after the previous one is resolved" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    with_tenant(hotel) do
      first = Conversation.live_for(session)
      first.update!(status: :resolved)

      second = Conversation.live_for(session)

      assert_not_equal first.id, second.id
      assert second.active?
      assert_equal 2, Conversation.where(guest_session: session).count
    end
  end

  # Simulates two requests racing to create "the" live conversation (a
  # guest double-tapping send on a slow connection): the partial unique
  # index on guest_session_id (status active/escalated,
  # db/migrate/*_create_conversations.rb) guarantees only one of two
  # concurrent inserts can ever succeed — this proves live_for's rescue
  # re-finds the winner instead of letting ActiveRecord::RecordNotUnique
  # propagate as a 500. #existing_live_conversation is monkey-patched
  # (Minitest 6 dropped Object#stub/Minitest::Mock into a separate gem this
  # app doesn't otherwise need — a plain define_singleton_method swap does
  # the same job with no new dependency) to return nil on its first call
  # only, pretending the race's other winner isn't visible yet — so
  # live_for's create attempt runs against a row that genuinely already
  # exists, and the RecordNotUnique this raises is real, not simulated.
  test "two concurrent live_for calls yield one conversation, never raising RecordNotUnique" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    winner = with_tenant(hotel) { Conversation.create!(guest_session: session) }

    call_count = 0
    original_lookup = Conversation.method(:existing_live_conversation)
    Conversation.define_singleton_method(:existing_live_conversation) do |guest_session|
      call_count += 1
      call_count == 1 ? nil : original_lookup.call(guest_session)
    end

    result = with_tenant(hotel) { Conversation.live_for(session) }

    assert_equal winner, result
    assert_equal 2, call_count, "expected the rescue path to re-find via a second lookup"
    assert_equal 1, with_tenant(hotel) { Conversation.where(guest_session: session).count }
  ensure
    Conversation.define_singleton_method(:existing_live_conversation, original_lookup) if original_lookup
  end

  test "post_guest_message! is idempotent on client_message_id" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }
    client_message_id = SecureRandom.uuid

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)

      first = conversation.post_guest_message!(body: "Can I get extra towels?", client_message_id: client_message_id)
      second = conversation.post_guest_message!(body: "Can I get extra towels?", client_message_id: client_message_id)

      assert_equal first.id, second.id
      assert_equal 1, conversation.messages.count
    end
  end

  # The upfront #find_by in post_guest_message! handles a *sequential*
  # retried submit (the common case); this proves the other half — a
  # genuinely concurrent double-tap, where both requests' upfront
  # existence-checks run before either has inserted anything. Monkey-patches
  # Message.find_by (scoped to this conversation's own messages association,
  # restored in the ensure block — same technique and same reason as the
  # live_for race test above) to return nil on its first call only, so
  # post_guest_message!'s create attempt runs against a client_message_id
  # that a "concurrent" call already inserted — the unique index on
  # [conversation_id, client_message_id] (db/migrate/*_create_messages.rb)
  # is what actually turns that into a real ActiveRecord::RecordNotUnique
  # for the rescue to catch.
  test "post_guest_message! stays idempotent even when two requests race past the upfront existence check" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }
    client_message_id = SecureRandom.uuid

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)
      winner = conversation.messages.create!(
        hotel: hotel, sender_role: :guest, body: "the other request's message", client_message_id: client_message_id
      )

      messages_association = conversation.messages
      call_count = 0
      original_find_by = messages_association.method(:find_by)
      messages_association.define_singleton_method(:find_by) do |*args|
        call_count += 1
        call_count == 1 ? nil : original_find_by.call(*args)
      end

      result = conversation.post_guest_message!(body: "a losing race attempt", client_message_id: client_message_id)

      assert_equal winner.id, result.id
      assert_equal "the other request's message", result.body
      assert_equal 1, conversation.messages.where(client_message_id: client_message_id).count
    end
  end

  test "post_guest_message! increments staff_unread_count and post_staff_message! clears it" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }
    staff = users(:stari_admin)

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)
      assert_equal 0, conversation.staff_unread_count

      conversation.post_guest_message!(body: "Hello?", client_message_id: SecureRandom.uuid)
      assert_equal 1, conversation.reload.staff_unread_count

      conversation.post_guest_message!(body: "Anyone there?", client_message_id: SecureRandom.uuid)
      assert_equal 2, conversation.reload.staff_unread_count

      conversation.post_staff_message!(user: staff, body: "Yes, how can I help?")
      assert_equal 0, conversation.reload.staff_unread_count
    end
  end

  test "post_guest_message! touches last_guest_message_at and last_message_at" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)
      assert_nil conversation.last_guest_message_at
      assert_nil conversation.last_message_at

      travel_to Time.zone.parse("2026-01-01 10:00:00") do
        conversation.post_guest_message!(body: "Hi", client_message_id: SecureRandom.uuid)
      end

      conversation.reload
      assert_equal Time.zone.parse("2026-01-01 10:00:00"), conversation.last_guest_message_at
      assert_equal Time.zone.parse("2026-01-01 10:00:00"), conversation.last_message_at
    end
  end

  test "a message's body is never modified by post_guest_message!, post_staff_message!, or a direct update attempt" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }
    staff = users(:stari_admin)

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)
      guest_message = conversation.post_guest_message!(body: "original guest text", client_message_id: SecureRandom.uuid)
      staff_message = conversation.post_staff_message!(user: staff, body: "original staff text")

      assert_equal "original guest text", guest_message.reload.body
      assert_equal "original staff text", staff_message.reload.body

      assert_not guest_message.update(body: "TAMPERED")
      assert_equal "original guest text", guest_message.reload.body
      assert_includes guest_message.errors[:body], "cannot be changed after creation"
    end
  end

  test "post_guest_message! broadcasts the new message to the conversation's own stream" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)
      stream_name = conversation.to_gid_param

      # 2, not 1: a "remove the now-stale empty-state greeting" action
      # alongside the "append the message" action — see
      # Conversation#broadcast_new_message.
      assert_broadcasts(stream_name, 2) do
        conversation.post_guest_message!(body: "Room service, please", client_message_id: SecureRandom.uuid)
      end

      broadcast = ActionCable.server.pubsub.broadcasts(stream_name).last
      assert_includes broadcast, "Room service, please"
    end
  end

  test "a conversation always takes its hotel, room, and guest_locale from its guest_session" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel, room: rooms(:stari_302), locale: "de") }

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)

      assert_equal session.hotel_id, conversation.hotel_id
      assert_equal session.room_id, conversation.room_id
      assert_equal "de", conversation.guest_locale
    end
  end

  test "a conversation cannot be saved against a guest_session belonging to a different hotel" do
    stari = hotels(:stari_grad)
    vrelo_session = guest_sessions(:vrelo_guest)

    with_tenant(stari) do
      conversation = Conversation.new(hotel: stari, guest_session: vrelo_session)

      assert_not conversation.valid?
      assert_includes conversation.errors[:guest_session], "must belong to the same hotel"
    end
  end

  private
    def fresh_guest_session(hotel, room: nil, locale: "en")
      hotel.guest_sessions.create!(
        guest_name: "Fixture-free Guest #{SecureRandom.hex(4)}", room: room, locale: locale,
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
        token_digest: GuestSession.digest(SecureRandom.hex(16))
      )
    end
end
