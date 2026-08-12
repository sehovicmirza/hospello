require "test_helper"

# Every hotel, one row each — the page for whoever runs Hospello.
#
# The property that matters most is that it reads the **same**
# Analytics::HotelReport a hotel reads about itself, so the two can never show
# different numbers for the same thing. There is a test for exactly that
# below, and it is the reason the report is an object rather than queries in a
# controller.
#
# This namespace is English-only by convention — platform admins are
# Hospello's own people, not a hotel's staff — so the strings asserted here
# are plain English rather than locale lookups.
class Platform::AnalyticsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:platform)
    @stari = hotels(:stari_grad)
    @vrelo = hotels(:vrelo)
  end

  test "lists every hotel with its own numbers" do
    with_tenant(@stari) { 3.times { |index| UnansweredQuestion.record!(hotel: @stari, question: "Stari #{index}?") } }
    with_tenant(@vrelo) { UnansweredQuestion.record!(hotel: @vrelo, question: "Vrelo?") }
    sign_in @admin

    get platform_analytics_path

    assert_response :success
    assert_select "##{dom_id(@stari, :analytics)}", text: /Hotel Stari Grad/
    assert_select "##{dom_id(@vrelo, :analytics)}"
  end

  # The whole reason Analytics::HotelReport is one object. Two implementations
  # of "how many conversations did a person have to take over" would disagree
  # within a month, and nobody could then say which page was lying.
  test "a hotel's row matches what that hotel sees on its own page" do
    with_tenant(@stari) do
      2.times { |index| UnansweredQuestion.record!(hotel: @stari, question: "Same number? #{index}") }
    end

    sign_in @admin
    get platform_analytics_path
    platform_row = css_select("##{dom_id(@stari, :analytics)} td").map { |cell| cell.text.strip }

    sign_in users(:stari_admin)
    get staff_analytics_path
    hotel_gaps = css_select("#analytics-gaps li").size

    assert_equal 2, hotel_gaps
    assert_includes platform_row, "2", "the platform's unanswered count must be the hotel's own"
  end

  test "totals every hotel's numbers into one row" do
    with_tenant(@stari) { 3.times { |index| UnansweredQuestion.record!(hotel: @stari, question: "S#{index}?") } }
    with_tenant(@vrelo) { 2.times { |index| UnansweredQuestion.record!(hotel: @vrelo, question: "V#{index}?") } }
    sign_in @admin

    get platform_analytics_path

    assert_select "#analytics-totals", text: /5/
  end

  # "Which hotels stopped using it" is exactly what this screen is for.
  # Dropping suspended hotels would hide the one number that matters
  # commercially.
  test "a suspended hotel is still listed, and marked as suspended" do
    @vrelo.update!(status: :suspended)
    sign_in @admin

    get platform_analytics_path

    assert_select "##{dom_id(@vrelo, :analytics)}", text: /Suspended/
  end

  test "an installation with no hotels says so rather than rendering an empty table" do
    Hotel.destroy_all
    sign_in @admin

    get platform_analytics_path

    assert_response :success
    assert_select "#analytics-totals", count: 0
  end

  # Same reasoning as the staff page: a URL people hand-edit and bookmark.
  test "a malformed date is treated as not given, not as an error" do
    sign_in @admin

    get platform_analytics_path(from: "banana")

    assert_response :success
  end

  # --- Who may see it ------------------------------------------------------

  test "a hotel admin cannot reach the platform rollup" do
    sign_in users(:stari_admin)

    get platform_analytics_path

    assert_response :forbidden
  end

  test "a receptionist cannot either" do
    sign_in users(:stari_staff)

    get platform_analytics_path

    assert_response :forbidden
  end

  # Sessions are permanent cookies that nothing revokes, so deactivating the
  # account is the only way to take cross-hotel access away.
  test "a deactivated platform admin cannot reach it" do
    @admin.update!(active: false)
    sign_in @admin

    get platform_analytics_path

    assert_response :forbidden
  end

  test "a signed-out visitor cannot reach it" do
    get platform_analytics_path

    assert_response :redirect
  end
end
