module Staff
  # The hotel's own knowledge base — the only thing the Slice 3 concierge is
  # allowed to answer a hotel question from. That makes publishing the act
  # that puts words in a guest's hands on the hotel's behalf, which is why
  # it is a distinct action with its own audit trail rather than a checkbox
  # buried in #update.
  #
  # Reading is open to every active staff member and writing is hotel-admin
  # only (KbEntryPolicy): a receptionist answering the same questions by
  # hand needs to look up what the hotel has already promised, but changing
  # what the hotel promises is not a mid-shift decision.
  class KbEntriesController < BaseController
    before_action :set_entry, only: %i[edit update destroy publish]

    def index
      authorize KbEntry

      @category = requested_category
      @entries = Current.hotel.kb_entries.ordered
      @entries = @entries.where(category: @category) if @category
      @counts = Current.hotel.kb_entries.group(:category).count
      @draft_count = Current.hotel.kb_entries.drafts.count
    end

    def new
      # A title arriving in the query string is how the empty state's
      # starter buttons work (see the index view): the hotel picks a topic
      # they know guests ask about and lands on a form already named.
      #
      # ?unanswered_question= is the other way in — a guest already asked
      # this and got "I don't have that written down", so the form arrives
      # named after their question and ticked to go live, because a gap
      # answered into a draft has not actually been answered.
      set_unanswered_question
      @entry = Current.hotel.kb_entries.new(
        title: params[:title].presence || @unanswered_question&.question,
        category: requested_category || :other,
        published: @unanswered_question.present?
      )
      authorize @entry
    end

    def create
      set_unanswered_question
      @entry = Current.hotel.kb_entries.new(entry_params)
      authorize @entry

      if save_entry_and_close_the_gap
        audit_publication_change if @entry.published?
        redirect_to staff_kb_entries_path, notice: [ t(".saved", title: @entry.title), gap_notice ].compact_blank.join(" ")
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
    end

    def update
      was_published = @entry.published?

      if @entry.update(entry_params)
        audit_publication_change if @entry.published? != was_published
        redirect_to staff_kb_entries_path, notice: t(".saved", title: @entry.title)
      else
        render :edit, status: :unprocessable_content
      end
    end

    # Separate from #update, and its own policy question, because this is
    # the only action here whose effect is visible to guests. It is also the
    # one a hotel will use most — a one-tap toggle on the list — so making
    # it go through the full edit form would be the wrong shape.
    def publish
      authorize @entry, :publish?

      @entry.update!(published: params[:published] == "true")
      audit_publication_change

      redirect_to staff_kb_entries_path,
        notice: @entry.published? ? t(".live", title: @entry.title) : t(".draft", title: @entry.title)
    end

    def destroy
      title = @entry.title
      @entry.destroy
      redirect_to staff_kb_entries_path, notice: t(".deleted", title: title)
    end

    private
      # The gap this entry is being written to answer, if any. Looked up
      # through Current.hotel, so another hotel's id is simply nil rather
      # than an authorization question.
      def set_unanswered_question
        id = params[:unanswered_question_id].presence || params.dig(:kb_entry, :unanswered_question_id).presence
        @unanswered_question = Current.hotel.unanswered_questions.find_by(id: id)
      end

      # Linking and answering happen in the same transaction as the save, so
      # a hotel never ends up with the entry written and the gap still open
      # (or the reverse) because something failed in between.
      #
      # The question is marked answered only when the entry actually went
      # live. An admin who unticked "Live for guests" is saying "not yet",
      # and a gap closed against a draft would be a gap that no guest can
      # tell was ever closed — the loop would report itself finished while
      # the next guest gets the same "I don't have that written down".
      def save_entry_and_close_the_gap
        KbEntry.transaction do
          next false unless @entry.save
          next true if @unanswered_question.nil?

          @unanswered_question.update!(
            kb_entry: @entry,
            status: @entry.published? ? :answered : @unanswered_question.status
          )
          true
        end
      end

      # nil rather than "" for "no gap" — the caller joins this onto the
      # main "saved" sentence with #compact_blank, which treats nil and ""
      # alike, but nil never risks the pure-whitespace value the structural
      # locale-file test (test/i18n/locale_files_test.rb) exists to reject.
      def gap_notice
        return nil if @unanswered_question.nil?

        if @unanswered_question.status_answered?
          t("staff.kb_entries.gap_notice.answered")
        else
          t("staff.kb_entries.gap_notice.still_draft")
        end
      end

      def set_entry
        @entry = Current.hotel.kb_entries.find(params[:id])
        authorize @entry unless action_name == "publish"
      end

      # An unrecognised ?category= falls back to "everything" rather than
      # reaching a scope or an enum lookup with attacker-chosen input.
      def requested_category
        category = params[:category].to_s
        KbEntry.categories.key?(category) ? category : nil
      end

      def entry_params
        params.require(:kb_entry).permit(:title, :content, :category, :published, :position)
      end

      # Publishing and unpublishing are the two events worth being able to
      # reconstruct later — "who told guests this, and when" is the question
      # that gets asked after a guest quotes something back at a hotel.
      def audit_publication_change
        AuditLog.record!(
          actor: Current.user,
          action: @entry.published? ? "kb_entry.publish" : "kb_entry.unpublish",
          hotel: Current.hotel,
          target: @entry,
          metadata: { title: @entry.title }
        )
      end
  end
end
