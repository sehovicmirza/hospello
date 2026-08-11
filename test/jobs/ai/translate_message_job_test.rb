require "test_helper"

module Ai
  # Translation as an overlay: the message is already on both surfaces by the
  # time this runs, and what this job adds is the ability to read it. So every
  # test here asks the same two questions — did the original survive, and did
  # the hotel pay for it exactly once?
  class TranslateMessageJobTest < ActiveJob::TestCase
    setup do
      @hotel = hotels(:stari_grad)          # staff_locale: bs
      ActsAsTenant.current_tenant = @hotel
      @conversation = conversations(:stari_conversation) # guest_locale: bs
      @fake = FakeClaude.new
    end

    test "a guest message is translated into the hotel's staff language" do
      # The two locales have to differ for this to mean anything: with a
      # German-speaking guest at a Bosnian-speaking hotel, translating into
      # the *guest's* language instead would be a visible bug. The fixtures
      # have both as "bs", which would make either direction look correct.
      @conversation.update!(guest_locale: "de")
      message = guest_message("Wann gibt es Frühstück?", locale: "de")
      @fake.script_text("Kada je doručak?", input_tokens: 30, output_tokens: 9)

      translate(message)

      message.reload
      assert_equal "Kada je doručak?", message.translated_body
      assert_equal "bs", message.translated_locale
      assert message.translation_status_translated?
      assert_equal "Wann gibt es Frühstück?", message.body, "the original is what was said and never changes"
    end

    test "a staff reply is translated into the guest's language" do
      @conversation.update!(guest_locale: "ar")
      message = staff_message("Doručak je od 07:00.")
      @fake.script_text("الإفطار من الساعة 07:00.")

      translate(message)

      assert_equal "ar", message.reload.translated_locale
      assert message.translation_status_translated?
    end

    test "a message whose reader already shares the language is never sent anywhere" do
      message = guest_message("Kada je doručak?", locale: "bs")

      translate(message)

      assert_equal 0, @fake.call_count
      assert_nil message.reload.translated_body
    end

    # --- Paying for it exactly once ------------------------------------------

    # A duplicate enqueue, a retry after a crash, the watchdog and the job
    # racing — all of them arrive here, and the claim is what makes only one
    # of them cost anything.
    test "a message is only ever translated once, however many times the job runs" do
      message = guest_message("Wann gibt es Frühstück?", locale: "de")
      @fake.script_text("Kada je doručak?")

      translate(message)
      translate(message) # would raise FakeClaude::UnscriptedCall if it called the model again

      assert_equal 1, @fake.call_count
      assert_equal 1, AiRun.where(kind: :translation).count
    end

    test "a message already settled by the watchdog is left alone" do
      message = guest_message("Wann gibt es Frühstück?", locale: "de")
      message.update!(translation_status: :failed)

      translate(message)

      assert_equal 0, @fake.call_count
    end

    # --- When it does not work -------------------------------------------------

    test "a timeout leaves the original readable and says the translation failed" do
      message = guest_message("Wann gibt es Frühstück?", locale: "de")
      @fake.script_timeout

      translate(message)

      message.reload
      assert message.translation_status_failed?
      assert_equal "Wann gibt es Frühstück?", message.translated_body,
                   "the fallback is the original, so a reader is never left with nothing"
      assert_equal "timeout", AiRun.order(:id).last.error_class
    end

    # The whole reason the digit guard exists, seen from the outside: a
    # receptionist reads the guest's own words rather than a confident wrong
    # room number.
    test "a translation that changed a number is thrown away, and the run says why" do
      message = guest_message("Room 305 please", locale: "en")
      @fake.script_text("Soba 350 molim")

      translate(message)

      message.reload
      assert message.translation_status_failed?
      assert_equal "Room 305 please", message.translated_body
      assert_equal "digit_mismatch", AiRun.order(:id).last.error_class
    end

    test "every attempt is accounted for, whatever the outcome" do
      message = guest_message("Wann gibt es Frühstück?", locale: "de")
      @fake.script_text("Kada je doručak?", input_tokens: 30, output_tokens: 9)

      translate(message)

      run_row = AiRun.order(:id).last
      assert_equal "translation", run_row.kind
      assert_equal "success", run_row.status
      assert_equal Rails.configuration.x.ai.translation_model, run_row.model
      assert_equal 30, run_row.input_tokens
      assert_equal message.id, run_row.message_id
      assert run_row.latency_ms.present?
    end

    # Translation and the concierge share ai_runs so that "what did AI cost
    # this hotel" is one query — and so a hotel whose translation is quietly
    # failing all day is visible in the same place its concierge is.
    test "translation spend counts towards the same daily total as the concierge" do
      message = guest_message("Wann gibt es Frühstück?", locale: "de")
      @fake.script_text("Kada je doručak?", input_tokens: 30, output_tokens: 9)

      translate(message)

      assert_equal 39, AiRun.tokens_used_today(@hotel)
    end

    # --- Enqueueing ------------------------------------------------------------

    test "posting a guest message in another language queues a translation" do
      @conversation.update!(guest_locale: "de")

      assert_enqueued_with(job: Ai::TranslateMessageJob) do
        @conversation.post_guest_message!(body: "Wann gibt es Frühstück?", client_message_id: SecureRandom.uuid)
      end
    end

    test "posting one in the staff's own language queues nothing" do
      assert_no_enqueued_jobs(only: Ai::TranslateMessageJob) do
        @conversation.post_guest_message!(body: "Kada je doručak?", client_message_id: SecureRandom.uuid)
      end
    end

    # --- Assistant replies, translated lazily -------------------------------------

    test "an assistant reply is not translated when it is written" do
      @conversation.update!(guest_locale: "de")

      assert_no_enqueued_jobs(only: Ai::TranslateMessageJob) do
        @conversation.post_assistant_reply!(body: "Das Frühstück ist um 07:00.")
      end
    end

    # The concierge already answered in the guest's language, so the
    # staff-facing translation is worth paying for exactly when a receptionist
    # is reading it — and not on the many conversations nobody opens.
    test "it is translated the first time a receptionist opens the conversation" do
      @conversation.update!(guest_locale: "de")
      @conversation.post_assistant_reply!(body: "Das Frühstück ist um 07:00.")

      assert_enqueued_with(job: Ai::TranslateMessageJob) { @conversation.request_staff_translations! }
    end

    test "opening it again does not queue the same translation twice" do
      @conversation.update!(guest_locale: "de")
      @conversation.post_assistant_reply!(body: "Das Frühstück ist um 07:00.")
      @conversation.request_staff_translations!

      assert_no_enqueued_jobs(only: Ai::TranslateMessageJob) { @conversation.request_staff_translations! }
    end

    test "an assistant reply already in the staff's language is left alone" do
      @conversation.post_assistant_reply!(body: "Doručak je u 07:00.")

      assert_no_enqueued_jobs(only: Ai::TranslateMessageJob) { @conversation.request_staff_translations! }
    end

    test "a staff reply is stamped with the language it was written in" do
      @conversation.update!(guest_locale: "ar")

      message = @conversation.post_staff_message!(user: users(:stari_staff), body: "Doručak je od 07:00.")

      assert_equal @hotel.staff_locale, message.body_locale,
                   "without this the translator is asked to translate from an unknown language"
      assert message.translation_status_pending?
    end

    private

    def translate(message)
      Ai::TranslateMessageJob.perform_now(message, client: @fake)
    end

    def guest_message(body, locale:)
      @conversation.messages.create!(
        hotel: @hotel, sender_role: :guest, body: body, body_locale: locale, translation_status: :pending
      )
    end

    def staff_message(body)
      @conversation.messages.create!(
        hotel: @hotel, sender_role: :staff, sender_user: users(:stari_staff), body: body,
        body_locale: @hotel.staff_locale, translation_status: :pending
      )
    end
  end
end
