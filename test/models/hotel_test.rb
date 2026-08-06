require "test_helper"

class HotelTest < ActiveSupport::TestCase
  test "slug must be unique" do
    duplicate = Hotel.new(name: "Another Stari Grad", slug: hotels(:stari_grad).slug)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:slug], "has already been taken"
  end

  test "slug is derived from the name when blank" do
    hotel = Hotel.new(name: "Hotel Bistrik Konak")

    assert hotel.valid?, hotel.errors.full_messages.to_sentence
    assert_equal "hotel-bistrik-konak", hotel.slug
  end

  test "a supplied slug is downcased, stripped and hyphenated" do
    hotel = Hotel.new(name: "Hotel Bistrik Konak", slug: "  Bistrik Konak  ")

    assert hotel.valid?, hotel.errors.full_messages.to_sentence
    assert_equal "bistrik-konak", hotel.slug
  end

  test "slug rejects characters that would not survive a URL" do
    hotel = Hotel.new(name: "Hotel Bistrik", slug: "-bistrik/konak")

    assert_not hotel.valid?
    assert_includes hotel.errors[:slug], "may only contain lowercase letters, numbers and hyphens"
  end

  test "colours must be six-digit hex" do
    hotel = Hotel.new(name: "Hotel Bistrik", primary_color: "navy", secondary_color: "#GGGGGG")

    assert_not hotel.valid?
    assert_includes hotel.errors[:primary_color], "must be a six-digit hex colour such as #1F3A5F"
    assert_includes hotel.errors[:secondary_color], "must be a six-digit hex colour such as #1F3A5F"
  end

  test "staff_locale is limited to the languages the staff UI ships" do
    hotel = Hotel.new(name: "Hotel Bistrik", staff_locale: "de")

    assert_not hotel.valid?
    assert_includes hotel.errors[:staff_locale], "is not included in the list"

    assert Hotel.new(name: "Hotel Bistrik", staff_locale: "bs").valid?
    assert Hotel.new(name: "Hotel Bistrik", staff_locale: "en").valid?
  end

  test "timezone must be a recognized identifier" do
    assert_not Hotel.new(name: "Hotel Bistrik", timezone: "Mars/Olympus").valid?
    assert_not Hotel.new(name: "Hotel Bistrik", timezone: "").valid?
    assert Hotel.new(name: "Hotel Bistrik", timezone: "Europe/Sarajevo").valid?
  end

  test "status predicates report whether the hotel is live" do
    hotel = hotels(:stari_grad)

    assert hotel.active?
    assert_not hotel.suspended?

    hotel.suspended!

    assert hotel.suspended?
    assert_not hotel.active?
  end
end
