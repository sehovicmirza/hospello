require "test_helper"

# Platform::BaseController's require_platform_admin already gates the whole
# namespace, so today HotelPolicy is a second, redundant layer — which is
# exactly why it needs its own test: nothing at the controller level would
# notice if its body were replaced with `true` everywhere. That stops being
# true the moment Task 3 extends #update? so a hotel_admin may edit their own
# hotel — at that point this policy becomes the only gate on a staff-facing
# surface, and a mistake there needs a test that already exists to catch it.
class HotelPolicyTest < ActiveSupport::TestCase
  test "a platform admin may act on any hotel" do
    policy = HotelPolicy.new(users(:platform), hotels(:stari_grad))

    assert policy.index?
    assert policy.show?
    assert policy.create?
    assert policy.update?
    assert policy.suspend?
    assert policy.activate?
  end

  test "a deactivated platform admin may not act on hotels" do
    users(:platform).update!(active: false)
    policy = HotelPolicy.new(users(:platform), hotels(:stari_grad))

    assert_not policy.index?
    assert_not policy.update?
  end

  test "a hotel admin may not act on hotels" do
    policy = HotelPolicy.new(users(:stari_admin), hotels(:stari_grad))

    assert_not policy.index?
    assert_not policy.show?
    assert_not policy.create?
    assert_not policy.update?
    assert_not policy.suspend?
    assert_not policy.activate?
  end

  test "plain staff may not act on hotels" do
    policy = HotelPolicy.new(users(:stari_staff), hotels(:stari_grad))

    assert_not policy.index?
    assert_not policy.update?
  end

  test "a signed-out user (nil) may not act on hotels" do
    policy = HotelPolicy.new(nil, hotels(:stari_grad))

    assert_not policy.index?
    assert_not policy.update?
  end
end
