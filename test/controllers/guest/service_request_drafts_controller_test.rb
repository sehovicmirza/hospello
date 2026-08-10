require "test_helper"

module Guest
  # The summary card's two buttons — the tapping half of "only a human may
  # confirm". Everything protective is in ServiceRequestDraft; what is tested
  # here is that this controller takes the draft from the guest's own cookie
  # and never from the request, and that a guest who taps Confirm is told, in
  # their own language, that the request is *pending*.
  class ServiceRequestDraftsControllerTest < ActionDispatch::IntegrationTest
    GUEST_TOKEN = "stari-grad-fixture-guest-token".freeze

    setup do
      @hotel = hotels(:stari_grad)
      @guest_session = with_tenant(@hotel) { guest_sessions(:stari_guest) }
      @conversation = with_tenant(@hotel) { Conversation.live_for(@guest_session) }
      @category = with_tenant(@hotel) { request_categories(:stari_towels) }
    end

    test "confirming sends the request and tells the guest it is pending" do
      draft = pending_draft
      sign_in_guest GUEST_TOKEN

      post confirm_guest_service_request_draft_path

      assert_redirected_to guest_chat_path
      with_tenant(@hotel) do
        request = ServiceRequest.sole
        assert_equal @category, request.request_category
        assert request.status_new?
        assert draft.reload.status_confirmed?

        notice = @conversation.messages.order(:id).last
        assert_equal "system", notice.sender_role
        assert notice.guest_visible?
        assert_equal I18n.t("requests.sent_to_reception", locale: :bs), notice.body
      end
    end

    # The words matter as much as the record. "Sent" and "pending" are the
    # promise; "confirmed", "booked" and "approved" are things only a person
    # can decide, and this message is posted before any person has seen it.
    test "the receipt never says the hotel has agreed to anything" do
      pending_draft
      sign_in_guest GUEST_TOKEN

      post confirm_guest_service_request_draft_path

      body = with_tenant(@hotel) { @conversation.messages.order(:id).last.body }
      assert_no_match(/potvr|confirm|book|approv|reserv/i, body)
    end

    test "cancelling discards the draft and creates nothing" do
      draft = pending_draft
      sign_in_guest GUEST_TOKEN

      post discard_guest_service_request_draft_path

      with_tenant(@hotel) do
        assert draft.reload.status_discarded?
        assert_equal 0, ServiceRequest.count
        assert_equal I18n.t("requests.cancelled", locale: :bs), @conversation.messages.order(:id).last.body
      end
    end

    # A draft the guest has not been shown is not theirs to confirm by
    # posting to this route directly.
    test "a draft still being gathered cannot be confirmed from the card route" do
      with_tenant(@hotel) do
        @conversation.service_request_drafts.create!(request_category: @category, status: :gathering)
      end
      sign_in_guest GUEST_TOKEN

      post confirm_guest_service_request_draft_path

      assert_equal 0, with_tenant(@hotel) { ServiceRequest.count }
    end

    test "confirming with nothing pending is a no-op, not an error" do
      sign_in_guest GUEST_TOKEN

      post confirm_guest_service_request_draft_path

      assert_redirected_to guest_chat_path
      assert_equal 0, with_tenant(@hotel) { ServiceRequest.count }
    end

    # Tapping twice on a slow phone, or tapping while a typed "yes" is still
    # in flight. One guest agreeing once means one request.
    test "confirming twice produces one request" do
      pending_draft
      sign_in_guest GUEST_TOKEN

      2.times { post confirm_guest_service_request_draft_path }

      assert_equal 1, with_tenant(@hotel) { ServiceRequest.count }
    end

    test "an expired draft cannot be confirmed from the card" do
      draft = pending_draft
      with_tenant(@hotel) { draft.update!(expires_at: 1.minute.ago) }
      sign_in_guest GUEST_TOKEN

      post confirm_guest_service_request_draft_path

      assert_redirected_to guest_chat_path
      assert_equal 0, with_tenant(@hotel) { ServiceRequest.count }
    end

    test "a guest with no session at all cannot reach it" do
      post confirm_guest_service_request_draft_path

      assert_response :unauthorized
      assert_equal 0, with_tenant(@hotel) { ServiceRequest.count }
    end

    # There is no id anywhere in this route, so another guest's draft is not
    # merely refused — it is unnameable. And if a future version of this
    # controller did read one from params, acts_as_tenant would still refuse:
    # verified by making it look the conversation up from params, at which
    # point the draft query returns nothing because the tenant does not match.
    # This test is a regression guard on that combination staying true, not a
    # check on a line of controller code.
    test "another hotel's draft is untouchable from here" do
      theirs = with_tenant(hotels(:vrelo)) do
        conversations(:vrelo_conversation).service_request_drafts.create!(
          request_category: request_categories(:vrelo_wakeup), status: :awaiting_confirmation,
          details: { "time" => "07:00" }
        )
      end
      sign_in_guest GUEST_TOKEN

      post confirm_guest_service_request_draft_path, params: { id: theirs.id, draft_id: theirs.id }

      assert with_tenant(hotels(:vrelo)) { theirs.reload.status_awaiting_confirmation? }
      assert_equal 0, with_tenant(hotels(:vrelo)) { ServiceRequest.count }
    end

    # --- The card on the page --------------------------------------------------

    test "the card is on the chat when something is waiting to be agreed to" do
      pending_draft
      sign_in_guest GUEST_TOKEN

      get guest_chat_path

      assert_select "#draft-card #draft-confirm"
      assert_select "#draft-card #draft-cancel"
      assert_select "#draft-card #draft-change"
      assert_select "#draft-card-summary", text: /#{@category.name}/
    end

    # Empty rather than absent: it is the target of a live Turbo replace, and
    # a target that does not exist yet is a broadcast that lands nowhere.
    test "the card element is present but empty when nothing is waiting" do
      sign_in_guest GUEST_TOKEN

      get guest_chat_path

      assert_select "#draft-card"
      assert_select "#draft-confirm", count: 0
    end

    test "a draft still being gathered shows no card" do
      with_tenant(@hotel) do
        @conversation.service_request_drafts.create!(request_category: @category, status: :gathering)
      end
      sign_in_guest GUEST_TOKEN

      get guest_chat_path

      assert_select "#draft-confirm", count: 0
    end

    private

    def pending_draft
      with_tenant(@hotel) do
        @conversation.service_request_drafts.create!(
          request_category: @category, status: :awaiting_confirmation,
          details: { "quantity" => "2", "description" => "bath towels" }
        )
      end
    end
  end
end
