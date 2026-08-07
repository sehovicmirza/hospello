require "test_helper"

# Mission Control – Jobs must be reachable only by a signed-in platform_admin
# — our session auth is the gate, not the gem's own HTTP Basic Auth (which
# is disabled: config/initializers/mission_control_jobs.rb). These are the
# tests that would fail if that wiring ever regressed — base_controller_class
# pointed somewhere else, or http_basic_auth_enabled flipped back to true
# with no credentials configured (which would 401 everyone, including a
# legitimate platform admin, rather than protect the dashboard further).
class MissionControlGateTest < ActionDispatch::IntegrationTest
  test "a signed-in platform admin can reach the jobs dashboard" do
    sign_in(users(:platform))

    get "/platform/jobs"

    assert_response :success
  end

  test "an unauthenticated visitor is redirected to sign in, not shown the dashboard" do
    get "/platform/jobs"

    # Not the bare `new_session_path` helper: after visiting a route inside
    # the mounted (isolated) Mission Control engine, this integration
    # session resolves bare route helpers against *that* engine's routes —
    # the same default_url_options sharp edge Authentication#request_authentication
    # itself had to route around. Rails.application.routes.url_helpers is
    # the main app's route set, unambiguous regardless of what was visited last.
    assert_redirected_to Rails.application.routes.url_helpers.new_session_path
  end

  test "a signed-in hotel admin is forbidden, not shown the dashboard" do
    sign_in(users(:stari_admin))

    get "/platform/jobs"

    assert_response :forbidden
  end

  test "a signed-in staff member is forbidden, not shown the dashboard" do
    sign_in(users(:stari_staff))

    get "/platform/jobs"

    assert_response :forbidden
  end

  # The gem's default gate is HTTP Basic Auth, which would present a
  # WWW-Authenticate challenge on an unauthorized request. Its absence here
  # confirms our session auth — not the gem's — is what's actually deciding
  # access, exactly the swap config/initializers/mission_control_jobs.rb makes.
  test "never falls back to the gem's own HTTP Basic Auth challenge" do
    get "/platform/jobs"

    assert_nil response.headers["WWW-Authenticate"]
  end
end
