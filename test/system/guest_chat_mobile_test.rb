require "application_system_test_case"

# The guest chat is opened by scanning a QR code in a hotel room, so it is
# always a phone. Every invariant below was broken in production and none of
# them was visible on a desktop browser, which is exactly why they need a test
# at phone size rather than a look.
#
# Measured on an emulated iPhone before the fix: with seven messages the
# composer sat 412px below the fold — a guest had to scroll down to find the
# box they were trying to type in, having just been thrown there by iOS zooming
# the page on a 14px input. That is the "focus gets lost and I have to scroll
# back" this page was reported for.
#
# Window resize rather than a second driver config: every invariant here is a
# consequence of viewport height and CSS, not of touch or pixel ratio, so the
# cheaper setup tests the same thing. The one exception is noted inline.
class GuestChatMobileTest < ApplicationSystemTestCase
  # iPhone 14/15 CSS pixels. Anything narrower is rare enough that a hotel
  # would hear about it; anything wider only makes these assertions easier.
  PHONE = [ 390, 844 ].freeze

  test "the composer stays on screen once the conversation is longer than the phone" do
    visit_chat_on_phone

    8.times { |i| send_message("Poruka #{i + 1} — pitanje o doručku, spa centru i transferu.") }

    assert composer_fully_visible?,
      "the composer left the screen: a guest with a real conversation would have to " \
      "scroll to find the box they are typing into"
  end

  # The transcript scrolls; the page does not. A fixed-height shell inside a
  # body that can still grow leaves the whole document draggable behind the
  # composer, which reads as the screen coming loose.
  test "the transcript scrolls, and the page behind it does not" do
    visit_chat_on_phone

    8.times { |i| send_message("Poruka #{i + 1} — pitanje o doručku, spa centru i transferu.") }

    assert_equal 0, attempted_page_scroll_offset,
      "the page scrolled behind the chat; only #chat-messages should scroll"
    assert page.evaluate_script("(() => { const m = document.getElementById('chat-messages'); " \
                                "return m.scrollHeight > m.clientHeight + 1 })()"),
      "the transcript is not the scroller, so its content is overflowing somewhere else"
  end

  # The dots have to be *on screen*, which is a different question from being
  # last in the DOM.
  #
  # chat_scroll_controller only follows new content when the transcript is
  # already within NEAR_BOTTOM_PX (48) of the bottom. That is right for a
  # message arriving while a guest rereads something earlier, and wrong the
  # moment the guest's own message is taller than 48px: the append leaves the
  # transcript further than the threshold from the bottom, the auto-scroll
  # declines, and the one element that says an answer is coming sits below the
  # fold. The transcript has to be full first or there is nothing to scroll and
  # the test proves nothing.
  test "the typing dots are on screen after sending, without scrolling" do
    visit_chat_on_phone

    8.times { |i| send_message("Poruka #{i + 1} — pitanje o doručku, spa centru i transferu.") }
    send_message("Dobar dan, ovdje smo s porodicom cijelu sedmicu i zanima nas šta ima " \
                 "u blizini, posebno nešto što odgovara djeci koja se brzo dosade u muzejima.")

    assert_selector "#typing-indicator", visible: true
    assert typing_dots_on_screen?,
      "the guest had to scroll to find the dots that tell them a reply is coming"
  end

  # The reply itself has to land on screen, not just the dots.
  #
  # Reported from a real phone: the guest sits watching the typing indicator,
  # the answer arrives, and half of it is behind the composer. The cause is
  # subtle — chat_scroll_controller asked "is the transcript near the bottom?"
  # from inside a MutationObserver callback, which runs *after* the DOM
  # changed, so it measured the distance with the new message already in place.
  # A reply taller than NEAR_BOTTOM_PX therefore looked exactly like a guest who
  # had scrolled away to reread something, and the scroll was declined.
  #
  # The reply below is deliberately long, because a short one hides the bug.
  test "a long reply lands on screen for a guest who was waiting at the bottom" do
    visit_chat_on_phone

    6.times { |i| send_message("Poruka #{i + 1} — pitanje o doručku i spa centru.") }

    long_reply = "Doručak se služi od 07:00 do 10:30 u restoranu na prvom spratu. " \
                 "Nudimo topli i hladni bife, domaće proizvode, svježe pecivo i lokalni med. " \
                 "Za goste koji ranije putuju možemo pripremiti paket za ponijeti, " \
                 "samo javite recepciji dan ranije. Spa centar radi od 10:00 do 22:00."
    post_reply(long_reply)

    assert_selector "#chat-messages", text: long_reply.truncate(30, omission: "")
    assert last_message_fully_visible?,
      "the guest had to scroll to read a reply they were sitting and waiting for"
  end

  # The other half of "the transcript is the scroller": a guest who scrolled up
  # to reread something must stay there when a new message arrives. This is the
  # behaviour chat_scroll_controller.js's NEAR_BOTTOM_PX exists for, and it was
  # never tested — easy to lose while changing which element scrolls, and the
  # symptom (being yanked to the bottom mid-sentence) reads as exactly the
  # flakiness this page was reported for.
  test "a guest who scrolled up to reread is not yanked back down" do
    visit_chat_on_phone

    8.times { |i| send_message("Poruka #{i + 1} — pitanje o doručku, spa centru i transferu.") }

    page.execute_script("document.getElementById('chat-messages').scrollTop = 0")
    assert_equal 0, transcript_scroll_top

    # A message arriving from anywhere other than this guest's own composer:
    # the live broadcast and the resilience resync both append here too.
    page.execute_script(<<~JS)
      const list = document.getElementById('chat-messages');
      const p = document.createElement('p');
      p.textContent = 'Poruka koja stiže dok gost čita ranije poruke.';
      list.appendChild(p);
    JS
    sleep 0.3

    assert_equal 0, transcript_scroll_top,
      "a new message dragged the guest back to the bottom while they were reading"
  end

  # Sending is not the same as receiving, and the rule flips.
  #
  # A guest who has scrolled up to reread something must not be dragged down by
  # a message *arriving* — that is the test above. But if they then type and
  # press send, they have asked to rejoin the conversation, and leaving their
  # own message off screen is the "where did it go" that made this chat feel
  # broken. chat_scroll_controller cannot tell these apart: it sees two appends.
  test "a guest who scrolled up and then sends is taken back to their own message" do
    visit_chat_on_phone

    8.times { |i| send_message("Poruka #{i + 1} — pitanje o doručku, spa centru i transferu.") }

    page.execute_script("document.getElementById('chat-messages').scrollTop = 0")
    assert_equal 0, transcript_scroll_top

    send_message("Još jedno pitanje, molim vas.")

    assert last_message_fully_visible?,
      "the guest pressed send and could not see the message they had just sent"
  end

  # iOS Safari zooms the whole page in when a focused field is under 16px and
  # never zooms back out. That is a font-size rule, not a preference: the page
  # was at 14px and every tap on the composer threw the guest's place away.
  test "the composer's input is large enough that iOS will not zoom the page" do
    visit_chat_on_phone

    font_px = page.evaluate_script(
      "parseFloat(getComputedStyle(document.querySelector('#composer textarea')).fontSize)"
    )

    assert_operator font_px, :>=, 16,
      "iOS zooms the page on focus below 16px, which is what loses the guest's place"
  end

  # 44px is the smallest target a thumb hits reliably, and the quick actions
  # are the first thing a guest touches. They were 34px.
  test "the quick actions are big enough to hit with a thumb" do
    visit_chat_on_phone

    height = page.evaluate_script(
      "Math.round(document.getElementById('quick-action-0').getBoundingClientRect().height)"
    )

    assert_operator height, :>=, 44
  end

  # A hotel configures its own request categories, so this row's length is not
  # something the page can predict. Wrapped chips grew to three or four rows on
  # a narrow phone and pushed the composer off the bottom; one scrolling row
  # costs the same vertical space whatever a hotel has set up.
  test "many quick actions do not push the composer off the screen" do
    hotel = phone_hotel
    ActsAsTenant.with_tenant(hotel) do
      department = hotel.departments.create!(name: "Usluge", position: 1)
      10.times do |i|
        hotel.request_categories.create!(
          department: department, key: "extra_#{i}", name: "Dodatna kategorija broj #{i}",
          detail_fields: %w[description], position: i + 10
        )
      end
    end

    visit_chat_on_phone(hotel: hotel)

    assert_selector "#quick-action-9", visible: :all
    assert composer_fully_visible?,
      "a hotel with a long category list pushed the composer off the screen"
  end

  private
    def visit_chat_on_phone(hotel: nil)
      hotel ||= phone_hotel
      room = ActsAsTenant.with_tenant(hotel) { hotel.rooms.first || hotel.rooms.create!(number: "701") }
      raw_token = SecureRandom.urlsafe_base64(32)
      ActsAsTenant.with_tenant(hotel) do
        hotel.guest_sessions.create!(
          guest_name: "Mobile Test Guest", room: room, locale: "bs",
          privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
          token_digest: GuestSession.digest(raw_token)
        )
      end

      page.current_window.resize_to(*PHONE)
      visit hotel_landing_path(hotel.slug)
      page.driver.browser.manage.add_cookie(
        name: "hospello_guest", value: guest_signed_cookie_value(raw_token), path: "/"
      )
      visit guest_chat_path
      assert_selector "#composer"
    end

    def phone_hotel
      @phone_hotel ||= begin
        hotel = Hotel.create!(name: "Mobile Test Hotel #{SecureRandom.hex(4)}",
                              slug: "mobile-test-#{SecureRandom.hex(4)}")
        ActsAsTenant.with_tenant(hotel) do
          hotel.rooms.create!(number: "701")
          department = hotel.departments.create!(name: "Recepcija", position: 0)
          hotel.request_categories.create!(department: department, key: "towels", name: "Peškiri",
                                           detail_fields: %w[quantity], position: 0)
        end
        hotel
      end
    end

    def send_message(body)
      fill_in "message_body", with: body
      find("#composer-send").click
      assert_selector "#chat-messages", text: body.truncate(20, omission: "")
    end

    # Delivered the way a real reply is — through the model, so it goes out over
    # the same broadcast the assistant's answers use — then nudged, because a
    # headless tab does not always process the cable promptly.
    def post_reply(body)
      hotel = phone_hotel
      staff = hotel.users.find_by(role: :staff) || hotel.users.first
      ActsAsTenant.with_tenant(hotel) do
        Conversation.live_for(hotel.guest_sessions.order(:id).last).post_staff_message!(user: staff, body: body)
      end
      page.execute_script('document.dispatchEvent(new Event("visibilitychange"))')
    end

    def last_message_fully_visible?
      page.evaluate_script(<<~JS)
        (() => {
          const list = document.getElementById('chat-messages')
          const msgs = list.querySelectorAll('[data-message-id]')
          const last = msgs[msgs.length - 1]
          if (!last) return false
          const l = list.getBoundingClientRect(), m = last.getBoundingClientRect()
          return m.bottom <= l.bottom + 1
        })()
      JS
    end

    def typing_dots_on_screen?
      page.evaluate_script(<<~JS)
        (() => {
          const list = document.getElementById('chat-messages')
          const dots = document.getElementById('typing-indicator')
          const l = list.getBoundingClientRect(), d = dots.getBoundingClientRect()
          return d.top >= l.top - 1 && d.bottom <= l.bottom + 1
        })()
      JS
    end

    def transcript_scroll_top
      page.evaluate_script("Math.round(document.getElementById('chat-messages').scrollTop)")
    end

    def composer_fully_visible?
      page.evaluate_script(
        "(() => { const c = document.getElementById('composer').getBoundingClientRect(); " \
        "return c.bottom <= window.innerHeight + 1 && c.top >= 0 })()"
      )
    end

    # Asks the browser to scroll as far as it can and reports where it landed.
    # A pinned shell reports 0; a document that still grows behind the chat
    # reports whatever it managed.
    #
    # This is deliberately a *programmatic* scroll, and that is what makes it a
    # strict test rather than a lenient one. `overflow: hidden` propagates to
    # the viewport and stops a finger from dragging the page, but it does not
    # stop `scrollTo` — nor the scrolls the browser itself performs to bring a
    # focused field into view, which is the exact mechanism this whole page was
    # reported for. So a non-zero answer here means the document genuinely has
    # scrollable overflow behind the chat, whether or not a drag can reach it.
    # It caught 20px of it that `overflow: hidden` alone was hiding: the
    # `.sr-only` sender label on each bubble is `position: absolute`, so until
    # the body became its containing block it was clipped by nothing.
    def attempted_page_scroll_offset
      page.evaluate_script(
        "(() => { window.scrollTo(0, 5000); const y = Math.round(window.scrollY); " \
        "window.scrollTo(0, 0); return y })()"
      )
    end

    # Same technique as test/system/guest_chat_test.rb: mint the signed cookie
    # a real sign-up would have set, rather than replaying the entry form
    # through the browser for every test.
    def guest_signed_cookie_value(raw_token)
      jar = ActionDispatch::TestRequest.create.cookie_jar
      jar.signed[:hospello_guest] = raw_token
      jar[:hospello_guest]
    end
end
