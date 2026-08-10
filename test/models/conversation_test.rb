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

  # The leak boundary internal notes introduce, at its source: the
  # [conversation] stream is the guest's own browser, so a note must never
  # be written to it. Asserted as "zero broadcasts on that stream", not
  # "the broadcast didn't contain the text" — the latter would also pass if
  # the note were broadcast with an empty render.
  test "an internal note is never broadcast to the guest's conversation stream" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)

      assert_broadcasts(conversation.to_gid_param, 0) do
        conversation.post_internal_note!(user: users(:stari_staff), body: "Guest already asked twice today.")
      end
    end
  end

  # ...while a guest-visible staff reply on the same conversation still is,
  # so the assertion above cannot be satisfied by broadcasting nothing at
  # all.
  test "a guest-visible staff reply is still broadcast to the guest's conversation stream" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)

      assert_broadcasts(conversation.to_gid_param, 2) do
        conversation.post_staff_message!(user: users(:stari_staff), body: "Housekeeping is on the way.")
      end

      assert_includes ActionCable.server.pubsub.broadcasts(conversation.to_gid_param).last,
        "Housekeeping is on the way."
    end
  end

  test "post_internal_note! writes a staff-authored internal message and leaves the inbox signals alone" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)
      conversation.post_guest_message!(body: "Any chance of a late checkout?", client_message_id: SecureRandom.uuid)
      conversation.reload
      unread_before = conversation.staff_unread_count
      last_message_at_before = conversation.last_message_at

      note = conversation.post_internal_note!(user: users(:stari_staff), body: "Front desk already said yes verbally.")
      conversation.reload

      assert note.internal?
      assert note.staff?
      assert_equal users(:stari_staff), note.sender_user
      # The guest asked something and nobody has answered — jotting a note
      # is not answering, so the badge that says so must survive it.
      assert_equal unread_before, conversation.staff_unread_count
      assert_equal last_message_at_before, conversation.last_message_at
    end
  end

  test "a staff reply to a resolved conversation reopens it rather than vanishing" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)
      conversation.update!(status: :resolved)

      conversation.post_staff_message!(user: users(:stari_staff), body: "One more thing — your taxi is booked.")

      assert conversation.reload.active?, "a reply must reopen the conversation it was written into"
      # The guest's chat only ever renders live_for, so "reopened" has to
      # mean the guest can actually see it — not merely that a status
      # column changed.
      assert_equal conversation, Conversation.live_for(session)
      assert conversation.messages.guest_visible.exists?(body: "One more thing — your taxi is booked.")
    end
  end

  # The reopen above is not always possible: one live conversation per
  # guest session is a database constraint, so a receptionist replying to a
  # settled conversation the guest has already moved on from must be told,
  # not handed a 500 and not left with a reply nobody will ever read.
  test "a staff reply to a superseded conversation is refused, and writes nothing" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    with_tenant(hotel) do
      old_conversation = Conversation.live_for(session)
      old_conversation.update!(status: :resolved)
      new_conversation = Conversation.live_for(session)
      assert_not_equal old_conversation.id, new_conversation.id

      assert_raises(Conversation::SupersededConversation) do
        old_conversation.post_staff_message!(user: users(:stari_staff), body: "reply into a stale transcript")
      end

      assert old_conversation.reload.resolved?
      assert_not Message.where(body: "reply into a stale transcript").exists?,
        "the rolled-back reply must not survive in the settled conversation"
    end
  end

  test "pause_ai! and resume_ai! flip ai_mode and leave an internal trail naming who did it" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)
      assert conversation.auto?, "a new conversation starts on auto — otherwise the flip below proves nothing"

      conversation.pause_ai!(user: users(:stari_staff))
      assert conversation.reload.paused?

      takeover = conversation.messages.last
      assert takeover.system?
      assert takeover.internal?, "the takeover notice explains the staff side's history, not the guest's"
      assert_equal users(:stari_staff), takeover.sender_user
      assert_equal "Reception took over the conversation.", takeover.body

      conversation.resume_ai!(user: users(:stari_admin))
      assert conversation.reload.auto?
      assert_equal "Reception handed the conversation back.", conversation.messages.last.body
    end
  end

  test "mark_read_by_staff! clears the unread count" do
    hotel = hotels(:stari_grad)
    session = with_tenant(hotel) { fresh_guest_session(hotel) }

    with_tenant(hotel) do
      conversation = Conversation.live_for(session)
      conversation.post_guest_message!(body: "Hello?", client_message_id: SecureRandom.uuid)
      assert_equal 1, conversation.reload.staff_unread_count

      conversation.mark_read_by_staff!

      assert_equal 0, conversation.reload.staff_unread_count
    end
  end

  # "Needs attention" has to mean both halves — an unanswered guest message
  # AND an escalation nobody has picked up, even one whose messages have
  # all been read. A scope covering only the first is the easy mistake.
  test "needs_attention covers unread live conversations and escalated ones alike" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      unread = Conversation.live_for(fresh_guest_session(hotel))
      unread.update!(staff_unread_count: 2)

      escalated_but_read = Conversation.live_for(fresh_guest_session(hotel))
      escalated_but_read.update!(status: :escalated, staff_unread_count: 0)

      quiet = Conversation.live_for(fresh_guest_session(hotel))
      quiet.update!(staff_unread_count: 0)

      resolved_with_unread = Conversation.live_for(fresh_guest_session(hotel))
      resolved_with_unread.update!(status: :resolved, staff_unread_count: 3)

      needing = Conversation.needs_attention.pluck(:id)

      assert_includes needing, unread.id
      assert_includes needing, escalated_but_read.id
      assert_not_includes needing, quiet.id
      assert_not_includes needing, resolved_with_unread.id,
        "a settled conversation is not waiting on anyone, whatever its stale unread count says"
    end
  end

  test "inbox_order puts conversations needing attention above newer quiet ones" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      Conversation.where(hotel: hotel).destroy_all

      stale_but_unread = Conversation.live_for(fresh_guest_session(hotel))
      stale_but_unread.update!(staff_unread_count: 1, last_message_at: 3.hours.ago)

      recent_and_quiet = Conversation.live_for(fresh_guest_session(hotel))
      recent_and_quiet.update!(staff_unread_count: 0, last_message_at: 1.minute.ago)

      assert_equal [ stale_but_unread.id, recent_and_quiet.id ], Conversation.inbox_order.pluck(:id)
    end
  end

  test "matching searches guest name and room number, and ignores a blank query" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      Conversation.where(hotel: hotel).destroy_all

      by_name = Conversation.live_for(fresh_guest_session(hotel))
      by_name.guest_session.update!(guest_name: "Ingrid Lindqvist")

      by_room = Conversation.live_for(fresh_guest_session(hotel, room: rooms(:stari_302)))

      assert_equal [ by_name.id ], Conversation.matching("lindqvist").pluck(:id)
      assert_equal [ by_room.id ], Conversation.matching(rooms(:stari_302).number).pluck(:id)
      assert_equal 2, Conversation.matching("   ").count, "a blank query must not filter anything out"
      assert_empty Conversation.matching("nobody-by-that-name").pluck(:id)
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
