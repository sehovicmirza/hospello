require "application_system_test_case"

# The loop that makes the concierge get better at one specific hotel: a guest
# asks something nobody wrote down, it lands here, a hotel admin writes the
# answer once, and it goes live for guests.
#
# Short and single-purpose with preconditions set up directly in Ruby — this
# suite's house rule (see test/system/guest_chat_test.rb).
class KnowledgeGapTest < ApplicationSystemTestCase
  test "a hotel answers a gap and it goes live for guests in one pass" do
    ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      UnansweredQuestion.record!(
        hotel: hotels(:stari_grad),
        question: "Is there a swimming pool?", question_original: "Ima li bazen?", locale: "bs"
      )
    end
    sign_in_as_hotel_admin

    # stari_admin reads the staff workspace in Bosnian — see
    # test/fixtures/users.yml — so every staff-chrome label below is the
    # literal Bosnian text from config/locales/staff.bs.yml. Flash notices
    # ("saved.", "answered for guests now") are set as literal English
    # strings in the controller, out of this task's scope, and stay English.
    click_on "Praznine u znanju"
    assert_text "Is there a swimming pool?"
    assert_text "Ima li bazen?"

    click_on "Odgovori i dodaj u bazu znanja"

    # The form knows what it is answering, and arrives ready to go live —
    # a gap answered into a draft is a gap no guest can tell was closed.
    within("#answering-gap") { assert_text "Ima li bazen?" }
    assert_equal "Is there a swimming pool?", find_field("Naslov").value
    assert find_field("Vidljivo gostima").checked?

    fill_in "Naslov", with: "Swimming pool"
    fill_in "Šta asistent smije reći gostima",
            with: "We have no pool, but the Ilidža thermal baths are 20 minutes away by tram."
    click_on "Sačuvaj stavku"

    assert_text "“Swimming pool” saved."
    assert_text "That question is answered for guests now."

    ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      question = UnansweredQuestion.find_by!(question: "Is there a swimming pool?")
      assert question.status_answered?
      assert question.kb_entry.published?, "the answer has to actually reach guests"
    end
  end

  test "dismissing a gap takes it off the list without writing anything down" do
    ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      UnansweredQuestion.record!(hotel: hotels(:stari_grad), question: "Do you sell cigarettes?")
    end
    sign_in_as_hotel_admin

    visit staff_unanswered_questions_path
    assert_text "Do you sell cigarettes?"

    # staff.unanswered_questions.index.dismiss, config/locales/staff.bs.yml.
    accept_confirm_if_any { click_on "Odbaci" }

    assert_text "Dismissed."
    within("#settled-gaps") { assert_text "Do you sell cigarettes?" }

    ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      assert UnansweredQuestion.find_by!(question: "Do you sell cigarettes?").status_dismissed?
      assert_not KbEntry.exists?(title: "Do you sell cigarettes?")
    end
  end

  # The badge is the whole reason this screen works: a hotel that never opens
  # it never discovers what it failed to answer.
  test "the nav badge shows how many gaps are waiting" do
    ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      UnansweredQuestion.record!(hotel: hotels(:stari_grad), question: "Is there a swimming pool?")
      UnansweredQuestion.record!(hotel: hotels(:stari_grad), question: "Do you have a gym?")
    end
    sign_in_as_hotel_admin

    within("#knowledge-gaps-badge") { assert_text "2" }
  end

  private
    # There is no confirmation on Dismiss today. Wrapped anyway so that adding
    # one later is a product decision rather than a broken test.
    def accept_confirm_if_any
      yield
    rescue Capybara::ModalNotFound
      nil
    end

    def sign_in_as_hotel_admin
      visit root_url
      fill_in "email_address", with: users(:stari_admin).email_address
      fill_in "password", with: "password123"
      click_on "Sign in"
      # Assert on the destination, not the click (engineering rule 4).
      # stari_admin reads the staff workspace in Bosnian — see
      # test/fixtures/users.yml — staff.layout.signed_in_as_html
      # (config/locales/staff.bs.yml), pasted literally.
      assert_text "Prijavljeni ste kao #{users(:stari_admin).name}"
    end
end
