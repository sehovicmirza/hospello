require "test_helper"

module ApplicationCable
  # ConversationChannel (and, later, Task 3's staff inbox channel) both
  # depend on this resolving the right identifier from whichever cookie is
  # actually present — a guest's hospello_guest cookie, or a staff member's
  # session_token — never both, and never neither.
  class ConnectionTest < ActionCable::Connection::TestCase
    test "a guest's signed cookie identifies the connection by guest_session, not by user" do
      cookies.signed[:hospello_guest] = "stari-grad-fixture-guest-token"

      connect

      assert_equal guest_sessions(:stari_guest), connection.current_guest_session
      assert_nil connection.current_user
    end

    test "a staff member's signed session cookie identifies the connection by user, not by guest_session" do
      staff = users(:stari_staff)
      session = with_tenant(hotels(:stari_grad)) { staff.sessions.create! }
      cookies.signed[:session_token] = session.token

      connect

      assert_equal staff, connection.current_user
      assert_nil connection.current_guest_session
    end

    test "no cookie at all is rejected" do
      assert_reject_connection { connect }
    end

    test "an expired guest session's cookie is rejected, the same as no cookie at all" do
      hotel = hotels(:stari_grad)
      raw_token = SecureRandom.urlsafe_base64(32)
      with_tenant(hotel) do
        hotel.guest_sessions.create!(
          guest_name: "Expired Guest", locale: "en",
          privacy_accepted_at: Time.current, expires_at: 1.hour.ago,
          token_digest: GuestSession.digest(raw_token)
        )
      end
      cookies.signed[:hospello_guest] = raw_token

      assert_reject_connection { connect }
    end

    test "a garbage session_token cookie is rejected rather than raising" do
      cookies.signed[:session_token] = "not-a-real-token"

      assert_reject_connection { connect }
    end
  end
end
