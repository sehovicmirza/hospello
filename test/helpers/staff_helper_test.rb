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

  # Every nav badge used to share one screen-reader string, so Requests
  # announced "2 conversations need attention" and the knowledge-gap badge
  # "4 conversations need attention". The span is sr-only, so nobody looking
  # at the page could see it was wrong — which is exactly why it needs a test
  # rather than an eyeball.
  test "each nav badge tells a screen reader what it is actually counting" do
    conversations = badge_sr_for(:conversations, 3)
    requests = badge_sr_for(:requests, 3)
    gaps = badge_sr_for(:knowledge_gaps, 3)

    assert_equal 3, [ conversations, requests, gaps ].uniq.length,
      "two badges share a label: #{[ conversations, requests, gaps ].inspect}"
    assert_match(/conversation/i, conversations)
    assert_match(/request/i, requests)
    assert_match(/question/i, gaps)
  end

  # Bosnian takes three plural forms where English takes two, and a badge is
  # nothing but a count — so this is the most plural-sensitive string in the
  # staff workspace.
  test "badge labels pluralise correctly in both staff languages" do
    I18n.with_locale(:en) do
      assert_match(/\bconversation needs\b/, badge_sr_for(:conversations, 1))
      assert_match(/\bconversations need\b/, badge_sr_for(:conversations, 5))
    end

    I18n.with_locale(:bs) do
      one = badge_sr_for(:conversations, 1)
      few = badge_sr_for(:conversations, 3)
      many = badge_sr_for(:conversations, 8)

      assert_equal 3, [ one, few, many ].uniq.length,
        "Bosnian needs one/few/other to read naturally: #{[ one, few, many ].inspect}"
    end
  end
end
