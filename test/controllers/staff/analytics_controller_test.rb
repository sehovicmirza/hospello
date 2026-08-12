require "test_helper"

# The hotel's own numbers. Analytics::HotelReport is tested in isolation
# (test/services/analytics/hotel_report_test.rb); what this file is about is
# the screen around it — who may see it, what a hand-edited URL does, and
# that the page states the range it is *really* showing rather than the one
# that was asked for.
#
# stari_admin and stari_staff both read the workspace in Bosnian (see
# test/fixtures/users.yml), so the strings asserted below are the literal
# Bosnian from config/locales/staff.bs.yml, pasted rather than looked up
# through I18n.t (engineering rule 2).
class Staff::AnalyticsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @hotel = hotels(:stari_grad)
    @admin = users(:stari_admin)
    @staff = users(:stari_staff)
  end

  test "a hotel admin sees their own numbers" do
    with_tenant(@hotel) do
      3.times { |index| UnansweredQuestion.record!(hotel: @hotel, question: "Is there parking? #{index}") }
    end
    sign_in @admin

    get staff_analytics_path

    assert_response :success
    assert_select "#analytics-gaps", text: /Is there parking\? 0/
    assert_select "#guests-helped"
  end

  # The most actionable thing on the page: "guests keep asking about parking"
  # tells a hotel exactly what to write down, which "7 unanswered" does not.
  test "the knowledge gaps are named, with how often each was asked" do
    with_tenant(@hotel) do
      3.times { UnansweredQuestion.record!(hotel: @hotel, question: "Do you have parking?") }
    end
    sign_in @admin

    get staff_analytics_path

    assert_select "#analytics-gaps", text: /Do you have parking\?/
    assert_select "#analytics-gaps", text: /pitano 3 puta/
  end

  test "a hotel with nothing unanswered is told so rather than shown an empty list" do
    sign_in @admin

    get staff_analytics_path

    assert_select "#analytics-gaps-empty"
  end

  # --- The range ---------------------------------------------------------------

  test "the page states the range it is showing" do
    sign_in @admin

    get staff_analytics_path(from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 7))

    assert_select "#analytics-range", text: /7 dana/
  end

  # A page someone lands on from a bookmark or a hand-edited URL. The useful
  # response to `?from=banana` is the default month, not a 500.
  test "a malformed date is treated as not given, not as an error" do
    sign_in @admin

    get staff_analytics_path(from: "banana", to: "🙂")

    assert_response :success
    assert_select "#analytics-range", text: /30 dana/
  end

  # The report clamps a future end date, and the page must say what it really
  # showed — a page quietly showing something other than what was asked for is
  # the kind of wrong nobody catches.
  test "a range ending in the future is pulled back to today, and the page says so" do
    sign_in @admin

    get staff_analytics_path(from: Date.current, to: Date.current + 365)

    assert_response :success
    assert_select "#analytics-range", text: /#{Regexp.escape(I18n.l(Date.current, format: :long, locale: :bs))}/
  end

  test "an absurdly wide range is capped rather than run" do
    sign_in @admin

    get staff_analytics_path(from: Date.current - 3650, to: Date.current)

    assert_response :success
    assert_select "#analytics-range", text: /#{Analytics::HotelReport::MAX_DAYS} dana/
  end

  # --- Who may see it -------------------------------------------------------------

  # Unlike most staff screens, this one is hotel-admin only. A receptionist
  # reading "how often did the assistant have to hand over to us" is reading a
  # page about their own performance, and that is a conversation a manager
  # should choose to have rather than one the software starts.
  test "a receptionist cannot reach it" do
    sign_in @staff

    get staff_analytics_path

    assert_response :forbidden
  end

  test "and is not shown a link to it" do
    sign_in @staff

    get staff_conversations_path

    assert_response :success
    assert_select "a[href=?]", staff_analytics_path, count: 0
  end

  test "a hotel admin is shown the link" do
    sign_in @admin

    get staff_root_path

    assert_select "a[href=?]", staff_analytics_path, text: "Analitika"
  end

  test "a deactivated hotel admin cannot reach it" do
    @admin.update!(active: false)
    sign_in @admin

    get staff_analytics_path

    assert_response :forbidden
  end

  # --- Isolation --------------------------------------------------------------------

  # There is no hotel id anywhere in this route, so reaching another hotel's
  # numbers is structural rather than checked. The two hotels are given
  # deliberately different data so a page accidentally reporting across all of
  # them is visibly wrong rather than coincidentally right.
  test "one hotel's page can never show another hotel's activity" do
    with_tenant(hotels(:vrelo)) do
      UnansweredQuestion.record!(hotel: hotels(:vrelo), question: "Vrelo's own secret question?")
    end
    sign_in @admin

    get staff_analytics_path

    assert_response :success
    assert_select "#analytics-gaps", text: /Vrelo's own secret question\?/, count: 0
  end
end
