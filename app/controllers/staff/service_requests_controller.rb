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
        when "accepted" then "Marked as accepted — the guest has been told someone is on it."
        when "in_progress" then "Marked as under way."
        when "completed" then "Marked as done."
        when "declined" then "Declined, and the guest has been told."
        when "cancelled" then "Cancelled."
        end
      end
  end
end
