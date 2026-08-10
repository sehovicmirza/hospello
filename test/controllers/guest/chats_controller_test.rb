require "test_helper"

# Exercises Guest::BaseController through its one concrete route in this
# task (Guest::ChatsController#show) — see that controller for the
# session/locale/tenant resolution this pins.
class Guest::ChatsControllerTest < ActionDispatch::IntegrationTest
  test "a valid guest cookie reaches the chat" do
    sign_in_guest("stari-grad-fixture-guest-token")

    get guest_chat_path

    assert_response :success
    assert_select "#chat-greeting"
  end

  # The leak boundary internal notes (Slice 2 Task 3) introduce, checked at
  # the surface a guest actually looks at. The guest-visible reply is
  # asserted alongside it on purpose: without it, this test would still
  # pass if the transcript rendered no staff messages at all.
  test "an internal note never appears in the guest's own transcript" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      conversation = Conversation.live_for(guest_sessions(:stari_guest))
      conversation.post_staff_message!(user: users(:stari_staff), body: "Towels are on their way up.")
      conversation.post_internal_note!(user: users(:stari_staff), body: "Third towel request today, flagged.")
    end

    sign_in_guest("stari-grad-fixture-guest-token")
    get guest_chat_path

    assert_response :success
    assert_select "#chat-messages" do
      assert_select "*", text: /Towels are on their way up\./
      assert_select "*", text: /Third towel request today, flagged\./, count: 0
    end
    assert_no_match "Third towel request today, flagged.", response.body
  end

  test "no cookie at all renders the re-entry page, not the chat" do
    get guest_chat_path

    assert_response :unauthorized
    assert_select "#guest-re-entry"
    assert_select "#chat-greeting", count: 0
  end

  test "an expired session's cookie renders the re-entry page" do
    hotel = hotels(:stari_grad)
    raw_token = SecureRandom.urlsafe_base64(32)

    with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Expired Guest", room: rooms(:stari_301), locale: "en",
        privacy_accepted_at: Time.current, expires_at: 1.hour.ago,
        token_digest: GuestSession.digest(raw_token)
      )
    end
    sign_in_guest(raw_token)

    get guest_chat_path

    assert_response :unauthorized
    assert_select "#guest-re-entry"
  end

  test "a blocked session's cookie renders the re-entry page" do
    hotel = hotels(:stari_grad)
    raw_token = SecureRandom.urlsafe_base64(32)

    with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Blocked Guest", room: rooms(:stari_301), locale: "en",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
        token_digest: GuestSession.digest(raw_token), status: :blocked
      )
    end
    sign_in_guest(raw_token)

    get guest_chat_path

    assert_response :unauthorized
    assert_select "#guest-re-entry"
  end

  # CRITICAL 1 (review round 1): the cookie was valid, unexpired, and
  # unblocked at issue time — the only thing that changed is the hotel's own
  # status, set *after* the guest already had a working cookie in hand.
  # Suspension is the platform's only lever for cutting a hotel off
  # entirely, so every guest request has to re-check it, not just the entry
  # form. Reproduced pre-fix: this returned 200 with the full chat page.
  test "a guest whose hotel is suspended after their cookie was already issued is refused, not shown the chat" do
    sign_in_guest("stari-grad-fixture-guest-token")
    hotels(:stari_grad).update!(status: :suspended)

    get guest_chat_path

    assert_response :success
    assert_select "#hotel-unavailable"
    assert_select "#chat-greeting", count: 0
  end
end
