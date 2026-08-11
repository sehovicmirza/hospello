module Staff
  # What guests asked that this hotel had never written down.
  #
  # This is the screen that makes the concierge get better at one specific
  # hotel over time, and it is the honest answer to "what happens when the AI
  # doesn't know?" — it says so, hands the guest to reception, and writes the
  # gap down here. Buried, that loop never closes; the nav badge exists for
  # exactly that reason.
  class UnansweredQuestionsController < BaseController
    before_action :set_question, only: %i[dismiss]

    def index
      authorize UnansweredQuestion

      # Most-asked first: a hotel should write the answer to the question
      # fourteen guests asked before the one asked once.
      @questions = Current.hotel.unanswered_questions.open_gaps
      @settled = Current.hotel.unanswered_questions.where.not(status: :new).order(updated_at: :desc).limit(20)
    end

    # Deciding this hotel will not answer something. Deliberately not a
    # delete: the row keeps counting repeats, so a question dismissed once
    # and then asked thirty more times is still visible as a decision worth
    # revisiting rather than silently re-created as new.
    def dismiss
      authorize @question, :dismiss?

      @question.update!(status: :dismissed)
      redirect_to staff_unanswered_questions_path, notice: t(".dismissed")
    end

    private
      def set_question
        @question = Current.hotel.unanswered_questions.find(params[:id])
      end
  end
end
