module Platform
  # Actioning a guest's request to be forgotten.
  #
  # Nested under a hotel because that is how the request arrives — "a guest of
  # the Stari Grad wants their data deleted" — and because a guest session
  # only means anything inside one hotel. The hotel comes from the URL and the
  # guest session is looked up **through that hotel's own association**, so
  # another hotel's session id 404s here exactly as it would anywhere else in
  # this app (test/tenancy/cross_tenant_access_test.rb).
  #
  # Every action reads tenant-scoped tables, and this namespace deliberately
  # sets no ambient tenant, so each one names its hotel with
  # ActsAsTenant.with_tenant — never one of the escape hatches
  # test/tenancy/without_tenant_grep_test.rb polices, which is the point: this
  # controller narrows to one hotel, it never widens past one.
  class GuestErasuresController < BaseController
    before_action :set_hotel

    # Finding the guest is half the job: an erasure request arrives as a
    # name, a room number or a phone number, never as an id.
    def index
      authorize :guest_erasure

      @query = params[:q].to_s.strip
      # includes(:room) and .to_a, both deliberate: Room is tenant-scoped, so
      # a room read lazily from the template would run its query outside this
      # block and raise NoTenantSet. That is the fail-closed guarantee
      # working, not something to route around — the same lesson
      # Analytics::HotelReport#for_hotel already carries, reached from the
      # other direction.
      @guest_sessions = ActsAsTenant.with_tenant(@hotel) do
        matching(@hotel.guest_sessions.includes(:room)).order(last_seen_at: :desc, id: :desc).limit(50).to_a
      end
    end

    # The confirmation. It is irreversible, so it names what is about to be
    # destroyed rather than asking "are you sure?" — a count of conversations,
    # of messages, of requests that will lose their guest — and those numbers
    # come from the same object that then does the destroying.
    def new
      authorize :guest_erasure
      @guest_session = find_guest_session
      @tally = Retention::GuestErasure.preview(guest_session: @guest_session)
    end

    def create
      authorize :guest_erasure
      @guest_session = find_guest_session

      tally = Retention::GuestErasure.call(guest_session: @guest_session, actor: Current.user)

      redirect_to platform_hotel_guest_erasures_path(@hotel),
        notice: "Erased: #{tally.conversations} conversation(s), #{tally.messages} message(s), " \
                "#{tally.service_requests} request(s) anonymized. This cannot be undone."
    end

    private
      def set_hotel
        @hotel = Hotel.find(params[:hotel_id])
      end

      # Through the hotel's own association, inside its own tenant: there is
      # no id in any of these paths that could reach another hotel's guest.
      def find_guest_session
        ActsAsTenant.with_tenant(@hotel) do
          # includes(:room) for the same reason #index has it: the
          # confirmation page names the room, and reading it lazily from the
          # template would query a tenant-scoped table outside this block.
          @hotel.guest_sessions.includes(:room).find(params[:guest_session_id] || params[:id])
        end
      end

      # Name, room number or phone — unanchored, the same shape
      # Conversation.matching and ServiceRequest.matching already use, because
      # "Amira" and "301" and "+38761..." are all somebody reads off an email.
      # A blank query lists the most recent guests rather than nothing: an
      # operator with a room number and a date needs to browse.
      def matching(scope)
        return scope if @query.blank?

        pattern = "%#{GuestSession.sanitize_sql_like(@query)}%"
        scope.left_joins(:room).where(
          "guest_sessions.guest_name ILIKE :pattern OR guest_sessions.phone_e164 ILIKE :pattern " \
          "OR rooms.number ILIKE :pattern",
          pattern: pattern
        )
      end
  end
end
