require "test_helper"

# Guest::ChatsController#show is the only production code that ever mints a
# signed stream name (via turbo_stream_from(@conversation, channel:
# ConversationChannel) — see app/views/guest/chats/show.html.erb), and it
# only ever does so for Current.guest_session's own conversation. These
# tests instead mint one directly for a conversation the connecting guest
# does NOT own, the same way a leaked/bookmarked/screenshotted
# signed-stream-name would let an attacker try — proving the ownership
# check in #subscription_allowed?, not just Turbo's own signature check.
class ConversationChannelTest < ActionCable::Channel::TestCase
  test "a guest subscribes to their own live conversation" do
    hotel = hotels(:stari_grad)
    session = guest_sessions(:stari_guest)
    conversation = with_tenant(hotel) { Conversation.live_for(session) }
    signed_name = Turbo::StreamsChannel.signed_stream_name(conversation)

    stub_connection(current_user: nil, current_guest_session: session)
    subscribe(signed_stream_name: signed_name)

    assert subscription.confirmed?
    assert_has_stream conversation.to_gid_param
  end

  # The core guarantee: a validly-signed stream name for a conversation
  # that belongs to a *different hotel entirely* is refused. Signing alone
  # (Turbo's own protection) only proves the name wasn't tampered with — it
  # says nothing about who is allowed to hold it.
  test "a forged subscription to another hotel's conversation is rejected" do
    other_hotel_conversation = with_tenant(hotels(:vrelo)) { Conversation.live_for(guest_sessions(:vrelo_guest)) }
    signed_name = Turbo::StreamsChannel.signed_stream_name(other_hotel_conversation)

    stub_connection(current_user: nil, current_guest_session: guest_sessions(:stari_guest))
    subscribe(signed_stream_name: signed_name)

    assert subscription.rejected?
  end

  # Same guarantee, the narrower case: a *different guest at the same
  # hotel* must not be able to subscribe to another guest's conversation
  # either — tenant isolation alone (the test above) would not catch this.
  test "a forged subscription to a different guest's conversation at the SAME hotel is rejected" do
    hotel = hotels(:stari_grad)
    session = guest_sessions(:stari_guest)
    other_session = with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Other Guest", locale: "en", privacy_accepted_at: Time.current,
        expires_at: 7.days.from_now, token_digest: GuestSession.digest(SecureRandom.hex(16))
      )
    end
    other_conversation = with_tenant(hotel) { Conversation.live_for(other_session) }
    signed_name = Turbo::StreamsChannel.signed_stream_name(other_conversation)

    stub_connection(current_user: nil, current_guest_session: session)
    subscribe(signed_stream_name: signed_name)

    assert subscription.rejected?
  end

  test "a tampered signed stream name is rejected" do
    hotel = hotels(:stari_grad)
    session = guest_sessions(:stari_guest)
    conversation = with_tenant(hotel) { Conversation.live_for(session) }
    real_signed_name = Turbo::StreamsChannel.signed_stream_name(conversation)

    stub_connection(current_user: nil, current_guest_session: session)
    subscribe(signed_stream_name: "#{real_signed_name}-tampered")

    assert subscription.rejected?
  end

  test "a connection with no guest_session at all is rejected regardless of the stream name's validity" do
    hotel = hotels(:stari_grad)
    conversation = with_tenant(hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }
    signed_name = Turbo::StreamsChannel.signed_stream_name(conversation)

    stub_connection(current_user: nil, current_guest_session: nil)
    subscribe(signed_stream_name: signed_name)

    assert subscription.rejected?
  end
end
