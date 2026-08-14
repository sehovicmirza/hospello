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
