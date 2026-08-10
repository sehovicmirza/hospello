require "test_helper"

# A cable connection outlives the request that opened it, so everything the
# board's controller checks per request has to be re-checked here once, at
# subscribe. Turbo's signature proves a stream name was not tampered with —
# not that this connection is allowed to hold it.
class HotelRequestsChannelTest < ActionCable::Channel::TestCase
  tests HotelRequestsChannel

  test "an active staff member may subscribe to their own hotel's board" do
    stub_connection current_user: users(:stari_staff)

    subscribe signed_stream_name: signed_name_for(hotels(:stari_grad))

    assert subscription.confirmed?
  end

  # The one that matters: a validly-signed name from the wrong hotel.
  test "a staff member cannot subscribe to another hotel's board" do
    stub_connection current_user: users(:stari_staff)

    subscribe signed_stream_name: signed_name_for(hotels(:vrelo))

    assert subscription.rejected?
  end

  test "a deactivated staff member is refused" do
    users(:stari_staff).update!(active: false)
    stub_connection current_user: users(:stari_staff)

    subscribe signed_stream_name: signed_name_for(hotels(:stari_grad))

    assert subscription.rejected?
  end

  test "a suspended hotel's staff are refused" do
    hotels(:stari_grad).update!(status: :suspended)
    stub_connection current_user: users(:stari_staff)

    subscribe signed_stream_name: signed_name_for(hotels(:stari_grad))

    assert subscription.rejected?
  end

  test "a platform admin has no hotel board to watch" do
    stub_connection current_user: users(:platform)

    subscribe signed_stream_name: signed_name_for(hotels(:stari_grad))

    assert subscription.rejected?
  end

  test "an unauthenticated connection is refused" do
    stub_connection current_user: nil

    subscribe signed_stream_name: signed_name_for(hotels(:stari_grad))

    assert subscription.rejected?
  end

  test "a name that was not signed by this app is refused" do
    stub_connection current_user: users(:stari_staff)

    subscribe signed_stream_name: "not-a-signed-name"

    assert subscription.rejected?
  end

  # The inbox and the board are different streams: holding one must not admit
  # you to the other, or a receptionist's page would morph on the wrong event.
  test "the inbox's stream name does not open the board" do
    stub_connection current_user: users(:stari_staff)

    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name([ hotels(:stari_grad), :inbox ])

    assert subscription.rejected?
  end

  private
    def signed_name_for(hotel)
      Turbo::StreamsChannel.signed_stream_name([ hotel, :requests ])
    end
end
