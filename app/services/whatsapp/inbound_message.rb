module Whatsapp
  # The one normalized shape every adapter's inbound-webhook parsing (Slice
  # 6 Task 3) produces, whatever a specific BSP's payload actually looks
  # like on the wire — so Whatsapp::InboundRouter and everything downstream
  # of it reads one vocabulary regardless of which BSP delivered the
  # message. Mirrors Ai::Result's role around Anthropic's response shape:
  # nothing above this layer should ever need to know the wire format.
  #
  # phone_number_id — Meta's routing id the message arrived on (see
  #   WhatsappChannel) — is how the router finds the tenant.
  # wa_id — the guest's own WhatsApp id (their phone number). The identity
  #   key GuestSession.find_or_create_by keys on (Slice 6 Task 3).
  # type — "text" today; Meta's other inbound types (image, location, ...)
  #   are out of scope for this slice.
  # text — the message body; blank for a type this slice does not handle.
  # timestamp — when Meta says the guest sent it.
  # provider_message_id — Meta's own id for this specific message, the
  #   dedupe anchor (messages.external_id).
  class InboundMessage
    attr_reader :phone_number_id, :wa_id, :type, :text, :timestamp, :provider_message_id

    def initialize(phone_number_id:, wa_id:, type:, timestamp:, provider_message_id:, text: nil)
      @phone_number_id = phone_number_id
      @wa_id = wa_id
      @type = type
      @text = text
      @timestamp = timestamp
      @provider_message_id = provider_message_id
    end
  end
end
