require "test_helper"

class MessageTest < ActiveSupport::TestCase
  test "a blank body is rejected" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      message = messages(:stari_first_message).conversation.messages.build(
        hotel: hotel, sender_role: :guest, body: "   "
      )

      assert_not message.valid?
      assert_includes message.errors[:body], "can't be blank"
    end
  end

  test "a body over 1000 characters is rejected with a friendly message" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      message = messages(:stari_first_message).conversation.messages.build(
        hotel: hotel, sender_role: :guest, body: "a" * 1001
      )

      assert_not message.valid?
      assert_includes message.errors[:body], "is too long (maximum is 1000 characters)"
    end
  end

  test "a body of exactly 1000 characters is accepted" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      message = messages(:stari_first_message).conversation.messages.build(
        hotel: hotel, sender_role: :guest, body: "a" * 1000
      )

      assert message.valid?
    end
  end

  test "body cannot be changed after creation, by update or update! alike" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      message = messages(:stari_first_message)

      assert_not message.update(body: "a different message entirely")
      assert_equal "Do you have extra towels?", message.reload.body

      assert_raises(ActiveRecord::RecordInvalid) { message.update!(body: "still tampering") }
      assert_equal "Do you have extra towels?", message.reload.body
    end
  end

  test "translated_body may still be written after creation — only body is frozen" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      message = messages(:stari_first_message)

      assert message.update(translated_body: "Haben Sie zusätzliche Handtücher?", translated_locale: "de")
      assert_equal "Haben Sie zusätzliche Handtücher?", message.reload.translated_body
    end
  end

  test "a message always takes its hotel_id from its conversation" do
    hotel = hotels(:stari_grad)

    with_tenant(hotel) do
      conversation = conversations(:stari_conversation)
      message = conversation.messages.create!(sender_role: :system, body: "A system notice.")

      assert_equal conversation.hotel_id, message.hotel_id
    end
  end

  # .valid? (and so every before_validation callback / custom validation)
  # has to run *inside* the with_tenant block — calling it after the block
  # exits runs with no ambient tenant at all and raises
  # ActsAsTenant::Errors::NoTenantSet from a completely different line than
  # the one this test means to exercise.
  test "a message cannot be saved against a conversation belonging to a different hotel" do
    stari = hotels(:stari_grad)
    vrelo_conversation = conversations(:vrelo_conversation)

    with_tenant(stari) do
      message = Message.new(hotel: stari, conversation: vrelo_conversation, sender_role: :guest, body: "cross-tenant attempt")

      assert_not message.valid?
      assert_includes message.errors[:conversation], "must belong to the same hotel"
    end
  end

  test "a staff sender_user must belong to the same hotel as the message" do
    stari = hotels(:stari_grad)
    vrelo_staff = users(:vrelo_staff)

    with_tenant(stari) do
      message = conversations(:stari_conversation).messages.build(
        hotel: stari, sender_role: :staff, sender_user: vrelo_staff, body: "cross-tenant staff reply"
      )

      assert_not message.valid?
      assert_includes message.errors[:sender_user], "must belong to the same hotel"
    end
  end

  # Internal notes (Slice 2 Task 3) share this table with guest-visible
  # replies, so "which rows may a guest ever see" stops being obvious and
  # becomes something that has to be pinned. The default is asserted
  # against a message built with no visibility mentioned at all: if the
  # column's default ever flipped to internal, every ordinary guest reply
  # would silently vanish from the guest's own transcript.
  test "a message is guest-visible unless it is deliberately made internal" do
    with_tenant(hotels(:stari_grad)) do
      message = conversations(:stari_conversation).messages.create!(sender_role: :guest, body: "Ordinary message")

      assert message.guest_visible?, "a message with no visibility given must be guest-visible"
      assert_not message.internal?
    end
  end

  # .guest_visible is the scope every guest-facing read goes through
  # (Guest::ChatsController#show, Guest::MessagesController#index,
  # Conversation#broadcast_new_message). Asserting it *excludes* the
  # internal note matters more than that it includes the visible one — the
  # include half would pass against a scope that filtered nothing at all.
  test "the guest_visible scope excludes internal notes" do
    with_tenant(hotels(:stari_grad)) do
      conversation = conversations(:stari_conversation)
      visible = conversation.messages.create!(sender_role: :staff, sender_user: users(:stari_staff), body: "On its way up.")
      note = conversation.messages.create!(
        sender_role: :staff, sender_user: users(:stari_staff), body: "Guest already complained twice.", visibility: :internal
      )

      guest_visible_ids = conversation.messages.guest_visible.pluck(:id)

      assert_includes guest_visible_ids, visible.id
      assert_not_includes guest_visible_ids, note.id
    end
  end

  # Only the two staff-authored roles may be internal. A guest's own
  # message arriving marked internal would mean a request parameter had
  # reached the visibility attribute — the guest would then be typing into
  # a transcript they cannot read back, which is a far more confusing
  # failure than a rejected write. An assistant reply (Slice 3) is by
  # definition an answer to the guest, so it is refused for the same
  # reason.
  test "a guest or assistant message may never be internal" do
    with_tenant(hotels(:stari_grad)) do
      %i[guest assistant].each do |role|
        message = conversations(:stari_conversation).messages.build(
          sender_role: role, body: "not a note", visibility: :internal
        )

        assert_not message.valid?, "a #{role} message was accepted as internal"
        assert_includes message.errors[:visibility], "is only available on staff messages and system notices"
      end
    end
  end

  # The same guarantee from the other side, so the validation above cannot
  # be satisfied by a blanket "internal is never allowed" — staff notes and
  # the staff-side system notices Conversation#pause_ai!/#resume_ai! write
  # both depend on internal being reachable.
  test "a staff message and a system notice may both be internal" do
    with_tenant(hotels(:stari_grad)) do
      note = conversations(:stari_conversation).messages.build(
        sender_role: :staff, sender_user: users(:stari_staff), body: "Room was serviced an hour ago.", visibility: :internal
      )
      notice = conversations(:stari_conversation).messages.build(
        sender_role: :system, body: "Reception took over the conversation.", visibility: :internal
      )

      assert note.valid?, note.errors.full_messages.to_sentence
      assert notice.valid?, notice.errors.full_messages.to_sentence
    end
  end

  # Visibility is decided when the note is written and never afterwards.
  # An internal note that could be flipped guest-visible by a later update
  # is a leak with a delay on it — and the reverse (retracting something
  # the guest has already read) would rewrite history the guest already
  # saw. Same reasoning as body's own immutability above.
  test "visibility cannot be changed after creation" do
    with_tenant(hotels(:stari_grad)) do
      note = conversations(:stari_conversation).messages.create!(
        sender_role: :staff, sender_user: users(:stari_staff), body: "Internal only.", visibility: :internal
      )

      assert_not note.update(visibility: :guest_visible)
      assert_includes note.errors[:visibility], "cannot be changed after creation"
      assert note.reload.internal?
    end
  end
end
