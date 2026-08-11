require "test_helper"

module Whatsapp
  # Slice 6's acceptance scenario, from a real webhook payload all the way to
  # a service request, with FakeClaude standing in for the model: a stranger
  # messages the hotel's WhatsApp number, is asked for their room and name
  # before anything else, answers, and only then gets an answer from the
  # hotel's own knowledge base and a request that reception can actually
  # deliver.
  #
  # The point being proved is not that any one class works — each has its own
  # unit tests — but that **nothing downstream had to change**. Every turn
  # after the first runs through exactly the job, prompt, tools and models a
  # web guest's message does. The only WhatsApp-shaped thing in this file is
  # the payload at the top of it.
  class InboundFlowTest < ActiveJob::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      @channel = with_tenant(@hotel) { whatsapp_channels(:stari_grad_whatsapp) }
      @fake = FakeClaude.new
      ActsAsTenant.current_tenant = nil
    end

    test "a stranger on WhatsApp becomes a guest in room 301 with a request on the board" do
      # --- Turn 1: a number nobody has seen before ---------------------------
      deliver("Dobar dan, trebaju mi dva peškira")

      session = with_tenant(@hotel) { GuestSession.find_by!(phone_e164: "+38761234567") }
      assert_nil session.room_id, "nobody has said which room yet"
      conversation = with_tenant(@hotel) { Conversation.live_for(session) }
      assert conversation.whatsapp?

      # The concierge is told, in the prompt, that it must ask first — and it
      # is told before it can answer anything from the knowledge base.
      @fake.script_text("Naravno! Recite mi broj sobe i vaše ime, molim.")
      reply(conversation)

      assert_includes @fake.prompt_text, "<room_unknown>"
      assert_includes @fake.prompt_text, "set_guest_room"

      # A request cannot be started yet even if the model tries — the prompt
      # is the persuadable half; this is the half that is not.
      refused = with_tenant(@hotel) do
        Ai::Tools.new(conversation: conversation).execute(
          Ai::Result::ToolCall.new(id: "t1", name: "propose_service_request",
                                   input: { "category_key" => request_categories(:stari_towels).key })
        )
      end
      assert refused[:is_error]
      assert_equal 0, with_tenant(@hotel) { conversation.service_request_drafts.count }

      # --- Turn 2: the guest answers ----------------------------------------
      deliver("Soba 301, Amira Hodžić", provider_message_id: "wamid.TURN2")

      @fake
        .script_tool_call("set_guest_room",
                          { "room_number" => "301", "guest_name" => "Amira Hodžić", "language" => "bs" })
        .script_text("Hvala! Kako vam mogu pomoći?")
      reply(conversation)

      with_tenant(@hotel) do
        session.reload
        assert_equal rooms(:stari_301), session.room
        assert_equal "Amira Hodžić", session.guest_name
        assert session.unverified?, "a WhatsApp guest is exactly as unverified as a web one"
        assert_equal rooms(:stari_301), conversation.reload.room
      end

      # --- Turn 3: now the hotel's own knowledge is in play ------------------
      deliver("Kada je doručak?", provider_message_id: "wamid.TURN3")

      @fake.script_text("Doručak je od 07:00 do 10:30.\n[kb: #{breakfast_entry.id}]")
      reply(conversation)

      assert_not_includes @fake.prompt_text, "<room_unknown>", "the guest has answered; stop asking"
      assert_includes @fake.prompt_text, "Room: 301"
      assert_includes @fake.prompt_text, "Doručak se služi u restoranu"

      # --- Turn 4: a request, gathered and confirmed the ordinary way --------
      deliver("Molim dva peškira za kupanje", provider_message_id: "wamid.TURN4")

      @fake
        .script_tool_call("propose_service_request", {
          "category_key" => request_categories(:stari_towels).key,
          "details" => { "quantity" => "2", "description" => "peškiri za kupanje" }
        })
        .script_text("Dva peškira za kupanje, soba 301 — da pošaljem recepciji?")
      reply(conversation)

      draft = with_tenant(@hotel) { ServiceRequestDraft.live_for(conversation) }
      assert draft.status_awaiting_confirmation?
      assert_equal 0, with_tenant(@hotel) { ServiceRequest.count }, "a summary is not a request"

      deliver("da, molim", provider_message_id: "wamid.TURN5")
      @fake
        .script_tool_call("confirm_service_request", { "draft_id" => draft.id })
        .script_text("Poslano recepciji.")
      reply(conversation)

      with_tenant(@hotel) do
        request = ServiceRequest.sole
        assert_equal rooms(:stari_301), request.room, "the room the guest told us, and nothing else"
        assert_equal "whatsapp", request.conversation.channel
        assert request.status_new?, "the hotel has not agreed to anything yet — a person still has to"
      end
    end

    # The other side of the same seam, and the reason a receptionist can work
    # this conversation at all: the whole thing is in the ordinary inbox, on
    # the ordinary transcript, with nothing WhatsApp-specific about it beyond
    # a badge.
    test "the whole exchange is an ordinary conversation in the reception inbox" do
      deliver("Dobar dan")
      conversation = with_tenant(@hotel) { Conversation.where(channel: :whatsapp).sole }

      with_tenant(@hotel) do
        assert_includes Conversation.needs_attention, conversation
        assert_equal 1, conversation.staff_unread_count
        assert_equal "Dobar dan", conversation.messages.guest_visible.sole.body
        assert conversation.messages.sole.guest?
      end
    end

    private
      def breakfast_entry
        with_tenant(@hotel) { @hotel.published_kb_entries.find { |entry| entry.content.include?("Doručak") } }
      end

      # One real webhook delivery, through the real controller-shaped path:
      # store the event, then run the job that routes it. Deliberately not a
      # direct InboundRouter call — this is the sequence
      # Webhooks::WhatsappController actually produces.
      def deliver(text, provider_message_id: "wamid.TURN1")
        event = WebhookEvent.create!(
          provider: :meta_cloud, external_id: provider_message_id,
          payload: {
            "object" => "whatsapp_business_account",
            "entry" => [ { "id" => "WABA_ID", "changes" => [ { "field" => "messages", "value" => {
              "messaging_product" => "whatsapp",
              "metadata" => { "phone_number_id" => @channel.phone_number_id },
              "contacts" => [ { "profile" => { "name" => "Amira W" }, "wa_id" => "38761234567" } ],
              "messages" => [ {
                "from" => "38761234567", "id" => provider_message_id, "timestamp" => "1786449600",
                "type" => "text", "text" => { "body" => text }
              } ]
            } } ] } ]
          }
        )
        perform_enqueued_jobs(only: ProcessInboundJob) { ProcessInboundJob.perform_later(event.id) }
        assert event.reload.processed?, "the delivery did not route: #{event.status} #{event.error}"
      end

      # The concierge turn the inbound message enqueued, run with FakeClaude
      # rather than left in the queue — the same job, with the same arguments,
      # a web guest's message enqueues.
      def reply(conversation)
        with_tenant(@hotel) { Ai::GenerateReplyJob.perform_now(conversation, client: @fake) }
        conversation.reload
      end
  end
end
