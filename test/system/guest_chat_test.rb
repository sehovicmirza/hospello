require "application_system_test_case"

# Each test sets up its own hotel/room/guest_session directly in Ruby and
# only drives the one behaviour under test through the browser — per the
# house rule on this suite's known Chrome "Element Click" flake (see
# .superpowers/sdd/slice-2-tasks/system-test-flake-diagnosis.md): short,
# single-purpose tests, preconditions set up directly rather than replayed
# through a second form.
class GuestChatTest < ApplicationSystemTestCase
  test "a guest sends a message and sees it in the transcript" do
    visit_chat_as_guest(locale: "en")

    fill_in "message_body", with: "Could I get an extra pillow, please?"
    find("#composer-send").click

    within "#chat-messages" do
      assert_text "Could I get an extra pillow, please?"
    end
  end

  test "a quick action prefills the composer without sending" do
    visit_chat_as_guest(locale: "en")

    assert_selector "#empty-state-greeting"
    find("#quick-action-0").click

    assert_equal "I have a question: ", find("#message_body").value
    assert_selector "#empty-state-greeting"
    assert_no_selector "#chat-messages [data-message-id]"
  end

  test "an over-long message shows an error" do
    visit_chat_as_guest(locale: "en")

    # maxlength on the textarea (good UX for real typing/pasting) would
    # otherwise stop Capybara's own fill_in from ever producing an
    # over-long value — setting it via JS is what actually gets an
    # over-length body to the server, the same way a body over 1000
    # characters could still arrive from a client this app doesn't
    # control end to end.
    page.execute_script(<<~JS)
      document.getElementById("message_body").value = "a".repeat(1001)
    JS
    find("#composer-send").click

    assert_text "Your message is too long. Please shorten it and try again."
    assert_no_selector "#chat-messages [data-message-id]"
  end

  # The database is the truth and the live broadcast is only ever an
  # enhancement on top of it (see Conversation#post_guest_message!/
  # #post_staff_message! and chat_resilience_controller.js) — a dropped
  # WebSocket must cost one poll interval, never a lost message.
  #
  # "Disable Action Cable" turned out to need real diagnosis, not the
  # first thing that looked plausible: Chrome DevTools Protocol's
  # Network.setBlockedURLs — the documented way to block requests by
  # pattern — does NOT block a WebSocket's own handshake in this Chrome
  # version (verified directly: blocking "*/cable*", "*cable*", even every
  # *ws* pattern tried left the connection reaching [connected] within
  # 1s; only blocking literally everything, urls: ["*"], which also takes
  # the whole page down with it, had any effect on it at all). Overriding
  # `window.WebSocket` itself — injected via Page.addScriptToEvaluateOnNewDocument
  # so it runs before any of the page's own scripts, including Action
  # Cable's own bundle — with a stub whose readyState never leaves
  # CONNECTING is what actually reproduces "the connection never
  # completes," proven by temporarily removing the visibilitychange
  # listener this test depends on and watching it fail (see
  # task-2-report.md for that run).
  #
  # Since the connection genuinely never completes, Turbo's own
  # visit-blocks-until-[connected] system test helper (which every other
  # test in this file benefits from, and which is why this app doesn't
  # disable it globally) would otherwise time this one test out for a
  # condition it's deliberately creating — stubbed out for this instance
  # only, which needs no teardown: Minitest gives every test its own
  # instance.
  test "a message posted by another session still appears via the polling fallback when Action Cable is down" do
    hotel = Hotel.create!(name: "System Test Hotel #{SecureRandom.hex(4)}", slug: "system-test-#{SecureRandom.hex(4)}")
    room = ActsAsTenant.with_tenant(hotel) { hotel.rooms.create!(number: "701") }
    staff = ActsAsTenant.with_tenant(hotel) do
      hotel.users.create!(email_address: "staff-#{SecureRandom.hex(4)}@example.com", password: "password123", name: "Front Desk", role: :staff)
    end
    raw_token = SecureRandom.urlsafe_base64(32)
    session = ActsAsTenant.with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "System Test Guest", room: room, locale: "en",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
        token_digest: GuestSession.digest(raw_token)
      )
    end

    visit hotel_landing_path(hotel.slug)
    page.driver.browser.manage.add_cookie(name: "hospello_guest", value: guest_signed_cookie_value(raw_token), path: "/")
    stub_websocket_that_never_connects!
    define_singleton_method(:connect_turbo_cable_stream_sources) { }

    visit guest_chat_path
    assert_no_selector "turbo-cable-stream-source[connected]"

    ActsAsTenant.with_tenant(hotel) do
      Conversation.live_for(session).post_staff_message!(user: staff, body: "Housekeeping is on its way up.")
    end
    page.execute_script('document.dispatchEvent(new Event("visibilitychange"))')

    assert_text "Housekeeping is on its way up."
  end

  private
    def visit_chat_as_guest(locale:)
      hotel = Hotel.create!(name: "System Test Hotel #{SecureRandom.hex(4)}", slug: "system-test-#{SecureRandom.hex(4)}")
      room = ActsAsTenant.with_tenant(hotel) { hotel.rooms.create!(number: "701") }
      raw_token = SecureRandom.urlsafe_base64(32)
      ActsAsTenant.with_tenant(hotel) do
        hotel.guest_sessions.create!(
          guest_name: "System Test Guest", room: room, locale: locale,
          privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
          token_digest: GuestSession.digest(raw_token)
        )
      end

      # A cookie can only be set for a domain the browser has already
      # loaded — this first visit exists purely to establish that domain
      # before injecting the signed cookie a real sign-up would have set
      # via Set-Cookie (same technique as test/system/guest_entry_test.rb).
      visit hotel_landing_path(hotel.slug)
      page.driver.browser.manage.add_cookie(name: "hospello_guest", value: guest_signed_cookie_value(raw_token), path: "/")

      visit guest_chat_path
    end

    def guest_signed_cookie_value(raw_token)
      jar = ActionDispatch::TestRequest.create.cookie_jar
      jar.signed[:hospello_guest] = raw_token
      jar[:hospello_guest]
    end

    # Page.addScriptToEvaluateOnNewDocument runs this before any script on
    # the *next* navigation gets a chance to run, so it replaces
    # window.WebSocket before Action Cable's own JS ever constructs one —
    # readyState stays 0 (CONNECTING) forever, open/close/error never
    # fire, the same observable shape a real stalled handshake has from
    # the page's point of view.
    def stub_websocket_that_never_connects!
      devtools = page.driver.browser.devtools
      devtools.send_cmd("Page.enable")
      devtools.send_cmd("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
        window.WebSocket = class {
          constructor(url) { this.url = url; this.readyState = 0 }
          close() {}
          send() {}
          addEventListener() {}
          removeEventListener() {}
        }
      JS
    end
end
