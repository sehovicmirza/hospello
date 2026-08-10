require "application_system_test_case"

# The demo this slice exists to make possible: a guest asks in German, gets a
# German answer built only from that hotel's own knowledge, and sees it appear
# on their phone without touching anything.
#
# The model is FakeClaude — the point of a browser test here is not what the
# model says (that is covered without a browser, and asserting on a real
# model's wording would be a coin flip). It is that the whole chain lines up:
# the guest's message persists, the job runs, the assistant's reply is written
# with the right visibility, the broadcast fires, and the guest's open page
# renders it. Those are five separate places this feature can break and
# nothing smaller than this catches all of them.
class AiConciergeTest < ApplicationSystemTestCase
  # Turbo's stream delivery makes a full round trip; still a bounded wait
  # rather than a sleep, so it returns the moment the text arrives.
  LIVE_WAIT = 15

  setup do
    @hotel = hotels(:stari_grad)
    @conversation = ActsAsTenant.with_tenant(@hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }
    @fake = FakeClaude.new
  end

  test "the assistant answers the guest live, in the guest's own language" do
    @fake.script_text("Das Frühstück wird von 07:00 bis 10:30 serviert.")

    open_guest_chat("stari-grad-fixture-guest-token")

    fill_in "message_body", with: "Wann gibt es Frühstück?"
    find("#composer-send").click
    within("#chat-messages") { assert_text "Wann gibt es Frühstück?" }

    run_the_concierge

    # Nothing is driven on this page between the send and here — the reply
    # arrives on its own, exactly as it would for a real guest.
    within("#chat-messages") do
      assert_text "Das Frühstück wird von 07:00 bis 10:30 serviert.", wait: LIVE_WAIT
    end

    # ...and it was built from this hotel's knowledge, not from thin air.
    assert_includes @fake.prompt_text, "Doručak se služi u restoranu Ćevabdžinica"
    assert_includes @fake.prompt_text, "<guest_message>Wann gibt es Frühstück?</guest_message>"
  end

  # The honest answer, which is the harder half of the product: the hotel
  # never wrote this down, so the guest is told so rather than told something
  # invented, and the gap is recorded for the hotel to fix.
  test "a question the hotel never answered is passed to reception, not guessed" do
    @fake
      .script_tool_call("log_unanswered_question", { "question" => "Is there a swimming pool?" })
      .script_text("Das habe ich nicht notiert — ich gebe die Frage an die Rezeption weiter.")

    open_guest_chat("stari-grad-fixture-guest-token")

    fill_in "message_body", with: "Gibt es einen Pool?"
    find("#composer-send").click
    within("#chat-messages") { assert_text "Gibt es einen Pool?" }

    run_the_concierge

    within("#chat-messages") { assert_text "an die Rezeption weiter", wait: LIVE_WAIT }

    ActsAsTenant.with_tenant(@hotel) do
      gap = @hotel.unanswered_questions.sole
      assert_equal "Is there a swimming pool?", gap.question
      assert gap.status_new?
    end
  end

  # The receptionist's override, and the reason it is re-checked at write
  # time: from the guest's side the chat simply carries on with a person on
  # the other end, with nothing announcing a handover they were never told
  # about in the first place.
  test "a paused conversation is answered by a person, and the assistant stays quiet" do
    ActsAsTenant.with_tenant(@hotel) { @conversation.pause_ai!(user: users(:stari_staff)) }

    open_guest_chat("stari-grad-fixture-guest-token")

    fill_in "message_body", with: "Kann ich später auschecken?"
    find("#composer-send").click
    within("#chat-messages") { assert_text "Kann ich später auschecken?" }

    run_the_concierge

    assert_equal 0, @fake.call_count, "a paused conversation must not reach the model at all"

    ActsAsTenant.with_tenant(@hotel) do
      @conversation.post_staff_message!(user: users(:stari_staff), body: "Ja, bis 14:00 Uhr.")
    end

    within("#chat-messages") { assert_text "Ja, bis 14:00 Uhr.", wait: LIVE_WAIT }
    assert_no_text "Hotel assistant"

    ActsAsTenant.with_tenant(@hotel) do
      assert_equal 0, @conversation.messages.where(sender_role: :assistant).count
      assert_equal 0, AiRun.count
    end
  end

  private
    # The browser enqueued the job for real; this performs it in the test
    # process with FakeClaude standing in for Anthropic. Deliberately not
    # `perform_enqueued_jobs` around the click: the assertion that matters is
    # that the reply arrives on a page nobody touched, which needs the send
    # and the reply to be separate moments.
    def run_the_concierge
      Ai::GenerateReplyJob.perform_now(@conversation, client: @fake)
    end

    def open_guest_chat(raw_token)
      # A cookie can only be set for a domain the browser has already loaded,
      # so this first visit exists purely to establish it before injecting the
      # signed cookie a real sign-up would have set via Set-Cookie (same
      # technique as test/system/guest_staff_live_test.rb).
      visit hotel_landing_path(@hotel.slug)

      jar = ActionDispatch::TestRequest.create.cookie_jar
      jar.signed[:hospello_guest] = raw_token
      page.driver.browser.manage.add_cookie(name: "hospello_guest", value: jar[:hospello_guest], path: "/")

      visit guest_chat_path
      # visible: :all — <turbo-cable-stream-source> is an empty custom element
      # with no box, so Capybara's default visibility filter never matches it
      # however connected it is. Waiting for it here is what makes "the reply
      # arrived on its own" a real claim rather than a lucky reload.
      assert_selector "turbo-cable-stream-source[connected]", visible: :all, wait: LIVE_WAIT
    end
end
