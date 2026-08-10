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
end
