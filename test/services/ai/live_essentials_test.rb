require "test_helper"

module Ai
  # The Essentials product claim, against the real model:
  #
  #   a guest asks for something, is told to call reception, and no ticket exists.
  #
  #   LIVE_AI=1 ANTHROPIC_API_KEY=sk-ant-... bin/rails test test/services/ai/live_essentials_test.rb
  #
  # Everything else about this plan is pinned by mocked tests, which prove the
  # tools are withheld and the dispatch refuses them. What they cannot prove is
  # the half that depends on a model reading prose: that it takes "tell them to
  # call reception" as an instruction rather than escalating, apologising
  # vaguely, or inventing a way to help. That is a prompt-quality question and
  # only a real call answers it.
  #
  # Never in CI — it costs money and it is not deterministic.
  class LiveEssentialsTest < ActiveSupport::TestCase
    setup do
      skip "Set LIVE_AI=1 to run the live API test" unless ENV["LIVE_AI"] == "1"
      skip "ANTHROPIC_API_KEY is not set" if ENV["ANTHROPIC_API_KEY"].blank?

      WebMock.allow_net_connect!
      @hotel = hotels(:stari_grad)
      @hotel.update!(plan: :essentials, contact_phone: "+387 33 000 000")
      ActsAsTenant.current_tenant = @hotel
      @conversation = conversations(:stari_conversation)
      @conversation.reload
    end

    test "a guest asking for towels is sent to reception, and no request exists afterwards" do
      reply = nil

      assert_no_difference [ -> { ServiceRequestDraft.unscoped.count }, -> { ServiceRequest.unscoped.count } ] do
        reply = run_concierge("Could I get two extra towels sent up to my room please?")
      end

      puts "\n  guest: Could I get two extra towels sent up to my room please?"
      puts "  concierge: #{reply}\n"

      assert_match(/33 000 000|reception/i, reply,
        "the assistant should point the guest at reception")
      assert_no_match(/i('ve| have) (sent|passed|arranged|requested|ordered)/i, reply,
        "the assistant must not claim it did something")
    end

    test "it still answers a question from the knowledge base" do
      reply = run_concierge("What time is breakfast?")

      puts "\n  guest: What time is breakfast?"
      puts "  concierge: #{reply}\n"

      # From the fixture: 07:00 to 10:30.
      assert_match(/07[:.]00|7[:.]00|10[:.]30/, reply, "a plain question must still be answered")
    end

    private
      def run_concierge(text)
        @conversation.post_guest_message!(body: text, client_message_id: SecureRandom.uuid)
        outcome = Ai::Concierge.new(conversation: @conversation.reload,
                                    client: Ai::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])).reply
        assert_equal :success, outcome.status, "the concierge did not answer: #{outcome.error_class}"
        outcome.text
      end
  end
end
