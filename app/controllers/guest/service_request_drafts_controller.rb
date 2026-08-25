module Guest
  # The two buttons on the summary card.
  #
  # Everything protective lives in ServiceRequestDraft — this controller only
  # decides *which* draft, and takes that from the guest's own cookie rather
  # than from the form. There is no id in the route on purpose (see
  # Guest::BaseController): the draft is always the live one belonging to this
  # conversation, so a form cannot name somebody else's.
  #
  # Confirm converges on the same ServiceRequestDraft#confirm! that a typed
  # "yes" reaches through the model. Two paths, one method, one unique index —
  # which is why tapping the button and saying yes in the same breath cannot
  # produce two requests.
  class ServiceRequestDraftsController < BaseController
    before_action :set_conversation
    # Defence in depth. On a plan without requests no draft can exist — the
    # only thing that creates one is propose_service_request, which the
    # assistant is neither offered nor allowed to run — so this should never
    # fire. It is here because "should never" is not a guarantee, and this
    # controller is the second of the two callers of
    # ServiceRequestDraft#confirm!, the one that does not go through the model
    # at all.
    before_action :refuse_when_plan_has_no_requests

    def confirm
      draft = pending_draft
      return redirect_to guest_chat_path, alert: t("requests.nothing_pending") if draft.nil?

      draft.confirm!
      # Pre-translated, from disk, in the guest's own language — posted by a
      # controller with no model in the loop, exactly like the degradation
      # notice. It says sent and pending, never confirmed or booked: the
      # hotel has not agreed to anything yet, and a person still decides.
      @conversation.post_system_notice!(body: t("requests.sent_to_reception"))

      redirect_to guest_chat_path
    rescue ServiceRequestDraft::NotConfirmable
      # The draft expired, or a "yes" typed a second earlier already
      # confirmed it. Either way there is nothing more to do and nothing has
      # gone wrong from the guest's side.
      redirect_to guest_chat_path
    end

    def discard
      pending_draft&.update!(status: :discarded)
      @conversation.post_system_notice!(body: t("requests.cancelled"))

      redirect_to guest_chat_path
    end

    private

      def refuse_when_plan_has_no_requests
        head :forbidden unless Current.hotel.plan_allows?(:requests)
      end

      def set_conversation
        @conversation = Conversation.live_for(Current.guest_session)
      end

      def pending_draft
        draft = ServiceRequestDraft.live_for(@conversation)
        draft if draft&.status_awaiting_confirmation?
      end
  end
end
