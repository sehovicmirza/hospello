require "application_system_test_case"

# Guards the browser harness itself. Everything here is about
# test/application_system_test_case.rb being wired up the way its comments
# claim — a silent regression there does not fail loudly, it comes back as
# flakiness in whichever unrelated test loses a race, which is exactly the
# kind of failure this project has already spent days chasing twice.
#
# Deliberately not an ApplicationSystemTestCase: none of this needs a browser.
# Capybara::Selenium::Driver only launches Chrome when something asks it for
# #browser, and #invalid_element_errors never does.
class SystemHarnessTest < ActiveSupport::TestCase
  setup { @driver = Capybara::Selenium::Driver.new(nil) }

  test "Capybara retries the Chrome spelling of a detached node" do
    stale = Selenium::WebDriver::Error::UnknownError.new(
      %q(unhandled inspector error: {"code":-32000,"message":"Node with given id does not belong to the document"})
    )

    assert @driver.invalid_element_errors.any? { |error| error === stale },
      "Capybara will not retry Chrome's detached-node error, so a node that " \
      "vanishes mid-navigation fails the assertion that was looking at it"
  end

  # The other half: this must stay narrow. Retrying a genuinely dead browser
  # turns a clear one-line error into a Capybara timeout somewhere unrelated.
  test "an unrelated UnknownError is still fatal" do
    dead = Selenium::WebDriver::Error::UnknownError.new("chrome not reachable")

    assert_not @driver.invalid_element_errors.any? { |error| error === dead },
      "an unrelated UnknownError is being swallowed and retried"
  end
end
