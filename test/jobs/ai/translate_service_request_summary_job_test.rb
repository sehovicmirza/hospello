require "test_helper"

module Ai
  # Translation as an overlay for a request summary — the request-summary
  # counterpart of translate_message_job_test.rb, and the same two
  # questions every test here asks: did the original survive, and — because
  # a request summary is exactly where "2 towels at 18:00" silently becoming
  # "20 towels at 8:00" does real operational damage — did the digit guard
  # actually protect it.
  class TranslateServiceRequestSummaryJobTest < ActiveJob::TestCase
    setup do
      @hotel = hotels(:stari_grad)          # staff_locale: bs
      ActsAsTenant.current_tenant = @hotel
      @conversation = conversations(:stari_conversation)
      @fake = FakeClaude.new
    end

    test "a confirmed request's summary is translated into the hotel's staff language" do
      request = create_request(original_locale: "de", details_original: "Zwei zusätzliche Handtücher — Menge: 2")
      @fake.script_text("Dva dodatna peškira — količina: 2", input_tokens: 40, output_tokens: 12)

      translate(request)

      request.reload
      assert_equal "Dva dodatna peškira — količina: 2", request.summary
      assert_equal "Zwei zusätzliche Handtücher — Menge: 2", request.details_original,
                   "the original is what the guest confirmed and never changes"
    end

    test "a request already in the hotel's own language is never sent anywhere" do
      request = create_request(original_locale: "bs", details_original: "Dva peškira")

      translate(request)

      assert_equal 0, @fake.call_count
      assert_equal request.details_original, request.reload.summary
    end

    test "a request with no original recorded is never sent anywhere" do
      request = create_request(original_locale: "de", details_original: nil)

      translate(request)

      assert_equal 0, @fake.call_count
    end

    # --- When it does not work ------------------------------------------------

    test "a timeout leaves the summary exactly as it started" do
      request = create_request(original_locale: "de", details_original: "Zwei zusätzliche Handtücher")
      original_summary = request.summary
      @fake.script_timeout

      translate(request)

      assert_equal original_summary, request.reload.summary
      assert_equal "timeout", AiRun.order(:id).last.error_class
    end

    # The whole reason the digit guard exists, seen from the outside: "2
    # towels at 18:00" must never silently become "20 towels at 8:00" on a
    # receptionist's board. Broken and restored to prove it actually fires —
    # see task-4-report.md.
    test "a translation that changed a number is thrown away, and the receptionist still reads the original" do
      request = create_request(original_locale: "de", details_original: "2 Handtücher um 18:00 Uhr")
      original_summary = request.summary
      @fake.script_text("20 peškira u 8:00")

      translate(request)

      request.reload
      assert_equal original_summary, request.summary, "the digit-mangled translation must never reach the board"
      assert_equal "digit_mismatch", AiRun.order(:id).last.error_class

      # And the overlay itself must not present the (unchanged) summary as
      # if it were a real translation — readable_in has to say :original.
      text, source = request.readable_in(@hotel.staff_locale)
      assert_equal original_summary, text
      assert_equal :original, source
    end

    test "a refusal leaves the summary exactly as it started" do
      request = create_request(original_locale: "de", details_original: "Zwei zusätzliche Handtücher")
      original_summary = request.summary
      @fake.script_refusal

      translate(request)

      assert_equal original_summary, request.reload.summary
      assert_equal "refusal", AiRun.order(:id).last.error_class
    end

    test "every attempt is accounted for, whatever the outcome" do
      request = create_request(original_locale: "de", details_original: "Zwei zusätzliche Handtücher")
      @fake.script_text("Dva peškira", input_tokens: 25, output_tokens: 8)

      translate(request)

      run_row = AiRun.order(:id).last
      assert_equal "translation", run_row.kind
      assert_equal "success", run_row.status
      assert_equal Rails.configuration.x.ai.translation_model, run_row.model
      assert_equal 25, run_row.input_tokens
      assert_equal request.conversation, run_row.conversation
      assert run_row.latency_ms.present?
    end

    # Translation shares ai_runs with the concierge and message translation
    # so that "what did AI cost this hotel today" is one query.
    test "translation spend counts towards the same daily total as the concierge and messages" do
      request = create_request(original_locale: "de", details_original: "Zwei zusätzliche Handtücher")
      @fake.script_text("Dva peškira", input_tokens: 25, output_tokens: 8)

      translate(request)

      assert_equal 33, AiRun.tokens_used_today(@hotel)
    end

    # --- Enqueueing --------------------------------------------------------

    test "confirming a request in a different language than the hotel's queues a translation" do
      @conversation.update!(guest_locale: "de")
      ready = draft(details: { "quantity" => "2", "description" => "towels" })

      assert_enqueued_with(job: Ai::TranslateServiceRequestSummaryJob) { ready.confirm! }
    end

    test "confirming a request already in the hotel's own language queues nothing" do
      @conversation.update!(guest_locale: "bs")
      ready = draft(details: { "quantity" => "2", "description" => "towels" })

      assert_no_enqueued_jobs(only: Ai::TranslateServiceRequestSummaryJob) { ready.confirm! }
    end

    private
      def translate(request)
        Ai::TranslateServiceRequestSummaryJob.perform_now(request, client: @fake)
      end

      def draft(details:)
        @conversation.service_request_drafts.create!(
          request_category: request_categories(:stari_towels), status: :awaiting_confirmation, details: details
        )
      end

      # A ServiceRequest built directly (not through ServiceRequestDraft, the
      # only path in the real app that creates one) so each test controls
      # `original_locale`/`details_original` independently — mirrors
      # test/models/service_request_test.rb's own create_request helper.
      def create_request(original_locale:, details_original:)
        category = request_categories(:stari_towels)
        details = { "quantity" => "2", "description" => "towels" }
        summary = details_original.presence || "Extra towels — quantity: 2"

        ServiceRequest.create!(
          hotel: @hotel, conversation: @conversation, guest_session: @conversation.guest_session,
          room: @conversation.guest_session.room, request_category: category, department: category.department,
          summary: summary, details: details, details_original: details_original, original_locale: original_locale,
          channel: :web,
          dedupe_key: SecureRandom.hex(16)
        )
      end
  end
end
