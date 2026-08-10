# Every guest controller except Guest::EntriesController (see that
# controller for the one deliberate exception) inherits this. It resolves
# Current.guest_session from the guest's signed cookie and sets
# Current.hotel / the acts_as_tenant tenant from *that session's* hotel —
# never from a URL parameter or any other request input. A guest request
# must never be able to name another hotel: there is no :hotel_slug, no
# :hotel_id, nothing tenant-identifying anywhere in this namespace's routes,
# on purpose.
module Guest
  class BaseController < ApplicationController
    include GuestLocalization

    layout "guest"

    # Guests have no staff session — this replaces Authentication's default
    # before_action with the guest-session equivalent below, the same shape
    # Guest::EntriesController uses for the same reason.
    allow_unauthenticated_access

    before_action :require_guest_session
    around_action :scope_to_guest_hotel

    private
      # Renders the re-entry page (missing cookie, expired session, or a
      # session staff has blocked all look identical from here — none of
      # them get a session, so none of them get a distinct error message
      # that would help someone probe which case they hit). Still activates
      # a best-effort locale for that page even though there's no guest
      # session to read one from.
      def require_guest_session
        session = GuestSession.authenticate_by_token(cookies.signed[:hospello_guest])

        if session.nil?
          activate_guest_locale(nil)
          return render "guest/base/re_entry", status: :unauthorized
        end

        Current.guest_session = session
        activate_guest_locale(session.locale)
      end

      def scope_to_guest_hotel(&block)
        Current.hotel = Current.guest_session.hotel
        ActsAsTenant.with_tenant(Current.guest_session.hotel, &block)
      end
  end
end
