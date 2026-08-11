require "application_system_test_case"

# Slice 4's acceptance scenario, in two browsers: a guest confirms a request,
# it appears on the reception board, a receptionist accepts and completes it,
# and the guest watches it change — never having been told anything was
# confirmed before a person confirmed it.
#
# Set up directly in Ruby up to the point the browsers take over, per this
# suite's house rule: what needs proving here is the board and the guest's
# view, not the multi-turn conversation that produced the draft (which is
# proved without a browser in test/services/ai/service_request_flow_test.rb).
class RequestBoardTest < ApplicationSystemTestCase
  # A morphing page refresh makes a full round trip; still a bounded wait, not
  # a sleep, so it returns the moment the text arrives.
  LIVE_WAIT = 15

  setup do
    @hotel = hotels(:stari_grad)
    @conversation = ActsAsTenant.with_tenant(@hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }
    @category = ActsAsTenant.with_tenant(@hotel) { request_categories(:stari_towels) }
  end

  test "a guest confirms, the board picks it up, and every step reaches the guest" do
    ActsAsTenant.with_tenant(@hotel) do
      @conversation.service_request_drafts.create!(
        request_category: @category, status: :awaiting_confirmation,
        details: { "quantity" => "2", "description" => "bath towels" }
      )
    end

    with_two_browsers do |guest, reception|
      sign_in_reception(reception)
      reception.visit staff_service_requests_path
      reception.assert_selector "#request-board-empty"

      open_guest_chat(guest)
      guest.within("#draft-card") { guest.click_on I18n.t("requests.card.confirm", locale: :bs) }
      guest.assert_text I18n.t("requests.sent_to_reception", locale: :bs)

      # The receptionist's page updated itself — nothing is driven on that
      # browser between the sign-in and here.
      reception.assert_text @category.name, wait: LIVE_WAIT
      reception.assert_text "301"

      request = ActsAsTenant.with_tenant(@hotel) { ServiceRequest.sole }

      # stari_staff reads the staff workspace in Bosnian — see
      # test/fixtures/users.yml — so the status/transition labels below are
      # staff.common.request_status/request_transitions' Bosnian text
      # (config/locales/staff.bs.yml), pasted literally.
      reception.within("##{ActionView::RecordIdentifier.dom_id(request)}") do
        reception.assert_text "Novo"
        reception.click_on "Prihvati"
      end
      guest.assert_text I18n.t("requests.status.accepted", locale: :bs), wait: LIVE_WAIT

      reception.within("##{ActionView::RecordIdentifier.dom_id(request)}") do
        reception.assert_text "Prihvaćeno"
        reception.click_on "Označi kao završeno"
      end
      guest.assert_text I18n.t("requests.status.completed", locale: :bs), wait: LIVE_WAIT
    end

    ActsAsTenant.with_tenant(@hotel) do
      request = ServiceRequest.sole
      assert request.status_completed?
      assert_equal %w[accepted completed], request.request_events.map(&:to_status_name)
      assert_equal users(:stari_staff), request.acknowledged_by
    end
  end

  private
    # Explicit Capybara::Session objects rather than Capybara.using_session —
    # see test/system/guest_staff_live_test.rb for why a pooled session breaks
    # the next test in this suite.
    def with_two_browsers
      guest = Capybara::Session.new(Capybara.current_driver, Capybara.app)
      reception = Capybara::Session.new(Capybara.current_driver, Capybara.app)

      yield guest, reception
    ensure
      [ guest, reception ].compact.each do |session|
        session.driver.quit if session.driver.respond_to?(:quit)
      rescue StandardError
        nil
      end
    end

    def sign_in_reception(session)
      session.visit root_url
      session.fill_in "email_address", with: users(:stari_staff).email_address
      session.fill_in "password", with: "password123"
      session.click_on "Sign in"
      # Assert on the destination, not the click (engineering rule 4).
      # stari_staff reads the staff workspace in Bosnian — see
      # test/fixtures/users.yml.
      session.assert_text "Prijavljeni ste kao #{users(:stari_staff).name}"
    end

    def open_guest_chat(session)
      session.visit hotel_landing_path(@hotel.slug)

      jar = ActionDispatch::TestRequest.create.cookie_jar
      jar.signed[:hospello_guest] = "stari-grad-fixture-guest-token"
      session.driver.browser.manage.add_cookie(
        name: "hospello_guest", value: jar[:hospello_guest], path: "/"
      )

      session.visit guest_chat_path
      # visible: :all — <turbo-cable-stream-source> is an empty custom element
      # with no box. Waiting for it is what makes "the guest's page updated
      # itself" a real claim rather than a lucky reload.
      session.assert_selector "turbo-cable-stream-source[connected]", visible: :all, wait: LIVE_WAIT
    end
end
