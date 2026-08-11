module Whatsapp
  # The port every BSP adapter implements, so the choice of BSP (the plan's
  # open blocking question — Meta direct, 360dialog, or Twilio) is a
  # config/adapter swap later, never a rewrite of anything that calls this.
  # Mirrors the seam Ai::Client keeps around Anthropic: nothing above this
  # layer may know which BSP a hotel actually uses, build a WhatsApp HTTP
  # request itself, or parse one of its responses.
  #
  # #send_text is a free-form reply, valid only inside Meta's 24-hour
  # customer service window (see Whatsapp::WindowClosedError — every
  # implementation must enforce this itself, in the provider, not leave it
  # to the caller). #send_template is the one way out of that window: a
  # message Meta has already pre-approved, and it is never subject to the
  # guard.
  class Provider
    # channel.provider picks the adapter; everything BSP-specific — auth,
    # request shape, error mapping — is that adapter's business from here
    # on, never the caller's.
    def self.for(channel)
      case channel.provider
      when "meta_cloud"
        MetaCloudProvider.new
      else
        raise ArgumentError, "no Whatsapp::Provider adapter is implemented for #{channel.provider.inspect} yet"
      end
    end

    # @param channel [WhatsappChannel] whose phone_number_id sends.
    # @param to [String] the recipient's phone number, E.164.
    # @param body [String] the free-form message text.
    # @param conversation [#last_guest_message_at] anything that can answer
    #   how long ago the guest last messaged in — in production always a
    #   real Conversation, and deliberately just a duck type: this seam
    #   should never need to load one to prove the 24-hour guard (see the
    #   boundary tests in test/services/whatsapp/meta_cloud_provider_test.rb).
    # @return [String] the provider's own message id.
    # @raise [Whatsapp::WindowClosedError, Whatsapp::AuthenticationError,
    #   Whatsapp::RateLimitedError, Whatsapp::ApiError]
    def send_text(channel:, to:, body:, conversation:)
      raise NotImplementedError, "#{self.class} must implement #send_text"
    end

    # @param components [Array<Hash>] Meta's own template-component shape
    #   (header/body/button parameters) — passed through verbatim, never
    #   interpreted here.
    # @return [String] the provider's own message id.
    # @raise [Whatsapp::AuthenticationError, Whatsapp::RateLimitedError,
    #   Whatsapp::ApiError] — never Whatsapp::WindowClosedError; a
    #   pre-approved template is exactly what Meta's rule allows outside the
    #   24-hour window.
    def send_template(channel:, to:, name:, locale:, components: [])
      raise NotImplementedError, "#{self.class} must implement #send_template"
    end
  end
end
