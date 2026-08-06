require "test_helper"

# Capybara's 2s default wait can be shorter than a first, uncompiled render of
# a new controller/view in this process (Zeitwerk autoload + ERB compilation
# happen lazily, on first hit) plus real browser round-trips — that reads as
# test flakiness but is really just an optimistic timeout. On a loaded machine
# (measured: a clean run completes in ~2s, a contended one in ~6-7s) 5s was
# still occasionally too tight; 10s gives real headroom without letting a
# genuinely broken assertion hang for long.
Capybara.default_max_wait_time = 10

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Chrome's autofill/password-manager UI can pop a suggestion overlay over a
  # form that resembles one filled in earlier in the same test run (this suite
  # fills near-identical "new hotel"/"new admin" forms more than once per
  # test) and swallow the next click. Off entirely — there is no human here
  # for it to help.
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |driver_option|
    driver_option.add_preference("autofill.profile_enabled", false)
    driver_option.add_preference("autofill.credit_card_enabled", false)
    driver_option.add_preference("credentials_enable_service", false)
    driver_option.add_preference("profile.password_manager_enabled", false)
  end
end
