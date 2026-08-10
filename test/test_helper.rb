require "fileutils"

# Propshaft's compiled-assets manifest under public/assets (gitignored) can
# outlive the source files that produced it: anyone who has ever run `rails
# assets:precompile` locally (testing bin/render-build.sh, deploying by
# hand) leaves one behind. When it's present, ActionDispatch::Static serves
# those stale digested files straight off disk without ever asking
# Propshaft to recompile — so a source CSS/JS change has silently zero
# effect until someone thinks to delete the directory by hand. A stale
# public/assets/tailwind-*.css already produced exactly this false result
# once, during an earlier task's fix round: a system test asserting on
# rendered CSS silently read pre-app CSS and passed anyway. Clearing it
# before every run makes that failure mode structurally impossible instead
# of a note nobody rereads — bin/setup clears it the same way for local dev,
# belt and braces.
FileUtils.rm_rf(File.expand_path("../public/assets", __dir__))

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

# No test may reach the network. Localhost stays open for the system-test driver.
WebMock.disable_net_connect!(allow_localhost: true)

# Test doubles and helpers that are not tests themselves. Loaded eagerly rather
# than required per file so that a helper is never accidentally half-loaded in
# one worker and absent in another (fixtures :all plus parallel workers make
# that failure mode genuinely hard to read).
Dir[Rails.root.join("test/support/**/*.rb")].each { |file| require file }

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

# Signs a guest in for controller/integration/system tests by writing the
# signed `hospello_guest` cookie directly — the same artifact
# Guest::BaseController reads back via GuestSession.authenticate_by_token.
# Pass the *raw* token (not its digest): fixtures/guest_sessions.yml
# documents the raw token each fixture session was created with, and
# Guest::EntriesController#create generates a fresh one per real signup.
module GuestSignInTestHelper
  def sign_in_guest(raw_token)
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:hospello_guest] = raw_token
    cookies[:hospello_guest] = jar[:hospello_guest]
  end

  # ActionDispatch::IntegrationTest#cookies (unlike ActionController::TestCase's)
  # returns a plain Rack::Test::CookieJar with no `.signed` reader — it only
  # ever sees the raw encoded value a controller's `cookies.signed[...] = `
  # produced. Round-tripping that raw value through a fresh, throwaway
  # ActionDispatch::Cookies::CookieJar (built the same way
  # #sign_in_guest above writes one) verifies and decodes it back to the
  # original raw token, the same way a real request handler would.
  def read_signed_cookie(name)
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar[name] = cookies[name]
    jar.signed[name]
  end
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Found investigating an intermittent (roughly 1-in-15-run) failure in
    # the guest locale tests: I18n::Backend::Simple loads translation files
    # lazily, on the first lookup, in whichever worker process happens to
    # hit it first — and that lazy load is not what fully guarantees every
    # locale is loaded before a request depending on it runs. Diagnostic
    # evidence from a captured failure showed a forked worker whose backend
    # had only ever loaded :en (`I18n.backend.send(:translations).keys` was
    # `[:en]`), even though `I18n.available_locales` was correctly
    # `[:bs, :en, :de, :ar]` and even a *direct* `I18n.t(key, locale: :bs)`
    # call — nowhere near this app's own with_locale scoping — returned the
    # English fallback. That points at I18n's own lazy-load path racing
    # fork, not at anything guest-controller-specific.
    # `I18n.backend.eager_load!` forces every locale file in
    # I18n.load_path to load immediately, once per freshly-forked worker,
    # before that worker runs any of its assigned tests — turning a rare,
    # order-independent, unreproducible-with-a-fixed-seed flake (confirmed:
    # 7/7 clean serial runs, ~1-in-15 parallel runs failing) into something
    # that can't happen at all.
    parallelize_setup do |_worker|
      I18n.backend.eager_load!
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include TenantTestHelper
    include SignInTestHelper
    include GuestSignInTestHelper

    # Leave every test in a known tenant state: a leaked tenant from one test
    # would mask a missing tenant in the next.
    teardown do
      ActsAsTenant.current_tenant = nil
      ActsAsTenant.test_tenant = nil
    end
  end
end
