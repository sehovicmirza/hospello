require "application_system_test_case"

# The tapping half of "only a human may confirm". The controller tests prove
# what the buttons do; this proves they are buttons — that a real guest on a
# real phone can read the summary, press one, and watch the card go away.
class ServiceRequestCardTest < ApplicationSystemTestCase
  setup do
    @hotel = hotels(:stari_grad)
    @conversation = ActsAsTenant.with_tenant(@hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }
    @category = ActsAsTenant.with_tenant(@hotel) { request_categories(:stari_towels) }
  end

  test "a guest reads the summary, sends it, and the card is gone" do
    pending_draft
    open_guest_chat

    within("#draft-card") do
      assert_text @category.name
      # The promise, in words, right where the decision is made.
      assert_text I18n.t("requests.card.pending_note", locale: :bs)
      click_on I18n.t("requests.card.confirm", locale: :bs)
    end

    assert_text I18n.t("requests.sent_to_reception", locale: :bs)
    assert_no_selector "#draft-confirm"

    ActsAsTenant.with_tenant(@hotel) do
      request = ServiceRequest.sole
      assert request.status_new?, "a guest agreeing does not commit the hotel — a person still decides"
    end
  end

  test "cancelling sends nothing" do
    pending_draft
    open_guest_chat

    within("#draft-card") { click_on I18n.t("requests.card.cancel", locale: :bs) }

    assert_text I18n.t("requests.cancelled", locale: :bs)
    assert_no_selector "#draft-confirm"
    assert_equal 0, ActsAsTenant.with_tenant(@hotel) { ServiceRequest.count }
  end

  # "Change" never submits anything by itself — the same rule the quick-action
  # chips follow. Changing your mind is a sentence you type, not a form this
  # app guessed at on your behalf.
  test "change only fills the composer, and sends nothing" do
    pending_draft
    open_guest_chat

    click_on I18n.t("requests.card.change", locale: :bs)

    assert_equal I18n.t("requests.card.change_prefill", locale: :bs), find("#message_body").value
    assert_selector "#draft-confirm", visible: :all
    assert_equal 0, ActsAsTenant.with_tenant(@hotel) { ServiceRequest.count }
  end

  private
    def pending_draft
      ActsAsTenant.with_tenant(@hotel) do
        @conversation.service_request_drafts.create!(
          request_category: @category, status: :awaiting_confirmation,
          details: { "quantity" => "2", "description" => "bath towels" }
        )
      end
    end

    def open_guest_chat
      # A cookie can only be set for a domain the browser has already loaded
      # (same technique as test/system/guest_staff_live_test.rb).
      visit hotel_landing_path(@hotel.slug)

      jar = ActionDispatch::TestRequest.create.cookie_jar
      jar.signed[:hospello_guest] = "stari-grad-fixture-guest-token"
      page.driver.browser.manage.add_cookie(name: "hospello_guest", value: jar[:hospello_guest], path: "/")

      visit guest_chat_path
      assert_selector "#chat-messages"
    end
end
