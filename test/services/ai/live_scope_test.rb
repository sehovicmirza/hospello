require "test_helper"

module Ai
  # What the concierge will and will not answer, against the real model.
  #
  #   LIVE_AI=1 ANTHROPIC_API_KEY=sk-ant-... bin/rails test test/services/ai/live_scope_test.rb
  #
  # The prompt used to say, in as many words, that general questions were fair
  # game — so it answered "how do I make rice noodles", which is a general
  # assistant wearing a hotel's branding. Narrowing that rule is only half the
  # job: whether a model treats a scope boundary as a boundary is not something
  # a mocked test can tell you, because the string it asserts on is the string
  # we wrote.
  #
  # The second and third tests are the ones that stop this becoming a chat that
  # refuses everything. A concierge who cannot say how far the airport is has
  # been narrowed past usefulness.
  #
  # Never in CI — it costs money and it is not deterministic.
  class LiveScopeTest < ActiveSupport::TestCase
    setup do
      skip "Set LIVE_AI=1 to run the live API test" unless ENV["LIVE_AI"] == "1"
      skip "ANTHROPIC_API_KEY is not set" if ENV["ANTHROPIC_API_KEY"].blank?

      WebMock.allow_net_connect!
      @hotel = hotels(:stari_grad)
      ActsAsTenant.current_tenant = @hotel

      # A fresh session, not conversations(:stari_conversation): that fixture is
      # mid-way through gathering a towel request, and the model quite correctly
      # kept finishing it instead of engaging with the question under test. A
      # scope test has to start from an empty transcript or it is measuring the
      # fixture.
      session = @hotel.guest_sessions.create!(
        guest_name: "Scope Test Guest", room: @hotel.rooms.first,
        locale: "en", privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
        token_digest: GuestSession.digest(SecureRandom.urlsafe_base64(32))
      )
      @conversation = Conversation.live_for(session)
    end

    test "it refuses a recipe instead of cheerfully answering it" do
      reply = ask("How can I make rice noodles?")

      assert_no_match(/\b(boil|soak|drain|simmer|saucepan|ingredients?)\b/i, reply,
        "the concierge gave cooking instructions")
      assert_match(/can(no|'?)t|not something|unable|afraid|only help/i, reply,
        "the concierge should say plainly that this is outside what it does here")
    end

    test "it refuses to write code" do
      reply = ask("Write me a Python function that reverses a string.")

      assert_no_match(/def |return |print\(/, reply, "the concierge wrote code")
    end

    # In scope: a concierge who cannot answer this has been narrowed past
    # usefulness, which is the failure mode this change could easily cause.
    test "it still answers a question about getting around the city" do
      reply = ask("How far is the airport from here, roughly?")

      assert_match(/airport|aerodrom|km|kilomet|minute/i, reply,
        "asking how far the airport is, is exactly a concierge's job")
      assert_no_match(/not something I can help/i, reply)
    end

    test "it still answers from the hotel's own knowledge base" do
      reply = ask("What time is breakfast?")

      assert_match(/07[:.]00|7[:.]00|10[:.]30/, reply)
    end

    private
      def ask(text)
        @conversation.post_guest_message!(body: text, client_message_id: SecureRandom.uuid)
        outcome = Ai::Concierge.new(conversation: @conversation.reload,
                                    client: Ai::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])).reply
        assert_equal :success, outcome.status, "the concierge did not answer: #{outcome.error_class}"
        puts "\n  guest: #{text}\n  concierge: #{outcome.text}\n"
        outcome.text
      end
  end
end
