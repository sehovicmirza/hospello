module Staff
  # Notes staff write on a request — "guest says the shower is cold too",
  # "left with housekeeping". They share a table with the status history
  # because to the receptionist reading it they are one list, in order, of
  # what happened.
  #
  # A note is **never** guest-visible. RequestEvent.guest_visible covers only
  # status changes, and ServiceRequest#notify_guest deliberately does not pass
  # a transition's note through — the same boundary Message#visibility draws
  # in the chat, for the same reason.
  class RequestEventsController < BaseController
    # Service requests are what the Service plan buys. On Essentials the whole
    # queue does not exist, so this screen is refused with an explanation
    # rather than shown empty (see PlanGated).
    requires_plan_feature :requests

    def create
      @request = Current.hotel.service_requests.find(params[:service_request_id])
      authorize @request, :note?

      @request.request_events.create!(
        hotel: Current.hotel, user: Current.user, kind: :note, note: params[:note]
      )

      redirect_to staff_service_request_path(@request), notice: t(".note_added")
    rescue ActiveRecord::RecordInvalid
      redirect_to staff_service_request_path(@request), alert: t(".note_blank")
    end
  end
end
