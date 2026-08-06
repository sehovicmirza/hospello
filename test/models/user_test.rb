require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "email address is stripped and downcased" do
    user = User.new(email_address: "  Nedim@Stari-Grad.Example  ")

    assert_equal "nedim@stari-grad.example", user.email_address
  end

  test "email address is unique platform-wide, case-insensitively" do
    duplicate = User.new(
      email_address: users(:stari_admin).email_address.upcase,
      name: "Someone Else", role: :staff, hotel: hotels(:vrelo), password: "password123"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email_address], "has already been taken"
  end

  test "platform admins must not belong to a hotel" do
    user = users(:platform)
    user.hotel = hotels(:stari_grad)

    assert_not user.valid?
    assert_includes user.errors[:hotel], "must be blank: platform admins must not belong to a hotel"
  end

  test "a platform admin without a hotel is valid" do
    assert users(:platform).valid?
  end

  test "staff and hotel admins must belong to a hotel" do
    %i[staff hotel_admin].each do |role|
      user = User.new(email_address: "someone@example.test", name: "Someone", role: role, password: "password123")

      assert_not user.valid?, "#{role} without a hotel should be invalid"
      assert_includes user.errors[:hotel], "must be present: staff and hotel admins must belong to a hotel"
    end
  end

  test "role predicates distinguish the three roles" do
    assert users(:stari_staff).staff?
    assert_not users(:stari_staff).hotel_admin?

    assert users(:stari_admin).hotel_admin?
    assert_not users(:stari_admin).platform_admin?

    assert users(:platform).platform_admin?
    assert_not users(:platform).staff?
  end

  test "the active scope excludes deactivated accounts" do
    deactivated = users(:vrelo_staff)
    deactivated.update!(active: false)

    assert_not_includes User.active, deactivated
    assert_includes User.active, users(:vrelo_admin)
  end

  test "a deactivated account cannot sign in" do
    user = users(:stari_staff)

    assert user.can_sign_in?

    user.update!(active: false)

    assert_not user.can_sign_in?
  end

  test "a suspended hotel's staff cannot sign in" do
    user = users(:vrelo_staff)

    assert user.can_sign_in?

    user.hotel.suspended!

    assert_not user.reload.can_sign_in?
  end

  test "a platform admin can sign in without a hotel" do
    assert users(:platform).can_sign_in?
  end
end
