# The single public entry point per hotel — where a guest lands right after
# scanning the printed QR card (see HotelQrCode#path, which encodes exactly
# this route). This is the ONLY guest controller that ever takes a hotel
# from the URL: it inherits ApplicationController directly, not
# Guest::BaseController, because Guest::BaseController requires a guest
# session to already exist — here, there isn't one yet. Every other guest
# controller resolves the hotel from the guest's own cookie instead, so a
# guest request can never be made to name a different hotel just by editing
# a URL or a param.
module Guest
  class EntriesController < ApplicationController
    include GuestLocalization

    layout "guest"

    # Guests have no staff session — replaces Authentication's default
    # before_action entirely (see Guest::BaseController for the guest-session
    # equivalent later in the flow).
    allow_unauthenticated_access

    # A guest's cookie is set for this long, and a freshly created session's
    # expires_at starts at exactly this — GuestSession#touch_activity! then
    # extends activity by 7 days at a time, capped at this same span from
    # creation (see that method).
    SESSION_LIFETIME = 21.days

    # Declared first so it's the outermost wrapper — every before_action,
    # around_action, and the eventual render below all happen inside its
    # I18n.with_locale scope (see GuestLocalization).
    around_action :activate_guest_locale
    before_action :set_hotel
    # Declared before the suspension check (not after) so Current.hotel is
    # already set — and the guest layout can already render this hotel's
    # branding and the right <html dir> — on the "not available" page too,
    # not only on the happy path.
    around_action :scope_to_hotel
    before_action :refuse_suspended_hotel

    def show
      return redirect_to guest_chat_path if guest_already_admitted?

      @guest_session = @hotel.guest_sessions.new(locale: guest_locale_for(nil).to_s)
    end

    def create
      raw_token = SecureRandom.urlsafe_base64(32)
      room_number = room_number_param
      room = @hotel.find_active_room(room_number)

      @guest_session = @hotel.guest_sessions.new(guest_session_params)
      @guest_session.room = room
      @guest_session.privacy_accepted_at = Time.current if consent_given?
      @guest_session.expires_at = SESSION_LIFETIME.from_now
      @guest_session.last_seen_at = Time.current
      @guest_session.token_digest = GuestSession.digest(raw_token)

      # Run the model's own validations first (guest_name, locale,
      # privacy_accepted_at, ...) so a guest who both left the room blank
      # AND skipped consent sees every problem at once, then layer the room
      # check on top — room_number isn't a real GuestSession column (the
      # model only ever stores the resolved, tenant-checked `room`
      # association), so it can't be a model validation.
      valid = @guest_session.valid?
      if room_number.blank?
        @guest_session.errors.add(:room_number, "can't be blank")
        valid = false
      elsif room.nil?
        @guest_session.errors.add(:room_number, "wasn't found — please check the room number and try again")
        valid = false
      end

      if valid && @guest_session.save
        issue_guest_cookie(raw_token)
        redirect_to guest_chat_path
      else
        render :show, status: :unprocessable_content
      end
    end

    private
      def set_hotel
        @hotel = Hotel.find_by!(slug: params[:hotel_slug])
      end

      def refuse_suspended_hotel
        render "guest/entries/unavailable" if @hotel.suspended?
      end

      # Everything downstream (Hotel#find_active_room, GuestSession's own
      # tenant-scoped room-ownership validation, GuestSession.authenticate_by_token's
      # caller-side comparison) runs inside the one tenant this request is
      # allowed to name — the hotel resolved from the URL slug above, never
      # from guest-supplied params. Mirrors Staff::BaseController's
      # scope_to_current_hotel, just keyed off @hotel instead of
      # Current.user.hotel.
      def scope_to_hotel(&block)
        Current.hotel = @hotel
        ActsAsTenant.with_tenant(@hotel, &block)
      end

      def activate_guest_locale(&block)
        I18n.with_locale(guest_locale_for(params.dig(:guest_session, :locale)), &block)
      end

      def guest_already_admitted?
        existing = GuestSession.authenticate_by_token(cookies.signed[:hospello_guest])
        existing.present? && existing.hotel_id == @hotel.id
      end

      # Deliberately excludes room/room_id, hotel_id, identity_status,
      # token_digest, privacy_accepted_at, expires_at, status, channel — every
      # one of those is set explicitly above from server-side logic, never
      # from raw params, so a crafted request cannot mass-assign its way into
      # naming another hotel's room, a verified identity, or anything else
      # this form doesn't legitimately ask for.
      def guest_session_params
        params.require(:guest_session).permit(:guest_name, :phone_e164, :locale)
      end

      def room_number_param
        params.dig(:guest_session, :room_number).presence
      end

      def consent_given?
        ActiveModel::Type::Boolean.new.cast(params.dig(:guest_session, :consent))
      end

      def issue_guest_cookie(raw_token)
        cookies.signed[:hospello_guest] = {
          value: raw_token, httponly: true, same_site: :lax, expires: SESSION_LIFETIME.from_now
        }
      end
  end
end
