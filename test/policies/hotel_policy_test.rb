require "test_helper"

# Platform::BaseController's require_platform_admin already gates the whole
# platform namespace, so on the platform-only predicates HotelPolicy is a
# second, redundant layer — which is exactly why it needs its own test:
# nothing at the controller level would notice if its body were replaced with
# `true` everywhere. That stopped being true for #update? the moment Task 3
# extended it so a hotel_admin may edit their own hotel: Staff::HotelSettingsController
# has no role check of its own beyond `authorize @hotel`, so this policy is
# now the *only* gate on that staff-facing surface, and a mistake here needs
# a test that already exists to catch it.
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

  test "a hotel admin may update their own hotel, but has no platform-admin powers" do
    policy = HotelPolicy.new(users(:stari_admin), hotels(:stari_grad))

    assert_not policy.index?
    assert_not policy.show?
    assert_not policy.create?
    assert policy.update?
    assert_not policy.suspend?
    assert_not policy.activate?
  end

  test "a hotel admin may not update a different hotel" do
    policy = HotelPolicy.new(users(:stari_admin), hotels(:vrelo))

    assert_not policy.update?
  end

  test "a deactivated hotel admin may not update their own hotel" do
    users(:stari_admin).update!(active: false)
    policy = HotelPolicy.new(users(:stari_admin), hotels(:stari_grad))

    assert_not policy.update?
  end

  test "plain staff may not act on hotels, including their own" do
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
