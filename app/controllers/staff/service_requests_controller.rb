module Staff
  # The reception board — what a receptionist standing at a desk with a queue
  # of guests actually works from.
  #
  # Nothing here creates a request: the only path that makes one is a guest
  # confirming a draft (ServiceRequestDraft#confirm!). Nothing here changes a
  # status directly either — every change goes through
  # ServiceRequest#transition!, which validates it, writes the RequestEvent
  # history, and tells the guest. A controller that set `status` itself would
  # produce a board that quietly disagreed with the guest's own chat.
  class ServiceRequestsController < BaseController
    # Service requests are what the Service plan buys. On Essentials the whole
    # queue does not exist, so this screen is refused with an explanation
    # rather than shown empty (see PlanGated).
    requires_plan_feature :requests

    # An upper bound on one screen, not a pagination scheme: a hotel with
    # more than this waiting has a staffing problem the software cannot fix,
    # and rendering 2000 cards would make the board unusable exactly when it
    # matters most.
    MAX_ROWS = 200

    FILTERS = { open: :open_requests, all: :all, settled: :settled }.freeze

    before_action :set_request, only: %i[show transition]

    def index
      authorize ServiceRequest

      @filter = FILTERS.key?(params[:filter]&.to_sym) ? params[:filter].to_sym : :open
      @query = params[:q].to_s.strip

      @requests = Current.hotel.service_requests
                    .public_send(FILTERS.fetch(@filter))
                    .matching(@query)
                    .where(category_filter)
                    .includes(:room, :request_category, :assigned_to, :guest_session)
                    .board_order
                    .limit(MAX_ROWS)

      @counts = {
        open: Current.hotel.service_requests.open_requests.count,
        new: Current.hotel.service_requests.status_new.count
      }
      @categories = Current.hotel.request_categories.ordered
    end

    def show
      authorize @request, :show?

      @events = @request.request_events.chronological.includes(:user)
    end

    # One route for every status change rather than accept/start/complete/
    # decline as separate actions: the transition table on the model already
    # says which are legal, and four near-identical actions would be four
    # places to forget the authorize call.
    def transition
      authorize @request, :transition?

      @request.transition!(to: params[:to], by: Current.user, note: params[:note].presence)
      redirect_back_or_to staff_service_request_path(@request), notice: transition_notice
    rescue ServiceRequest::InvalidTransition => e
      # e.message is untranslated English — this fires only when two staff
      # members race the same request in two tabs, or a stale page offers a
      # button the request can no longer legally take; not a routine
      # confirmation. Left as a known, deliberate gap alongside
      # Staff::RoomsController#bulk_create's own model-exception alert —
      # see this task's report.
      redirect_back_or_to staff_service_request_path(@request), alert: e.message.capitalize
    end

    private
      def set_request
        @request = Current.hotel.service_requests.find(params[:id])
      end

      # An unrecognised ?category= filters nothing rather than reaching a
      # scope with attacker-chosen input.
      def category_filter
        return {} if params[:category_id].blank?

        category = Current.hotel.request_categories.find_by(id: params[:category_id])
        category ? { request_category_id: category.id } : {}
      end

      def transition_notice
        case @request.status
        when "accepted" then t(".accepted")
        when "in_progress" then t(".in_progress")
        when "completed" then t(".completed")
        when "declined" then t(".declined")
        when "cancelled" then t(".cancelled")
        end
      end
  end
end
