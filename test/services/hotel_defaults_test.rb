require "test_helper"

class HotelDefaultsTest < ActiveSupport::TestCase
  # A fresh, non-fixture hotel so these tests own their starting state
  # completely — hotels(:stari_grad)/hotels(:vrelo) carry their own
  # hand-authored department/category fixtures for other tests (isolation,
  # controller listings), which would make an "exactly these rows exist"
  # assertion here brittle and coupled to unrelated fixture data.
  setup do
    @hotel = Hotel.create!(name: "Defaults Test Hotel #{SecureRandom.hex(4)}")
  end

  test "creates the four default departments and eight default categories" do
    with_tenant(@hotel) do
      HotelDefaults.apply!(@hotel)

      assert_equal [ "Food & Beverage", "Housekeeping", "Maintenance", "Reception" ],
        @hotel.departments.order(:name).pluck(:name)
      assert_equal 8, @hotel.request_categories.count
    end
  end

  # Review round 1: the previous version of this test checked 3 of the 8
  # tuples (room_items, wake_up_call, dining_reservation) — a typo in, say,
  # spa_reservation's department or detail_fields could ship green. This
  # pins every key/name/department/detail_fields tuple exactly, in the
  # brief's own order, character for character.
  test "pins every default category's key, name, department and detail_fields exactly" do
    expected = [
      { key: "room_items", name: "Extra towels, bedding or toiletries",
        department: "Housekeeping", detail_fields: %w[quantity description] },
      { key: "cleaning", name: "Room cleaning",
        department: "Housekeeping", detail_fields: %w[time] },
      { key: "maintenance", name: "Report a problem",
        department: "Maintenance", detail_fields: %w[description] },
      { key: "wake_up_call", name: "Wake-up call",
        department: "Reception", detail_fields: %w[time] },
      { key: "dining_reservation", name: "Restaurant or breakfast reservation request",
        department: "Food & Beverage", detail_fields: %w[date time people] },
      { key: "spa_reservation", name: "Spa or wellness reservation request",
        department: "Reception", detail_fields: %w[date time people] },
      { key: "transport", name: "Taxi, airport transfer or luggage help",
        department: "Reception", detail_fields: %w[time description] },
      { key: "reception", name: "Something else for reception",
        department: "Reception", detail_fields: %w[description] }
    ]

    with_tenant(@hotel) do
      HotelDefaults.apply!(@hotel)

      actual = expected.map do |exp|
        category = @hotel.request_categories.find_by!(key: exp[:key])
        { key: category.key, name: category.name, department: category.department.name, detail_fields: category.detail_fields }
      end

      assert_equal expected, actual
    end
  end

  test "every default category's detail_fields only use values the AI tool understands" do
    with_tenant(@hotel) do
      HotelDefaults.apply!(@hotel)

      @hotel.request_categories.find_each do |category|
        unsupported = category.detail_fields - RequestCategory::ALLOWED_DETAIL_FIELDS
        assert_empty unsupported, "#{category.key} has unsupported detail_fields: #{unsupported}"
      end
    end
  end

  test "is idempotent — calling it twice does not create duplicate rows" do
    with_tenant(@hotel) do
      HotelDefaults.apply!(@hotel)
      counts_after_first_apply = [ @hotel.departments.count, @hotel.request_categories.count ]

      HotelDefaults.apply!(@hotel)

      assert_equal counts_after_first_apply, [ @hotel.departments.count, @hotel.request_categories.count ]
    end
  end

  test "re-applying does not duplicate a category whose name the hotel already edited" do
    with_tenant(@hotel) do
      HotelDefaults.apply!(@hotel)
      towels = @hotel.request_categories.find_by!(key: "room_items")
      towels.update!(name: "Peškiri, posteljina ili toaletni pribor")

      HotelDefaults.apply!(@hotel)

      assert_equal "Peškiri, posteljina ili toaletni pribor", towels.reload.name
      assert_equal 8, @hotel.request_categories.count, "must not have created a duplicate 'room_items' category"
    end
  end

  # Unlike categories, departments have no stable `key` column (see the
  # brief's schema — only request_categories gets one), so find_or_create_by!
  # can only match departments by their current `name`. Renaming a department
  # and then re-applying *would* create a second row here — but apply! only
  # ever runs once, synchronously, inside Platform::HotelsController#create,
  # before the hotel has any admin who could rename anything. Documented
  # rather than silently assumed away.
  test "documented limitation: re-applying after a department rename creates a second department" do
    with_tenant(@hotel) do
      HotelDefaults.apply!(@hotel)
      @hotel.departments.find_by!(name: "Reception").update!(name: "Recepcija")

      HotelDefaults.apply!(@hotel)

      assert_equal 5, @hotel.departments.count
    end
  end

  test "does not touch a different hotel's departments or categories" do
    other_hotel = Hotel.create!(name: "Other Test Hotel #{SecureRandom.hex(4)}")

    with_tenant(@hotel) { HotelDefaults.apply!(@hotel) }

    with_tenant(other_hotel) do
      assert_equal 0, other_hotel.departments.count
      assert_equal 0, other_hotel.request_categories.count
    end
  end
end
