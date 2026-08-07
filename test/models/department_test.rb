require "test_helper"

class DepartmentTest < ActiveSupport::TestCase
  test "name must be unique within a hotel" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      duplicate = hotel.departments.new(name: hotels(:stari_grad).departments.first.name)

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:name], "has already been taken"
    end
  end

  test "the same name may be reused by a different hotel" do
    with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).departments.create!(name: "Spa") }

    with_tenant(hotels(:vrelo)) do
      department = hotels(:vrelo).departments.new(name: "Spa")
      assert department.valid?
    end
  end

  test "name is required" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      department = hotel.departments.new(name: "")
      assert_not department.valid?
    end
  end

  test "cannot be destroyed while a request category still references it" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      department = hotel.departments.create!(name: "Referenced Dept")
      hotel.request_categories.create!(key: "refd", name: "Referenced category", department: department)

      assert_not department.destroy

      assert department.errors.full_messages.any?
      assert Department.exists?(department.id), "the department must still exist after a blocked destroy"
    end
  end

  test "can be destroyed once nothing references it" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      department = hotel.departments.create!(name: "Unreferenced Dept")

      assert department.destroy
      assert_not Department.exists?(department.id)
    end
  end
end
