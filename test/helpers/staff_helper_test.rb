require "test_helper"

class StaffHelperTest < ActionView::TestCase
  include StaffHelper

  test "staff_time converts a timestamp into the hotel's own timezone" do
    Current.hotel = hotels(:stari_grad) # Europe/Sarajevo, UTC+1 in January
    time = Time.utc(2026, 1, 1, 12, 0, 0)

    result = staff_time(time)

    assert_equal "Europe/Sarajevo", result.time_zone.name
    assert_equal 13, result.hour
  end

  test "a hotel in a different timezone gets a different local hour for the same instant" do
    instant = Time.utc(2026, 1, 1, 12, 0, 0)

    Current.hotel = hotels(:stari_grad) # Europe/Sarajevo
    sarajevo_hour = staff_time(instant).hour

    Current.hotel = Hotel.new(timezone: "America/New_York")
    new_york_hour = staff_time(instant).hour

    assert_not_equal sarajevo_hour, new_york_hour
  end

  test "staff_time returns nil for a nil timestamp" do
    Current.hotel = hotels(:stari_grad)

    assert_nil staff_time(nil)
  end
end
