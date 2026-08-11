module Staff
  # The hotel's own WhatsApp number, and the screen that made it possible to
  # set one up without a Rails console.
  #
  # Until this existed a `WhatsappChannel` row could only be created by hand
  # on the production box — which is exactly the "hidden manual step" this
  # project's own rules forbid, and it would have made onboarding a hotel an
  # engineering task rather than a hotel-admin one.
  #
  # A singular resource with no id anywhere in its path, the same shape
  # Staff::HotelSettingsController and Staff::PreferencesController use for
  # "always the current hotel's, never one a form could name": there is no
  # request shape here that could reach another hotel's channel.
  class WhatsappChannelsController < BaseController
    before_action :set_channel

    # Authorized as a *read*, deliberately, even though the route is #edit:
    # a receptionist has to be able to answer "I messaged you on WhatsApp and
    # nobody replied" at 23:00 — is the number live, did anything ever arrive
    # — and that is a shift question, not a configuration one. The form
    # itself is gated separately in the view on `policy(@channel).update?`,
    # so what they get is the state panel and no fields, rather than an
    # editable form that refuses them on submit.
    def edit
      authorize @channel, :show?
    end

    def update
      # A new channel is created on first save rather than by a separate
      # #new/#create pair: there is exactly one per hotel and the form is
      # the same either way, so two actions would be two places to keep the
      # same permitted-parameter list.
      authorize @channel, :update?

      if @channel.update(channel_params)
        redirect_to edit_staff_whatsapp_channel_path, notice: t(".updated")
      else
        render :edit, status: :unprocessable_content
      end
    end

    private
      # Always Current.hotel's — never an id from params, of which this route
      # has none at all.
      def set_channel
        @channel = Current.hotel.whatsapp_channel || Current.hotel.build_whatsapp_channel
      end

      # Deliberately excludes `verified_at`, `last_inbound_at` and
      # `last_error`: those are written by what actually happens on the
      # channel (Whatsapp::InboundRouter stamps last_inbound_at on every real
      # delivery), and a form that could set them would let a hotel tell
      # itself a number is working when nothing has ever arrived on it.
      #
      # `provider` is here because a BSP swap is a real, if rare, hotel-level
      # decision — and Whatsapp::Provider.for raises a clear error rather than
      # guessing for the two adapters this slice does not ship.
      def channel_params
        params.require(:whatsapp_channel).permit(
          :phone_number_e164, :phone_number_id, :waba_id, :provider, :status, :display_name_status
        )
      end
  end
end
