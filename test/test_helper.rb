ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

# No test may reach the network. Localhost stays open for the system-test driver.
WebMock.disable_net_connect!(allow_localhost: true)

# acts_as_tenant runs with require_tenant = true, so any query touching a
# tenant-scoped model has to name the hotel it is for. Non-tenant models
# (Hotel, User, Session, AuditLog) are unaffected and need no block.
module TenantTestHelper
  def with_tenant(hotel, &block) = ActsAsTenant.with_tenant(hotel, &block)
end

# Signs a user in for controller/integration tests by writing the signed
# session cookie directly, the same artifact Authentication#resume_session
# reads back. This bypasses SessionsController (and its login rate limit)
# so a test failure here means the base controllers changed, not that this
# helper hit a throttle or a bcrypt cost.
module SignInTestHelper
  def sign_in(user)
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_token] = user.sessions.create!.token
    cookies[:session_token] = jar[:session_token]
  end
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include TenantTestHelper
    include SignInTestHelper

    # Leave every test in a known tenant state: a leaked tenant from one test
    # would mask a missing tenant in the next.
    teardown do
      ActsAsTenant.current_tenant = nil
      ActsAsTenant.test_tenant = nil
    end
  end
end
