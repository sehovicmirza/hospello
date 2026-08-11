require "test_helper"

module Ai
  # A message stuck mid-translation shows its reader "translating…" forever.
  # That is worse than showing them the original, because they are waiting for
  # something that is not coming — and the one thing this product must never
  # do is leave someone at a dead end.
  class TranslationWatchdogJobTest < ActiveJob::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      @conversation = with_tenant(@hotel) { conversations(:stari_conversation) }
    end

    # The number itself, pinned. Every other test here is relative to the
    # constant and would stay green if someone widened it to an hour — at
    # which point a reader stares at "translating…" for an hour. Fifteen
    # seconds is a product decision about how long someone is asked to wait,
    # not an implementation detail.
    test "the budget is fifteen seconds" do
      assert_equal 15.seconds, Ai::TranslationWatchdogJob::BUDGET
    end

    test "a translation that never came back is settled on the original" do
      message = message_awaiting(:translating, age: Ai::TranslationWatchdogJob::BUDGET + 1.second)

      Ai::TranslationWatchdogJob.perform_now

      assert with_tenant(@hotel) { message.reload.translation_status_failed? }
    end

    # Claimed-but-never-started and never-claimed-at-all are the same problem
    # from the reader's side: a bubble that is not going to resolve.
    test "one that was queued and never picked up is settled too" do
      message = message_awaiting(:pending, age: Ai::TranslationWatchdogJob::BUDGET + 1.second)

      Ai::TranslationWatchdogJob.perform_now

      assert with_tenant(@hotel) { message.reload.translation_status_failed? }
    end

    test "a translation still inside its budget is left alone" do
      message = message_awaiting(:translating, age: 2.seconds)

      Ai::TranslationWatchdogJob.perform_now

      assert with_tenant(@hotel) { message.reload.translation_status_translating? }
    end

    test "a finished translation is never touched" do
      message = with_tenant(@hotel) do
        @conversation.messages.create!(
          hotel: @hotel, sender_role: :guest, body: "Wann gibt es Frühstück?", body_locale: "de",
          translated_body: "Kada je doručak?", translated_locale: "bs", translation_status: :translated
        )
      end
      with_tenant(@hotel) { message.update_column(:updated_at, 1.hour.ago) }

      Ai::TranslationWatchdogJob.perform_now

      with_tenant(@hotel) do
        assert message.reload.translation_status_translated?
        assert_equal "Kada je doručak?", message.translated_body
      end
    end

    # The original always survives. Settling a translation is a decision about
    # what to show, never a change to what was said.
    test "settling never touches what the guest actually wrote" do
      message = message_awaiting(:translating, age: 1.minute)

      Ai::TranslationWatchdogJob.perform_now

      assert_equal "Wann gibt es Frühstück?", with_tenant(@hotel) { message.reload.body }
    end

    test "every hotel is swept, not just whichever happened to be current" do
      mine = message_awaiting(:translating, age: 1.minute)
      theirs = with_tenant(hotels(:vrelo)) do
        conversations(:vrelo_conversation).messages.create!(
          hotel: hotels(:vrelo), sender_role: :guest, body: "Wann gibt es Frühstück?", body_locale: "de",
          translation_status: :translating
        ).tap { |message| message.update_column(:updated_at, 1.minute.ago) }
      end

      Ai::TranslationWatchdogJob.perform_now

      assert with_tenant(@hotel) { mine.reload.translation_status_failed? }
      assert with_tenant(hotels(:vrelo)) { theirs.reload.translation_status_failed? }
    end

    private

    def message_awaiting(status, age:)
      with_tenant(@hotel) do
        message = @conversation.messages.create!(
          hotel: @hotel, sender_role: :guest, body: "Wann gibt es Frühstück?", body_locale: "de",
          translation_status: status
        )
        # update_column so the timestamp is not immediately overwritten by the
        # very touch that would make the row look fresh again.
        message.update_column(:updated_at, age.ago)
        message
      end
    end
  end
end
