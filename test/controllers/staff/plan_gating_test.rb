require "test_helper"

# Every staff screen that only exists because a hotel bought the Service plan,
# asked for by a hotel on Essentials.
#
# The important one here is request_categories. It has no nav item — it is
# reached only through a link inside departments/index.html.erb — so hiding the
# Departments nav entry would leave the URL working perfectly. Engineering rule
# 3: guard the idiomatic way in, not just the obvious one.
#
# Expected copy is pasted literally rather than looked up through I18n, so
# these assertions cannot pass by reading the same source the view reads
# (rule 2). stari_admin reads the workspace in Bosnian — see the fixtures.
class Staff::PlanGatingTest < ActionDispatch::IntegrationTest
  # Every request-only route in the staff namespace, including the two that no
  # nav item points at.
  REQUEST_ROUTES = {
    "request board" => -> { staff_service_requests_path },
    "departments" => -> { staff_departments_path },
    "request categories" => -> { staff_request_categories_path }
  }.freeze

  setup do
    @hotel = hotels(:stari_grad)
  end

  test "an Essentials hotel is refused every request-only screen" do
    @hotel.update!(plan: :essentials)
    sign_in users(:stari_admin)

    REQUEST_ROUTES.each do |name, path|
      get instance_exec(&path)
      assert_response :forbidden, "#{name} was reachable on Essentials"
    end
  end

  test "the refusal explains itself instead of saying Not authorized" do
    @hotel.update!(plan: :essentials)
    sign_in users(:stari_admin)

    get staff_service_requests_path

    assert_response :forbidden
    assert_select "h1", text: "Zahtjevi gostiju nisu dio Essentials plana"
    assert_match "Vaš plan: Essentials", response.body
    assert_no_match(/Not authorized/, response.body)
  end

  # A POST, not a GET: the note form on a request is its own controller and
  # would otherwise be a writable hole behind a refused read screen.
  #
  # The id is deliberately one that does not exist. requires_plan_feature is
  # declared above `before_action :set_request`, so the refusal happens before
  # the lookup — which is the ordering that matters: a gate that ran after the
  # find would leak "this request exists" as a 404-vs-403 difference, and would
  # be skipped entirely on any path that 404s first.
  test "an Essentials hotel cannot post a staff note onto a request" do
    @hotel.update!(plan: :essentials)
    sign_in users(:stari_admin)

    assert_no_difference -> { RequestEvent.unscoped.count } do
      post staff_service_request_request_events_path(999_999), params: { request_event: { body: "on it" } }
    end
    assert_response :forbidden
  end

  test "a Service hotel still reaches every one of them" do
    @hotel.update!(plan: :service)
    sign_in users(:stari_admin)

    REQUEST_ROUTES.each do |name, path|
      get instance_exec(&path)
      assert_response :success, "#{name} was refused on Service"
    end
  end

  # --- What an Essentials hotel's workspace actually looks like -------------

  test "the nav offers no Requests and no Departments on Essentials" do
    @hotel.update!(plan: :essentials)
    sign_in users(:stari_admin)

    get staff_root_path

    assert_response :success
    assert_select "nav a[href=?]", staff_service_requests_path, count: 0
    assert_select "nav a[href=?]", staff_departments_path, count: 0
    # The inbox and knowledge base are what Essentials *is*, so their absence
    # would be a different bug wearing the same clothes.
    assert_select "nav a[href=?]", staff_conversations_path, count: 1
    assert_select "nav a[href=?]", staff_kb_entries_path, count: 1
  end

  test "the nav offers both on Service" do
    @hotel.update!(plan: :service)
    sign_in users(:stari_admin)

    get staff_root_path

    assert_response :success
    assert_select "nav a[href=?]", staff_service_requests_path, count: 1
    assert_select "nav a[href=?]", staff_departments_path, count: 1
  end

  test "analytics hides the requests panel on Essentials and shows it on Service" do
    sign_in users(:stari_admin)

    @hotel.update!(plan: :essentials)
    get staff_analytics_path
    assert_response :success
    assert_select "#requests-total", count: 0
    assert_select "#requests-overdue", count: 0
    # The assistant panel is not request-specific and must survive.
    assert_select "#assistant-runs", count: 1

    @hotel.update!(plan: :service)
    get staff_analytics_path
    assert_response :success
    assert_select "#requests-total", count: 1
  end

  test "hotel settings hides the escalation fieldset on Essentials" do
    @hotel.update!(plan: :essentials)
    sign_in users(:stari_admin)

    get edit_staff_hotel_settings_path

    assert_response :success
    assert_select "input[name=?]", "hotel[escalation_email]", count: 0
    assert_select "input[name=?]", "hotel[overdue_after_minutes]", count: 0
    # A field that is genuinely part of Essentials, to prove the form rendered.
    assert_select "input[name=?]", "hotel[concierge_name]", count: 1
  end

  # The one that matters: hiding a field is a UI decision, not a gate. This
  # posts the parameters directly, as anyone with the form's HTML could.
  test "an Essentials hotel cannot set escalation fields by posting them" do
    @hotel.update!(plan: :essentials, escalation_email: "before@example.com", overdue_after_minutes: 120)
    sign_in users(:stari_admin)

    patch staff_hotel_settings_path, params: {
      hotel: { concierge_name: "Amila", escalation_email: "after@example.com", overdue_after_minutes: 5 }
    }

    @hotel.reload
    assert_equal "before@example.com", @hotel.escalation_email
    assert_equal 120, @hotel.overdue_after_minutes
    # The rest of the form still saved — this is a filter, not a rejection.
    assert_equal "Amila", @hotel.concierge_name
  end

  test "a Service hotel can still set them" do
    @hotel.update!(plan: :service, escalation_email: "before@example.com")
    sign_in users(:stari_admin)

    patch staff_hotel_settings_path, params: { hotel: { escalation_email: "after@example.com" } }

    assert_equal "after@example.com", @hotel.reload.escalation_email
  end
end
