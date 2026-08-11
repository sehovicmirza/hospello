require "test_helper"

module Staff
  # The board a receptionist works from. The two things asserted hardest:
  # every status change goes through ServiceRequest#transition! (so the
  # history and the guest's own chat cannot drift from what the board shows),
  # and a request that cannot legally make a move is not offered the button.
  class ServiceRequestsControllerTest < ActionDispatch::IntegrationTest
    include ActionView::RecordIdentifier

    setup do
      @hotel = hotels(:stari_grad)
      @admin = users(:stari_admin)
      @staff = users(:stari_staff)
      @conversation = with_tenant(@hotel) { conversations(:stari_conversation) }
      @category = with_tenant(@hotel) { request_categories(:stari_towels) }
    end

    test "the board shows this hotel's open requests" do
      request = create_request
      sign_in @staff

      get staff_service_requests_path

      assert_response :success
      assert_select "##{dom_id(request)}"
      assert_select "*", text: /#{@category.name}/
    end

    # --- The request-summary overlay (Slice 5 Task 4) -----------------------
    #
    # The same overlay rule messages already follow: a receptionist reads a
    # translation, with the guest's own words one tap away. Digit-guard
    # coverage (a mangled number never reaches `summary` in the first place)
    # lives in test/jobs/ai/translate_service_request_summary_job_test.rb —
    # these prove the *rendering* half, on the actual board a receptionist
    # works from.

    test "a translated request summary shows the translation, with the guest's own words one tap away" do
      request = create_translated_request(
        summary: "Extra towels — quantity: 2",
        details_original: "Zusätzliche Handtücher — Menge: 2", original_locale: "de"
      )
      sign_in @staff

      get staff_service_requests_path

      assert_response :success
      assert_select "##{dom_id(request)}" do
        assert_select "[data-translation-toggle-target='translated']", text: "Extra towels — quantity: 2"
        # hidden, not absent: the original must be in the DOM either way —
        # findable by selection, by a screen reader, with JavaScript off —
        # the same reasoning shared/_translated_body.html.erb documents.
        assert_select "[data-translation-toggle-target='original']", text: "Zusätzliche Handtücher — Menge: 2"
        assert_select "[data-action='click->translation-toggle#toggle']"
      end
    end

    # Not a failure state — this is the ordinary, honest gap between a
    # request landing on the board and Ai::TranslateServiceRequestSummaryJob
    # actually completing (or a same-language hotel, where nothing is ever
    # queued at all). Either way there is nothing to reveal, so there must
    # be no toggle offering to reveal it.
    test "a request summary not yet translated shows the original with no toggle at all" do
      request = create_request
      sign_in @staff

      get staff_service_requests_path

      assert_response :success
      assert_select "##{dom_id(request)}" do
        assert_select "*", text: request.summary
        assert_select "[data-controller='translation-toggle']", count: 0
      end
    end

    test "the open filter hides finished requests, and the finished one shows them" do
      open_one = create_request
      done = create_request(quantity: "9")
      with_tenant(@hotel) do
        done.transition!(to: :accepted, by: @staff)
        done.transition!(to: :completed, by: @staff)
      end
      sign_in @staff

      get staff_service_requests_path(filter: "open")
      assert_select "##{dom_id(open_one)}"
      assert_select "##{dom_id(done)}", count: 0

      get staff_service_requests_path(filter: "settled")
      assert_select "##{dom_id(done)}"
      assert_select "##{dom_id(open_one)}", count: 0
    end

    test "search finds a request by room number, guest name or what was asked for" do
      request = create_request
      sign_in @staff

      %w[301 Amira towels].each do |term|
        get staff_service_requests_path(q: term)
        assert_select "##{dom_id(request)}", { count: 1 }, "searching #{term.inspect} should have found it"
      end
    end

    test "a search that matches nothing says so rather than showing everything" do
      create_request
      sign_in @staff

      get staff_service_requests_path(q: "helicopter")

      assert_select "#request-board", count: 0
      assert_select "#request-board-empty"
    end

    test "the category filter narrows the board" do
      towels = create_request
      wakeup = create_request(category: request_categories(:stari_wakeup), quantity: "1")
      sign_in @staff

      get staff_service_requests_path(category_id: request_categories(:stari_wakeup).id)

      assert_select "##{dom_id(wakeup)}"
      assert_select "##{dom_id(towels)}", count: 0
    end

    # An unrecognised filter value must land somewhere sane rather than
    # reaching a scope with attacker-chosen input.
    test "an unknown filter or category falls back to showing the open board" do
      request = create_request
      sign_in @staff

      get staff_service_requests_path(filter: "destroy_everything", category_id: "9999999")

      assert_response :success
      assert_select "##{dom_id(request)}"
    end

    # --- Transitions ------------------------------------------------------------

    test "accepting records who did it and tells the guest" do
      request = create_request
      sign_in @staff

      patch transition_staff_service_request_path(request, to: "accepted")

      with_tenant(@hotel) do
        request.reload
        assert request.status_accepted?
        assert_equal @staff, request.acknowledged_by
        assert request.request_events.exists?(kind: :status_change, to_status: ServiceRequest.statuses[:accepted])

        notice = @conversation.messages.order(:id).last
        assert_equal "system", notice.sender_role
        assert_equal I18n.t("requests.status.accepted", locale: :bs), notice.body
      end
    end

    test "completing stamps the time and tells the guest" do
      request = create_request
      with_tenant(@hotel) { request.transition!(to: :accepted, by: @staff) }
      sign_in @staff

      patch transition_staff_service_request_path(request, to: "completed")

      with_tenant(@hotel) do
        assert request.reload.status_completed?
        assert request.completed_at.present?
        assert_equal I18n.t("requests.status.completed", locale: :bs), @conversation.messages.order(:id).last.body
      end
    end

    # A move that makes no sense is refused with a message, not swallowed —
    # a board that silently ignores a tap is a board a receptionist stops
    # trusting.
    test "an impossible move is refused and says so" do
      request = create_request
      sign_in @staff

      patch transition_staff_service_request_path(request, to: "in_progress")

      assert_response :redirect
      assert_match(/cannot become/i, flash[:alert])
      assert with_tenant(@hotel) { request.reload.status_new? }
    end

    test "a made-up status is refused" do
      request = create_request
      sign_in @staff

      patch transition_staff_service_request_path(request, to: "free_upgrade")

      assert with_tenant(@hotel) { request.reload.status_new? }
    end

    # --- The page a receptionist opens -------------------------------------------

    test "the request page shows what was asked for, the history, and only the legal moves" do
      request = create_request
      with_tenant(@hotel) { request.transition!(to: :accepted, by: @staff) }
      sign_in @staff

      get staff_service_request_path(request)

      assert_response :success
      assert_select "#request-history li"
      assert_select "#transition-completed"
      assert_select "#transition-accepted", { count: 0 }, "a request already accepted cannot be accepted again"
    end

    test "a finished request offers no moves at all" do
      request = create_request
      with_tenant(@hotel) do
        request.transition!(to: :accepted, by: @staff)
        request.transition!(to: :completed, by: @staff)
      end
      sign_in @staff

      get staff_service_request_path(request)

      assert_select "#request-transitions form", count: 0
    end

    # --- Notes ---------------------------------------------------------------------

    # The same boundary Message#visibility draws in the chat: a receptionist
    # writing something frank about a guest must be able to trust that the
    # guest cannot read it.
    test "a note is recorded against the request and never reaches the guest" do
      request = create_request
      sign_in @staff

      assert_no_difference -> { with_tenant(@hotel) { @conversation.messages.count } } do
        post staff_service_request_request_events_path(request), params: { note: "Guest sounded annoyed." }
      end

      with_tenant(@hotel) do
        event = request.request_events.last
        assert event.kind_note?
        assert_equal @staff, event.user
        assert_equal "Guest sounded annoyed.", event.note
        assert_not_includes RequestEvent.guest_visible, event
      end
    end

    test "a blank note is refused rather than saved empty" do
      request = create_request
      sign_in @staff

      assert_no_difference -> { with_tenant(@hotel) { RequestEvent.count } } do
        post staff_service_request_request_events_path(request), params: { note: "  " }
      end
      assert_match(/needs some text/i, flash[:alert])
    end

    # A note attached to a transition is staff commentary too — the guest
    # hears the status changed, never what was written about it.
    test "the note on a transition is not passed on to the guest" do
      request = create_request
      sign_in @staff

      patch transition_staff_service_request_path(request, to: "declined"),
            params: { note: "Third time this week, we're out of towels." }

      body = with_tenant(@hotel) { @conversation.messages.order(:id).last.body }
      assert_equal I18n.t("requests.status.declined", locale: :bs), body
      assert_no_match(/third time/i, body)
    end

    # --- Who may work the board ----------------------------------------------------

    # Working the board is the job, not a decision about hotel policy, so
    # every active staff member can do all of it.
    test "a plain staff member can read and work the board" do
      request = create_request
      sign_in @staff

      get staff_service_requests_path
      assert_response :success

      patch transition_staff_service_request_path(request, to: "accepted")
      assert with_tenant(@hotel) { request.reload.status_accepted? }
    end

    # Refused by Staff::BaseController before ServiceRequestPolicy is ever
    # consulted — verified by loosening the policy to allow anyone and
    # watching this stay green. Kept because it pins the *outcome*: whichever
    # layer moves later, a deactivated account still gets nothing.
    test "a deactivated staff member cannot" do
      request = create_request
      @staff.update!(active: false)
      sign_in @staff

      get staff_service_requests_path

      assert_response :forbidden
      assert with_tenant(@hotel) { request.reload.status_new? }
    end

    test "the nav badge counts what nobody has picked up yet" do
      sign_in @staff
      get staff_service_requests_path
      assert_select "#requests-badge", count: 0

      request = create_request
      get staff_service_requests_path
      assert_select "#requests-badge", text: /1/

      with_tenant(@hotel) { request.transition!(to: :accepted, by: @staff) }
      get staff_service_requests_path
      assert_select "#requests-badge", { count: 0 }, "an accepted request is somebody's job now, not an unread one"
    end

    private

    def create_request(category: nil, quantity: "2")
      category ||= @category
      with_tenant(@hotel) do
        details = { "quantity" => quantity, "description" => "bath towels" }
        ServiceRequest.create!(
          hotel: @hotel, conversation: @conversation, guest_session: @conversation.guest_session,
          room: @conversation.guest_session.room, request_category: category, department: category.department,
          summary: "#{category.name} — quantity: #{quantity}, description: bath towels",
          details: details, channel: :web,
          dedupe_key: ServiceRequest.dedupe_key_for(conversation: @conversation, category: category, details: details)
        )
      end
    end

    # A request as it looks once Ai::TranslateServiceRequestSummaryJob has
    # already run and won: `summary` holds the translation, `details_original`
    # the guest's own words it was translated from — the two are only ever
    # allowed to differ after a translation genuinely succeeded (see
    # ServiceRequest#readable_in), which is exactly the state this builds
    # directly rather than by actually calling the job.
    def create_translated_request(summary:, details_original:, original_locale:)
      with_tenant(@hotel) do
        details = { "quantity" => "2", "description" => "bath towels" }
        ServiceRequest.create!(
          hotel: @hotel, conversation: @conversation, guest_session: @conversation.guest_session,
          room: @conversation.guest_session.room, request_category: @category, department: @category.department,
          summary: summary, details_original: details_original, original_locale: original_locale,
          details: details, channel: :web,
          dedupe_key: ServiceRequest.dedupe_key_for(
            conversation: @conversation, category: @category, details: details, requested_for_at: Time.current
          )
        )
      end
    end
  end
end
