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

  test "links each category to its named department and stores its detail_fields" do
    with_tenant(@hotel) do
      HotelDefaults.apply!(@hotel)

      towels = @hotel.request_categories.find_by!(key: "room_items")
      assert_equal "Housekeeping", towels.department.name
      assert_equal %w[quantity description], towels.detail_fields

      wake_up = @hotel.request_categories.find_by!(key: "wake_up_call")
      assert_equal "Reception", wake_up.department.name
      assert_equal %w[time], wake_up.detail_fields

      dining = @hotel.request_categories.find_by!(key: "dining_reservation")
      assert_equal "Food & Beverage", dining.department.name
      assert_equal %w[date time people], dining.detail_fields
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
