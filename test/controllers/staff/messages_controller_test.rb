require "test_helper"

# The staff reply composer. Two kinds of message come through one action —
# a reply the guest will read, and an internal note the guest must never
# see — so most of what is worth testing here is which of the two a given
# request produces, including for requests no legitimate form would send.
class Staff::MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @hotel = hotels(:stari_grad)
    @staff = users(:stari_staff)
    @conversation = with_tenant(@hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }
  end

  test "a reply creates a guest-visible staff message attributed to the acting user" do
    sign_in @staff

    assert_difference -> { with_tenant(@hotel) { @conversation.messages.count } }, 1 do
      post staff_conversation_messages_path(@conversation),
        params: { kind: "reply", message: { body: "Housekeeping is on the way up." } }
    end

    assert_redirected_to staff_conversation_path(@conversation)
    message = with_tenant(@hotel) { @conversation.messages.last }
    assert message.staff?
    assert message.guest_visible?
    assert_equal @staff, message.sender_user
    assert_equal "Housekeeping is on the way up.", message.body
  end

  test "a reply clears the unread count" do
    with_tenant(@hotel) { @conversation.update!(staff_unread_count: 3) }
    sign_in @staff

    post staff_conversation_messages_path(@conversation),
      params: { kind: "reply", message: { body: "On it." } }

    assert_equal 0, with_tenant(@hotel) { @conversation.reload.staff_unread_count }
  end

  test "an internal note creates an internal staff message" do
    sign_in @staff

    post staff_conversation_messages_path(@conversation),
      params: { kind: "internal_note", message: { body: "Guest has asked three times today." } }

    assert_redirected_to staff_conversation_path(@conversation)
    note = with_tenant(@hotel) { @conversation.messages.last }
    assert note.internal?
    assert_equal @staff, note.sender_user
  end

  # An internal note is staff bookkeeping, not an answer: it must not clear
  # the badge that says a guest is still waiting, and it must not reorder
  # the inbox as though the guest had just been replied to.
  test "an internal note leaves the unread count and the inbox ordering alone" do
    with_tenant(@hotel) { @conversation.update!(staff_unread_count: 2, last_message_at: 2.hours.ago) }
    last_message_at_before = with_tenant(@hotel) { @conversation.reload.last_message_at }
    sign_in @staff

    post staff_conversation_messages_path(@conversation),
      params: { kind: "internal_note", message: { body: "Checked with housekeeping." } }

    with_tenant(@hotel) do
      @conversation.reload
      assert_equal 2, @conversation.staff_unread_count
      assert_equal last_message_at_before.to_i, @conversation.last_message_at.to_i
    end
  end

  # The fail-safe direction. A stale form, a typo, or a crafted request can
  # only ever make a message MORE visible than intended, never less — an
  # unrecognised `kind` must not silently produce something the guest
  # cannot see, because nobody would ever notice that it had.
  test "an unrecognised kind is treated as a reply, never as an internal note" do
    sign_in @staff

    [ nil, "", "note", "INTERNAL_NOTE", "internal", "reply" ].each do |kind|
      post staff_conversation_messages_path(@conversation),
        params: { kind: kind, message: { body: "kind was #{kind.inspect}" } }

      message = with_tenant(@hotel) { @conversation.messages.last }
      assert message.guest_visible?, "kind #{kind.inspect} produced a message the guest cannot see"
    end
  end

  test "a reply to a resolved conversation reopens it rather than vanishing" do
    with_tenant(@hotel) { @conversation.update!(status: :resolved) }
    sign_in @staff

    post staff_conversation_messages_path(@conversation),
      params: { kind: "reply", message: { body: "One last thing — your taxi is booked." } }

    assert_redirected_to staff_conversation_path(@conversation)
    with_tenant(@hotel) do
      assert @conversation.reload.active?
      assert_equal @conversation, Conversation.live_for(guest_sessions(:stari_guest))
    end
  end

  # The case reopening cannot serve: the guest has already started a newer
  # conversation, so the one-live-conversation index refuses the reopen.
  # The receptionist has to be told and pointed at the live conversation —
  # a 500, or a reply silently parked in a transcript nobody will open, are
  # both worse than saying so.
  test "a reply to a superseded conversation is refused and points at the live one" do
    newer = with_tenant(@hotel) do
      @conversation.update!(status: :resolved)
      Conversation.live_for(guest_sessions(:stari_guest))
    end
    sign_in @staff

    assert_no_difference -> { with_tenant(@hotel) { Message.count } } do
      post staff_conversation_messages_path(@conversation),
        params: { kind: "reply", message: { body: "reply into a stale transcript" } }
    end

    assert_redirected_to staff_conversation_path(newer)
    # @staff (stari_staff) reads the staff workspace in Bosnian — see
    # fixtures. staff.messages.create.superseded, config/locales/staff.bs.yml.
    assert_match "gost je u međuvremenu započeo novi", flash[:alert]
  end

  test "an over-long reply is refused with a readable message and creates nothing" do
    sign_in @staff

    assert_no_difference -> { with_tenant(@hotel) { Message.count } } do
      post staff_conversation_messages_path(@conversation),
        params: { kind: "reply", message: { body: "a" * (Message::MAX_BODY_LENGTH + 1) } }
    end

    assert_redirected_to staff_conversation_path(@conversation)
    assert_match "too long", flash[:alert]
  end

  test "an empty reply is refused and creates nothing" do
    sign_in @staff

    assert_no_difference -> { with_tenant(@hotel) { Message.count } } do
      post staff_conversation_messages_path(@conversation),
        params: { kind: "reply", message: { body: "   " } }
    end

    assert_redirected_to staff_conversation_path(@conversation)
  end

  test "a deactivated staff member cannot post at all" do
    @staff.update!(active: false)
    sign_in @staff

    assert_no_difference -> { with_tenant(@hotel) { Message.count } } do
      post staff_conversation_messages_path(@conversation),
        params: { kind: "reply", message: { body: "should never land" } }
    end

    assert_response :forbidden
  end
end
