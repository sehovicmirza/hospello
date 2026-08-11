require "test_helper"

module Whatsapp
  # The other half of the adapter's job: turning one of Meta's own webhook
  # payloads into this app's normalized structs. Kept in its own file rather
  # than added to meta_cloud_provider_test.rb because that file is explicitly
  # about what goes *out* on the wire (and builds a provider instance in
  # setup to do it); parsing is a class method with no instance, no network
  # and no token.
  #
  # Every payload below is written to the shape Meta actually documents at
  # https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples
  # — nesting, key names, string timestamps and all. That literalness is the
  # point: this is the one place in the app that knows the wire format, so a
  # test that parses a convenient made-up hash would prove nothing about the
  # payloads that will really arrive.
  class MetaCloudWebhookParsingTest < ActiveSupport::TestCase
    # --- Inbound text messages ------------------------------------------------

    test "a text message is parsed into one batch carrying the routing id and the message" do
      batches = MetaCloudProvider.parse_webhook(text_payload)

      assert_equal 1, batches.size
      batch = batches.first
      assert_equal "PHONE_NUMBER_ID_A", batch.phone_number_id
      assert_empty batch.statuses

      message = batch.messages.sole
      assert_equal "38761234567", message.wa_id
      assert_equal "text", message.type
      assert_equal "Dobar dan, treba mi peškir", message.text
      assert_equal "wamid.INBOUND1", message.provider_message_id
      assert_equal "PHONE_NUMBER_ID_A", message.phone_number_id
    end

    # Meta sends unix seconds, as a *string*. Left as one, it would silently
    # compare and store as garbage anywhere a Time is expected.
    test "Meta's string unix timestamp is parsed into a real Time" do
      message = MetaCloudProvider.parse_webhook(text_payload).first.messages.sole

      assert_kind_of ActiveSupport::TimeWithZone, message.timestamp
      assert_equal Time.utc(2026, 8, 11, 12, 0, 0), message.timestamp
    end

    # contacts[] is a sibling of messages[], matched to a message by wa_id —
    # not nested inside it. It is the only name this app has for a WhatsApp
    # guest before the concierge asks for a real one.
    test "the contact's WhatsApp profile name is matched to its own message by wa_id" do
      message = MetaCloudProvider.parse_webhook(text_payload).first.messages.sole

      assert_equal "Amira W", message.profile_name
    end

    test "a message with no matching contact entry simply has no profile name" do
      payload = text_payload
      payload["entry"][0]["changes"][0]["value"].delete("contacts")

      assert_nil MetaCloudProvider.parse_webhook(payload).first.messages.sole.profile_name
    end

    # --- Batching -------------------------------------------------------------
    #
    # entry[] and changes[] are both plural in Meta's own schema, and a single
    # delivery really can carry more than one. Parsing only the first would
    # silently drop a guest message — and, because phone_number_id is what
    # routes to a *hotel*, potentially an entire other hotel's guest.

    test "every entry and every change is parsed, not just the first" do
      batches = MetaCloudProvider.parse_webhook(two_hotel_payload)

      assert_equal %w[PHONE_NUMBER_ID_A PHONE_NUMBER_ID_B], batches.map(&:phone_number_id)
      assert_equal [ "wamid.INBOUND1", "wamid.INBOUND2" ],
                   batches.flat_map { |batch| batch.messages.map(&:provider_message_id) }
    end

    test "two messages inside one change both survive" do
      payload = text_payload
      payload["entry"][0]["changes"][0]["value"]["messages"] << {
        "from" => "38761234567", "id" => "wamid.INBOUND1B", "timestamp" => "1786449660",
        "type" => "text", "text" => { "body" => "i još jedan" }
      }

      assert_equal [ "wamid.INBOUND1", "wamid.INBOUND1B" ],
                   MetaCloudProvider.parse_webhook(payload).first.messages.map(&:provider_message_id)
    end

    # --- Delivery statuses ----------------------------------------------------

    test "a delivery status callback is parsed into its own struct" do
      batch = MetaCloudProvider.parse_webhook(status_payload("delivered")).sole

      assert_empty batch.messages
      status = batch.statuses.sole
      assert_equal "wamid.OUTBOUND1", status.provider_message_id
      assert_equal "delivered", status.status
      assert_equal Time.utc(2026, 8, 11, 12, 0, 0), status.timestamp
      assert_nil status.error
    end

    test "a failed status carries Meta's own reason, so a receptionist is told something true" do
      payload = status_payload("failed")
      payload["entry"][0]["changes"][0]["value"]["statuses"][0]["errors"] = [
        { "code" => 131_047, "title" => "Re-engagement message" }
      ]

      assert_equal "131047: Re-engagement message",
                   MetaCloudProvider.parse_webhook(payload).sole.statuses.sole.error
    end

    # --- Payloads with nothing this app can use --------------------------------
    #
    # None of these may raise. Anything that reaches the parser has already
    # been signature-verified and stored; blowing up here would turn a payload
    # shape we simply do not handle into an exception on a guest's message
    # path.

    test "an empty payload parses to nothing at all" do
      assert_empty MetaCloudProvider.parse_webhook({})
      assert_empty MetaCloudProvider.parse_webhook({ "entry" => [] })
    end

    test "a change with no phone_number_id is dropped — there is nothing to route it by" do
      payload = text_payload
      payload["entry"][0]["changes"][0]["value"]["metadata"] = {}

      assert_empty MetaCloudProvider.parse_webhook(payload)
    end

    # Meta sends these for template approvals, account alerts and quality
    # updates. They route by phone_number_id like anything else and simply
    # carry nothing this app acts on — an empty batch, not a crash.
    test "a change carrying neither messages nor statuses is an empty batch" do
      payload = text_payload
      payload["entry"][0]["changes"][0]["field"] = "message_template_status_update"
      payload["entry"][0]["changes"][0]["value"].delete("messages")
      payload["entry"][0]["changes"][0]["value"].delete("contacts")

      batch = MetaCloudProvider.parse_webhook(payload).sole
      assert batch.empty?
    end

    test "a message with no id is dropped rather than parsed into something undedupable" do
      payload = text_payload
      payload["entry"][0]["changes"][0]["value"]["messages"][0].delete("id")

      assert_empty MetaCloudProvider.parse_webhook(payload).sole.messages
    end

    # A non-text inbound message (an image, a location, a voice note) is out of
    # scope for this slice — but it is parsed, not dropped, so the router can
    # tell "the guest sent something I cannot read" apart from "nothing
    # arrived". Only the router decides what to do about it.
    test "a non-text message is parsed with its type and no text" do
      payload = text_payload
      payload["entry"][0]["changes"][0]["value"]["messages"][0] = {
        "from" => "38761234567", "id" => "wamid.IMAGE1", "timestamp" => "1786449600",
        "type" => "image", "image" => { "id" => "MEDIA_ID", "mime_type" => "image/jpeg" }
      }

      message = MetaCloudProvider.parse_webhook(payload).sole.messages.sole
      assert_equal "image", message.type
      assert_nil message.text
    end

    # --- The port ------------------------------------------------------------

    test "the parser is chosen by the provider that delivered the webhook, not by a channel" do
      assert_equal MetaCloudProvider, Provider.parser_for("meta_cloud")
    end

    # Same reasoning as Provider.for: an unimplemented BSP raises a clear
    # error rather than silently parsing another BSP's payload shape, which
    # would route a guest into whatever hotel the wrong key happened to name.
    test "a BSP with no adapter raises rather than guessing a payload shape" do
      error = assert_raises(ArgumentError) { Provider.parser_for("twilio") }

      assert_match "twilio", error.message
    end

    private
      def text_payload
        {
          "object" => "whatsapp_business_account",
          "entry" => [ {
            "id" => "WABA_ID",
            "changes" => [ {
              "field" => "messages",
              "value" => {
                "messaging_product" => "whatsapp",
                "metadata" => {
                  "display_phone_number" => "38761100100", "phone_number_id" => "PHONE_NUMBER_ID_A"
                },
                "contacts" => [ { "profile" => { "name" => "Amira W" }, "wa_id" => "38761234567" } ],
                "messages" => [ {
                  "from" => "38761234567",
                  "id" => "wamid.INBOUND1",
                  "timestamp" => "1786449600",
                  "type" => "text",
                  "text" => { "body" => "Dobar dan, treba mi peškir" }
                } ]
              }
            } ]
          } ]
        }
      end

      def two_hotel_payload
        second = text_payload["entry"][0].deep_dup
        second["changes"][0]["value"]["metadata"]["phone_number_id"] = "PHONE_NUMBER_ID_B"
        second["changes"][0]["value"]["messages"][0]["id"] = "wamid.INBOUND2"

        { "object" => "whatsapp_business_account", "entry" => [ text_payload["entry"][0], second ] }
      end

      def status_payload(status)
        {
          "object" => "whatsapp_business_account",
          "entry" => [ {
            "id" => "WABA_ID",
            "changes" => [ {
              "field" => "messages",
              "value" => {
                "messaging_product" => "whatsapp",
                "metadata" => {
                  "display_phone_number" => "38761100100", "phone_number_id" => "PHONE_NUMBER_ID_A"
                },
                "statuses" => [ {
                  "id" => "wamid.OUTBOUND1",
                  "status" => status,
                  "timestamp" => "1786449600",
                  "recipient_id" => "38761234567"
                } ]
              }
            } ]
          } ]
        }
      end
  end
end
