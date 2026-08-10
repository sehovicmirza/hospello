require "test_helper"

# The staff-side counterpart of ConversationChannelTest, and it exists for
# the same reason: Staff::ConversationsController is the only production
# code that ever mints a signed inbox stream name, and it only ever mints
# the signed-in user's own hotel's. These tests mint one directly for a
# hotel the connecting user does not work at — the way a leaked, bookmarked
# or screenshotted signed name would let someone try — so what is being
# proven is HotelInboxChannel's ownership check, not Turbo's signature.
class HotelInboxChannelTest < ActionCable::Channel::TestCase
  test "an active staff member subscribes to their own hotel's inbox" do
    signed_name = Turbo::StreamsChannel.signed_stream_name([ hotels(:stari_grad), :inbox ])

    stub_connection(current_user: users(:stari_staff), current_guest_session: nil)
    subscribe(signed_stream_name: signed_name)

    assert subscription.confirmed?
  end

  test "a hotel admin subscribes to their own hotel's inbox too" do
    signed_name = Turbo::StreamsChannel.signed_stream_name([ hotels(:stari_grad), :inbox ])

    stub_connection(current_user: users(:stari_admin), current_guest_session: nil)
    subscribe(signed_stream_name: signed_name)

    assert subscription.confirmed?
  end

  # The core guarantee. A validly-signed name for another hotel's inbox
  # would stream that hotel's entire guest conversation traffic to someone
  # who does not work there.
  test "a forged subscription to another hotel's inbox is rejected" do
    signed_name = Turbo::StreamsChannel.signed_stream_name([ hotels(:vrelo), :inbox ])

    stub_connection(current_user: users(:stari_staff), current_guest_session: nil)
    subscribe(signed_stream_name: signed_name)

    assert subscription.rejected?
  end

  # A cable connection outlives the request that opened it, so the checks
  # Staff::BaseController makes on every request have to be made here too —
  # otherwise revoking someone's access closes the door while leaving the
  # socket they already have wide open.
  test "a deactivated staff member is rejected" do
    users(:stari_staff).update!(active: false)
    signed_name = Turbo::StreamsChannel.signed_stream_name([ hotels(:stari_grad), :inbox ])

    stub_connection(current_user: users(:stari_staff), current_guest_session: nil)
    subscribe(signed_stream_name: signed_name)

    assert subscription.rejected?
  end

  test "a staff member whose hotel has been suspended is rejected" do
    hotels(:stari_grad).suspended!
    signed_name = Turbo::StreamsChannel.signed_stream_name([ hotels(:stari_grad), :inbox ])

    stub_connection(current_user: users(:stari_staff), current_guest_session: nil)
    subscribe(signed_stream_name: signed_name)

    assert subscription.rejected?
  end

  # Guests connect over the same ApplicationCable::Connection (identified
  # by their own cookie), so "a guest cannot subscribe to the staff inbox"
  # is a real request this channel must refuse, not a hypothetical one.
  test "a guest connection is rejected" do
    signed_name = Turbo::StreamsChannel.signed_stream_name([ hotels(:stari_grad), :inbox ])

    stub_connection(current_user: nil, current_guest_session: guest_sessions(:stari_guest))
    subscribe(signed_stream_name: signed_name)

    assert subscription.rejected?
  end

  test "a tampered signed stream name is rejected" do
    signed_name = Turbo::StreamsChannel.signed_stream_name([ hotels(:stari_grad), :inbox ])

    stub_connection(current_user: users(:stari_staff), current_guest_session: nil)
    subscribe(signed_stream_name: "#{signed_name}tampered")

    assert subscription.rejected?
  end

  test "no signed stream name at all is rejected" do
    stub_connection(current_user: users(:stari_staff), current_guest_session: nil)
    subscribe

    assert subscription.rejected?
  end
end
