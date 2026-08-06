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

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include TenantTestHelper

    # Leave every test in a known tenant state: a leaked tenant from one test
    # would mask a missing tenant in the next.
    teardown do
      ActsAsTenant.current_tenant = nil
      ActsAsTenant.test_tenant = nil
    end
  end
end
