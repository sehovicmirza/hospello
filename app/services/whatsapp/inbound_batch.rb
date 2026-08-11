module Whatsapp
  # One webhook delivery's worth of activity for **one** WhatsApp number.
  #
  # It exists because Meta's envelope is plural at two levels — `entry[]` and,
  # inside each, `changes[]` — and different entries can carry different
  # `phone_number_id`s, which in this app means *different hotels*. Handing
  # Whatsapp::InboundRouter a flat list of messages would force it either to
  # re-read the routing key per message (BSP wire knowledge, one layer too
  # high) or to assume a delivery only ever concerns one hotel (silently
  # dropping the other one's guest). A batch is the unit that has exactly one
  # answer to "which hotel is this for".
  #
  # Produced only by an adapter's own `.parse_webhook` (see
  # Whatsapp::Provider.parser_for); nothing above that layer ever sees Meta's
  # payload shape.
  class InboundBatch
    attr_reader :phone_number_id, :messages, :statuses

    def initialize(phone_number_id:, messages: [], statuses: [])
      @phone_number_id = phone_number_id
      @messages = messages
      @statuses = statuses
    end

    # Nothing this app acts on. Not an error: Meta routes template approvals,
    # account alerts and quality updates through the same subscription, and
    # they arrive here looking exactly like this.
    def empty? = messages.empty? && statuses.empty?
  end
end
