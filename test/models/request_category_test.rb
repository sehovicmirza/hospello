require "test_helper"

class RequestCategoryTest < ActiveSupport::TestCase
  test "detail_fields must only contain values the AI tool understands" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      category = hotel.request_categories.new(key: "unsupported_test", name: "Test", detail_fields: %w[quantity bogus])

      assert_not category.valid?
      assert_includes category.errors[:detail_fields].join, "bogus"
    end
  end

  test "detail_fields accepts every allowed value" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      category = hotel.request_categories.new(
        key: "all_fields_test", name: "Test",
        detail_fields: RequestCategory::ALLOWED_DETAIL_FIELDS
      )

      assert category.valid?
    end
  end

  test "detail_fields may be empty" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      category = hotel.request_categories.new(key: "no_fields_test", name: "Test", detail_fields: [])
      assert category.valid?
    end
  end

  test "a blank entry (the checkbox form's hidden fallback) is stripped, not treated as unsupported" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      category = hotel.request_categories.new(key: "blank_fallback_test", name: "Test", detail_fields: [ "", "time" ])

      assert category.valid?
      assert_equal %w[time], category.detail_fields
    end
  end

  test "key must be unique within a hotel" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      existing_key = hotel.request_categories.first.key
      duplicate = hotel.request_categories.new(key: existing_key, name: "Second")

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:key], "has already been taken"
    end
  end

  test "the same key may be reused by a different hotel" do
    with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).request_categories.create!(key: "shared_key_test", name: "Stari's") }

    with_tenant(hotels(:vrelo)) do
      category = hotels(:vrelo).request_categories.new(key: "shared_key_test", name: "Vrelo's")
      assert category.valid?
    end
  end

  test "name is required" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      category = hotel.request_categories.new(key: "blank_name_test", name: "")
      assert_not category.valid?
    end
  end

  test "department is optional" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      category = hotel.request_categories.new(key: "no_department_test", name: "No department")
      assert category.valid?
    end
  end

  # A hotel_admin tampering with a submitted department_id must not be able
  # to cross-link a category into a different hotel's department.
  test "a department belonging to a different hotel is rejected" do
    stari_department_id = with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).departments.first.id }

    with_tenant(hotels(:vrelo)) do
      category = hotels(:vrelo).request_categories.new(
        key: "cross_tenant_department_test", name: "Cross-tenant test", department_id: stari_department_id
      )

      assert_not category.valid?
      assert_includes category.errors[:department], "must belong to the same hotel"
    end
  end

  # Review round 1: the id path (`department_id = x`) re-queries under the
  # tenant scope on read and is covered above, but assigning the
  # association *object* directly caches exactly what was handed to it —
  # HotelDefaults.apply! itself does `record.department = departments_by_name.fetch(...)`,
  # so this is not a hypothetical path. The fix re-queries Department by id
  # from scratch rather than trusting the cached reader, so it closes both.
  test "a department object from a different hotel, assigned directly rather than by id, is still rejected" do
    stari_department = with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).departments.first }

    with_tenant(hotels(:vrelo)) do
      category = hotels(:vrelo).request_categories.new(
        key: "cross_tenant_object_test", name: "Cross-tenant object test", department: stari_department
      )

      assert_not category.valid?
      assert_includes category.errors[:department], "must belong to the same hotel"
    end
  end

  # Review round 1: "  Wake Up Call!  " saved verbatim, and "wake_up_call"
  # / "WAKE_UP_CALL" coexisted as distinct rows in the same hotel — key is
  # the AI tool's literal enum vocabulary, the one identifier here a
  # language model reads, and previously the only one of the three
  # (Room#number, Hotel#slug, RequestCategory#key) with no format
  # discipline.
  test "key is normalized to snake_case on save" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      category = hotel.request_categories.create!(key: "  Wake Up 2nd-Call  ", name: "Test")
      assert_equal "wake_up_2nd_call", category.key
    end
  end

  test "a key that still contains an invalid character after normalization is rejected, not saved verbatim" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      category = hotel.request_categories.new(key: "  Wake Up Call!  ", name: "Test")

      assert_not category.valid?
      assert category.errors[:key].any?
    end
  end

  test "a key must start with a letter, not a digit or underscore" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      assert_not hotel.request_categories.new(key: "1_starts_with_digit", name: "Test").valid?
      assert_not hotel.request_categories.new(key: "_starts_with_underscore", name: "Test").valid?
    end
  end

  test "key uniqueness is effectively case-insensitive because normalization lowercases both sides" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      hotel.request_categories.create!(key: "shouting_test", name: "First")
      duplicate = hotel.request_categories.new(key: "SHOUTING_TEST", name: "Second")

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:key], "has already been taken"
    end
  end

  test "detail_fields deduplicates repeated values" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      category = hotel.request_categories.new(key: "dup_fields_test", name: "Test", detail_fields: %w[time time description])

      assert category.valid?
      assert_equal %w[time description], category.detail_fields
    end
  end
end
