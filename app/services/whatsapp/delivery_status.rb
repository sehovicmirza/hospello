module Whatsapp
  # The normalized shape for a delivery-status callback (sent/delivered/
  # read/failed), independent of which BSP the callback actually came from —
  # the status-callback counterpart of Whatsapp::InboundMessage.
  #
  # provider_message_id matches this back to the Message that carries it in
  # messages.external_id. Out-of-order delivery is normal on WhatsApp — a
  # `read` callback can arrive before its `delivered` one — so `timestamp` is
  # what lets a caller (Slice 6 Task 3) refuse to move a message backwards;
  # arrival order is not trustworthy on its own.
  class DeliveryStatus
    attr_reader :provider_message_id, :status, :timestamp, :error

    def initialize(provider_message_id:, status:, timestamp:, error: nil)
      @provider_message_id = provider_message_id
      @status = status
      @timestamp = timestamp
      @error = error
    end
  end
end
