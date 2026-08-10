require "test_helper"

# A first hit on a controller/view in this process pays Zeitwerk autoloading and
# ERB compilation before the browser sees anything, so the very first assertion
# in a run can legitimately need more than Capybara's optimistic 2s default.
Capybara.default_max_wait_time = 5

# Chrome does not release the input grab taken by a native <select> popup when
# the page navigates away while that popup is still logically open. After
# `select` is followed by a form submit, every later click and keystroke in the
# browser session is silently dropped: fields stay empty, forms never submit,
# and the failure surfaces much later as an unrelated assertion — which reads
# as flakiness and is not.
#
# Verified on selenium-webdriver 4.46.0 / Chrome 151: `select` alone is
# harmless and a submit alone is harmless, but the pair poisons the session.
# In the poisoned state the field is present, displayed, unobscured and topmost
# at its own centre, and assigning its value from JavaScript still works — only
# real input is dropped, which is what makes it so hard to see. Moving focus off
# the select closes the popup and releases the grab.
module CloseNativeSelectPopup
  def select(value = nil, **options, &block)
    super.tap do
      page.execute_script("document.activeElement && document.activeElement.blur()")
    rescue Capybara::NotSupportedByDriverError, Selenium::WebDriver::Error::WebDriverError
      # Non-JS driver, or the page navigated as a side effect of selecting.
      nil
    end
  end
end

# A node Capybara has already found can be detached before it gets to ask
# whether the node is visible — the ordinary consequence of asserting on text
# while the page is still navigating, which every sign-in assertion here does
# (submit, 302, land on the next page). Capybara handles exactly this: it
# rescues the driver's `invalid_element_errors` while filtering candidate nodes
# and treats a vanished node as "doesn't match" (see
# Capybara::Queries::SelectorQuery#matches_filters?), so the query simply
# retries against the new document.
#
# That list contains StaleElementReferenceError. Chrome reports this same
# condition a second way — UnknownError carrying `Node with given id does not
# belong to the document` from the DevTools layer — which is not in the list, so
# the recovery never engages and the error surfaces as a failed assertion in
# whichever test lost the race. Measured at roughly 1 run in 12 here.
#
# Naming it makes Capybara's own recovery work for both spellings of the same
# condition. Capybara's list already carries entries of exactly this shape (an
# InvalidSelectorError for a chromedriver go_back/go_forward race, two
# IE-specific ones). Matching is deliberately narrow — this precise message on
# this precise class — so an unrelated UnknownError (`chrome not reachable`, a
# genuinely dead browser) still fails the test loudly instead of being retried
# into a timeout.
DetachedNodeError = Module.new do
  def self.===(error)
    error.is_a?(::Selenium::WebDriver::Error::UnknownError) &&
      error.message.include?("does not belong to the document")
  end
end

module RetryDetachedNodes
  def invalid_element_errors
    super + [ DetachedNodeError ]
  end
end

Capybara::Selenium::Driver.prepend(RetryDetachedNodes)

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Autofill and password-manager popups are native Chrome UI, so they take the
  # same input grab the <select> popup does and drop the keystrokes that follow.
  # There is no human here for them to help.
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |options|
    # TEMPORARY DIAGNOSTIC — remove with the rest of the experiment.
    options.add_option("goog:loggingPrefs", { browser: "ALL" })
    options.add_preference("autofill.profile_enabled", false)
    options.add_preference("autofill.credit_card_enabled", false)
    options.add_preference("credentials_enable_service", false)
    options.add_preference("profile.password_manager_enabled", false)
    # EXPERIMENT: every fixture signs in with "password123", which is one of
    # the most-breached passwords there is. Chrome's password leak check
    # fires on exactly that, after a successful sign-in submit, as native UI
    # — which is the one event that happens between the form submit that
    # works and the next click that does not. It needs a live call to
    # Google to decide, so it can only fire where the network is open.
    options.add_preference("profile.password_manager_leak_detection", false)
    options.add_argument("--password-store=basic")
    options.add_argument("--use-mock-keychain")
    options.add_argument(
      "--disable-features=AutofillServerCommunication,PasswordManagerOnboarding," \
      "PasswordLeakDetection,PasswordChangeAffiliationInfo,PasswordChange"
    )
  end

  prepend CloseNativeSelectPopup

  # Rails reuses one browser process for every system test in a run, so the
  # dropped-input state above outlives the test that caused it and resurfaces as
  # a failure in whichever unrelated test happens to run next — including on its
  # very first keystroke. Capybara's own reset only clears cookies and navigates
  # away; it does not clear this. Ending the browser between tests does, at a
  # cost of roughly a second per test, which is worth paying to stop chasing
  # failures into the test that did not cause them.
  teardown do
    Capybara.current_session.driver.quit if Capybara.current_session.driver.respond_to?(:quit)
  rescue StandardError
    nil
  end
end
