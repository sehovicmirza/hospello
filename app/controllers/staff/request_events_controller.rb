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
    def create
      @request = Current.hotel.service_requests.find(params[:service_request_id])
      authorize @request, :note?

      @request.request_events.create!(
        hotel: Current.hotel, user: Current.user, kind: :note, note: params[:note]
      )

      redirect_to staff_service_request_path(@request), notice: "Note added — the guest cannot see it."
    rescue ActiveRecord::RecordInvalid
      redirect_to staff_service_request_path(@request), alert: "A note needs some text."
    end
  end
end
