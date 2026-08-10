module ApplicationCable
  # Identifies a connection two different ways depending on who's
  # connecting: a staff member's session_token cookie (unchanged from
  # before this task), or a guest's hospello_guest cookie — the same
  # signed cookie Guest::BaseController reads to resolve
  # Current.guest_session, read the same way (GuestSession.authenticate_by_token)
  # for the same reason: it is the one legitimate place a guest's identity
  # is looked up before any tenant is known (see that method's own
  # comment). Exactly one of the two is ever set for a real connection —
  # nothing here lets a client claim to be both, or claim a guest_session
  # or user id directly; both are resolved purely from signed cookies the
  # client cannot forge.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :current_guest_session

    def connect
      self.current_user = find_verified_user
      self.current_guest_session = find_verified_guest_session
      reject_unauthorized_connection unless current_user || current_guest_session
    end

    private
      def find_verified_user
        Session.find_by(token: cookies.signed[:session_token])&.user
      end

      def find_verified_guest_session
        GuestSession.authenticate_by_token(cookies.signed[:hospello_guest])
      end
  end
end
