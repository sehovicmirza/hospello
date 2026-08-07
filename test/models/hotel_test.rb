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

  # An audit trail has to outlive what it describes, so deleting a hotel must
  # nullify the references rather than be blocked by them.
  test "destroying a hotel leaves its audit trail behind" do
    hotel = hotels(:vrelo)
    log = AuditLog.record!(actor: users(:vrelo_admin), hotel: hotel, action: "hotel.suspended")

    hotel.destroy!

    log.reload

    assert_nil log.hotel_id
    assert_nil log.actor_user_id
    assert_equal "hotel.suspended", log.action
  end

  test "logo must be one of the supported image types" do
    hotel = hotels(:stari_grad)
    hotel.logo.attach(io: StringIO.new("bogus"), filename: "evil.pdf", content_type: "application/pdf")

    assert_not hotel.valid?
    assert_includes hotel.errors[:logo], "must be a PNG, JPEG, WebP or SVG image"
  end

  test "logo must be 2 MB or smaller" do
    hotel = hotels(:stari_grad)
    hotel.logo.attach(io: StringIO.new("x" * 3.megabytes), filename: "big.png", content_type: "image/png")

    assert_not hotel.valid?
    assert_includes hotel.errors[:logo], "must be smaller than 2 MB"
  end

  test "a logo within the type and size limits attaches cleanly" do
    hotel = hotels(:stari_grad)
    hotel.logo.attach(io: StringIO.new("small-fake-logo"), filename: "logo.png", content_type: "image/png")

    assert hotel.valid?, hotel.errors.full_messages.to_sentence
  end

  test "welcome image must be 5 MB or smaller" do
    hotel = hotels(:stari_grad)
    hotel.welcome_image.attach(io: StringIO.new("x" * 6.megabytes), filename: "big.jpg", content_type: "image/jpeg")

    assert_not hotel.valid?
    assert_includes hotel.errors[:welcome_image], "must be smaller than 5 MB"
  end

  # Review round 1, Important 5: a hotel admin could otherwise attach a PDF
  # (or anything else) declared as the welcome image; it would persist
  # cleanly and then render as a broken image on the guest landing page in
  # Slice 2. No SVG here (unlike the logo) — this is a photographic hero
  # image, not a vector mark.
  test "welcome image must be one of the supported image types" do
    hotel = hotels(:stari_grad)
    hotel.welcome_image.attach(io: StringIO.new("bogus"), filename: "evil.pdf", content_type: "application/pdf")

    assert_not hotel.valid?
    assert_includes hotel.errors[:welcome_image], "must be a PNG, JPEG or WebP image"
  end

  test "a welcome image within the type and size limits attaches cleanly" do
    hotel = hotels(:stari_grad)
    hotel.welcome_image.attach(io: StringIO.new("small-fake-image"), filename: "welcome.jpg", content_type: "image/jpeg")

    assert hotel.valid?, hotel.errors.full_messages.to_sentence
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
