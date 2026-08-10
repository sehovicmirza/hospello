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

    # Both around_actions: session/locale resolution has to wrap everything
    # after it (including the eventual render, for I18n.with_locale to
    # actually cover it — see GuestLocalization), and tenant-scoping has to
    # wrap everything *it* comes before too. Declaring both as around_action,
    # in this order, nests them correctly either way.
    around_action :resolve_guest_session_and_locale
    around_action :scope_to_guest_hotel
    # Declared after scope_to_guest_hotel (not before) so Current.hotel is
    # already set — suspension can happen at any point during an otherwise
    # still-valid, unexpired session, so this re-checks it on *every* guest
    # request, not just at cookie-issue time. Staff::BaseController does the
    # analogous check (`Current.user.hotel&.active?`) on every staff
    # request; this was missing here entirely, so a guest whose hotel got
    # suspended mid-stay kept full chat access on an already-issued cookie.
    before_action :refuse_suspended_hotel

    private
      # Reuses guest/entries/unavailable — the same "not currently accepting
      # guest chats, call the front desk" page a fresh visitor to a
      # suspended hotel's landing page sees (Guest::EntriesController), so a
      # guest never hits a dead end or a raw error here, just the same
      # honest message either way.
      def refuse_suspended_hotel
        return unless Current.hotel.suspended?

        @hotel = Current.hotel
        render "guest/entries/unavailable"
      end

      # Renders the re-entry page (missing cookie, expired session, or a
      # session staff has blocked all look identical from here — none of
      # them get a session, so none of them get a distinct error message
      # that would help someone probe which case they hit) without ever
      # calling `yield` — same halting effect a before_action's render has,
      # so scope_to_guest_hotel below never runs. Still activates a
      # best-effort locale for that page even though there's no guest
      # session to read one from.
      def resolve_guest_session_and_locale
        session = GuestSession.authenticate_by_token(cookies.signed[:hospello_guest])

        if session.nil?
          I18n.with_locale(guest_locale_for(nil)) { render "guest/base/re_entry", status: :unauthorized }
          return
        end

        Current.guest_session = session
        I18n.with_locale(guest_locale_for(session.locale)) { yield }
      end

      def scope_to_guest_hotel(&block)
        Current.hotel = Current.guest_session.hotel
        ActsAsTenant.with_tenant(Current.guest_session.hotel, &block)
      end
  end
end
