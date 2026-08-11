require "test_helper"

module Staff
  # The screen that closes the loop: a guest asks something the hotel never
  # wrote down, the assistant says so honestly, and the hotel finds out here.
  # If this screen is wrong or invisible, the concierge never gets better at
  # any particular hotel and "the AI doesn't know" stays permanently true.
  class UnansweredQuestionsControllerTest < ActionDispatch::IntegrationTest
    include ActionView::RecordIdentifier

    setup do
      @hotel = hotels(:stari_grad)
      @admin = users(:stari_admin)
      @staff = users(:stari_staff)
    end

    test "the list shows this hotel's open questions, most-asked first" do
      once = record("Is there a sauna?")
      often = record("Is there a swimming pool?", asked: 4)
      sign_in @admin

      get staff_unanswered_questions_path

      assert_response :success
      assert_select "#knowledge-gaps li:first-child" do
        assert_select "*", text: /swimming pool/
      end
      assert_select "##{dom_id(often)}"
      assert_select "##{dom_id(once)}"
    end

    test "the guest's own words are shown alongside the recorded question" do
      record("Is there a swimming pool?", original: "Ima li bazen?")
      sign_in @admin

      get staff_unanswered_questions_path

      assert_select "*", text: /Ima li bazen\?/
    end

    test "answered and dismissed questions are not in the open list" do
      answered = record("Answered one")
      dismissed = record("Dismissed one")
      with_tenant(@hotel) do
        answered.update!(status: :answered)
        dismissed.update!(status: :dismissed)
      end
      sign_in @admin

      get staff_unanswered_questions_path

      assert_select "#knowledge-gaps", count: 0
      assert_select "#no-knowledge-gaps"
      assert_select "#settled-gaps ##{dom_id(answered)}"
    end

    test "an empty list says what will appear here rather than nothing at all" do
      sign_in @admin

      get staff_unanswered_questions_path

      assert_select "#no-knowledge-gaps"
      # @admin (stari_admin) reads the staff workspace in Bosnian — see
      # fixtures. "ne pokriva" = "doesn't cover" (staff.unanswered_questions
      # .index.empty_hint, config/locales/staff.bs.yml).
      assert_select "*", text: /ne pokriva/
    end

    # --- Answering a gap ----------------------------------------------------

    test "answering opens a knowledge base form already named and set to go live" do
      question = record("Is there a swimming pool?", original: "Ima li bazen?")
      sign_in @admin

      get new_staff_kb_entry_path(unanswered_question_id: question.id)

      assert_response :success
      assert_select "#answering-gap", text: /Ima li bazen/
      assert_select "input[name='kb_entry[title]'][value=?]", "Is there a swimming pool?"
      assert_select "input[name='kb_entry[published]'][checked='checked']"
      assert_select "#kb-entry-gap-id[value=?]", question.id.to_s
    end

    test "saving the answer publishes the entry, links it, and closes the gap" do
      question = record("Is there a swimming pool?")
      sign_in @admin

      post staff_kb_entries_path, params: {
        kb_entry: {
          title: "Swimming pool", content: "There is no pool, but the Ilidža baths are 20 minutes away.",
          category: "facilities", published: "1", unanswered_question_id: question.id
        }
      }

      with_tenant(@hotel) do
        question.reload
        entry = KbEntry.find_by!(title: "Swimming pool")
        assert entry.published?, "a gap answered into a draft is a gap no guest can tell was closed"
        assert_equal entry, question.kb_entry
        assert question.status_answered?
      end
    end

    # An admin who unticked "Live for guests" is saying "not yet". Closing the
    # gap anyway would report the loop finished while the next guest gets the
    # same "I don't have that written down".
    test "saving it as a draft links the entry but leaves the gap open" do
      question = record("Is there a swimming pool?")
      sign_in @admin

      post staff_kb_entries_path, params: {
        kb_entry: {
          title: "Swimming pool", content: "Still checking with the manager.",
          category: "facilities", published: "0", unanswered_question_id: question.id
        }
      }

      with_tenant(@hotel) do
        question.reload
        assert_equal "Swimming pool", question.kb_entry.title
        assert question.status_new?, "the question stays open until an answer actually reaches guests"
      end
    end

    # A validation failure re-renders the form as a POST, and a gap that lost
    # its link there would be silently left open while the hotel believed
    # they had just answered it.
    test "a rejected answer keeps the gap attached to the form" do
      question = record("Is there a swimming pool?")
      sign_in @admin

      post staff_kb_entries_path, params: {
        kb_entry: { title: "", content: "", unanswered_question_id: question.id }
      }

      assert_response :unprocessable_content
      assert_select "#kb-entry-gap-id[value=?]", question.id.to_s
      assert_select "#answering-gap"
    end

    test "another hotel's question cannot be closed by naming it in the form" do
      other_question = with_tenant(hotels(:vrelo)) do
        UnansweredQuestion.record!(hotel: hotels(:vrelo), question: "Is there a swimming pool?")
      end
      sign_in @admin

      post staff_kb_entries_path, params: {
        kb_entry: {
          title: "Swimming pool", content: "No pool here.", published: "1",
          unanswered_question_id: other_question.id
        }
      }

      assert_response :redirect
      assert with_tenant(hotels(:vrelo)) { other_question.reload.status_new? }
      assert_nil with_tenant(hotels(:vrelo)) { other_question.reload.kb_entry_id }
    end

    # --- Dismissing ----------------------------------------------------------

    test "dismissing settles the question without writing anything" do
      question = record("Do you sell cigarettes?")
      sign_in @admin

      assert_no_difference -> { with_tenant(@hotel) { KbEntry.count } } do
        patch dismiss_staff_unanswered_question_path(question)
      end

      assert question.reload.status_dismissed?
    end

    # --- Who may do what -------------------------------------------------------

    # A receptionist answering the same question by hand for the fourth time
    # is the person best placed to notice it belongs in the knowledge base.
    test "a plain staff member may read the list" do
      record("Is there a swimming pool?")
      sign_in @staff

      get staff_unanswered_questions_path

      assert_response :success
      assert_select "*", text: /swimming pool/
    end

    test "a plain staff member is not offered the actions and cannot take them" do
      question = record("Is there a swimming pool?")
      sign_in @staff

      get staff_unanswered_questions_path
      assert_select "#answer-#{question.id}", count: 0
      assert_select "form[action=?]", dismiss_staff_unanswered_question_path(question), count: 0

      patch dismiss_staff_unanswered_question_path(question)
      assert_response :forbidden
      assert question.reload.status_new?
    end

    test "the nav badge counts this hotel's open questions and disappears when there are none" do
      sign_in @admin

      get staff_unanswered_questions_path
      assert_select "#knowledge-gaps-badge", count: 0

      record("Is there a swimming pool?")
      get staff_unanswered_questions_path
      assert_select "#knowledge-gaps-badge", text: /1/
    end

    private

    def record(question, original: nil, asked: 1, hotel: @hotel)
      with_tenant(hotel) do
        row = UnansweredQuestion.record!(hotel: hotel, question: question, question_original: original)
        row.update!(asked_count: asked) if asked > 1
        row
      end
    end
  end
end
