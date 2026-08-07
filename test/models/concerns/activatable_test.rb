require "test_helper"

# active: "" is the blank-string shape a stray or hand-crafted request most
# often sends for a boolean param (curl, a form field that isn't backed by a
# hidden "0" default). ActiveModel::Type::Boolean casts that to nil — not
# false — and users, rooms, and departments all declare `active boolean,
# null: false`, so unguarded that nil sails straight through to Postgres and
# raises an unrescued ActiveRecord::NotNullViolation (a 500) instead of a
# normal, rescued validation error a controller re-renders.
#
# Fixed in one shared concern (Activatable) rather than three near-identical
# `validates :active, inclusion: ...` lines — and tested here, once, against
# all three real models it's included in, rather than against a synthetic
# double.
class ActivatableTest < ActiveSupport::TestCase
  test "User: active: \"\" is a validation error, not a database crash" do
    user = users(:stari_staff)
    user.active = ""

    assert_not user.valid?
    assert_includes user.errors[:active], "is not included in the list"
    refute_not_null_violation { user.save }
  end

  test "Room: active: \"\" is a validation error, not a database crash" do
    with_tenant(hotels(:stari_grad)) do
      room = rooms(:stari_301)
      room.active = ""

      assert_not room.valid?
      assert_includes room.errors[:active], "is not included in the list"
      refute_not_null_violation { room.save }
    end
  end

  test "Department: active: \"\" is a validation error, not a database crash" do
    with_tenant(hotels(:stari_grad)) do
      department = departments(:stari_reception)
      department.active = ""

      assert_not department.valid?
      assert_includes department.errors[:active], "is not included in the list"
      refute_not_null_violation { department.save }
    end
  end

  private
    def refute_not_null_violation
      yield
    rescue ActiveRecord::NotNullViolation => e
      flunk "expected a rescued validation error, not a database-level NotNullViolation: #{e.message}"
    end
end
