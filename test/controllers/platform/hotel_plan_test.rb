require "test_helper"

# Setting a hotel's plan from the platform cockpit.
#
# The shape here follows suspend/activate rather than the shared edit form, and
# for the same stated reason: a plan change is commercially significant, so it
# gets its own action and its own audit row. "What moved this hotel onto
# Essentials, and when" must never be something you infer from a generic
# hotel.update.
class Platform::HotelPlanTest < ActionDispatch::IntegrationTest
  setup do
    @hotel = hotels(:stari_grad)
    @hotel.update!(plan: :service, room_limit: nil)
    sign_in users(:platform)
  end

  test "a platform admin moves a hotel onto Essentials" do
    patch plan_platform_hotel_path(@hotel), params: { hotel: { plan: "essentials", room_limit: "" } }

    assert_redirected_to platform_hotel_path(@hotel)
    assert_equal "essentials", @hotel.reload.plan
    assert_nil @hotel.room_limit, "a blank box means 'whatever the plan includes', not zero"
    assert_equal 20, @hotel.effective_room_limit
  end

  test "the change is audited under its own action, with the plans it moved between" do
    assert_difference -> { AuditLog.where(action: "hotel.plan_change").count }, 1 do
      patch plan_platform_hotel_path(@hotel), params: { hotel: { plan: "essentials", room_limit: "" } }
    end

    log = AuditLog.where(action: "hotel.plan_change").last
    assert_equal @hotel.id, log.hotel_id
    assert_equal "service", log.metadata["from"]
    assert_equal "essentials", log.metadata["to"]
  end

  test "a room limit can be sold alongside the plan" do
    patch plan_platform_hotel_path(@hotel), params: { hotel: { plan: "essentials", room_limit: "35" } }

    assert_equal 35, @hotel.reload.room_limit
    assert_equal 35, @hotel.effective_room_limit
  end

  # The notice is what an operator reads to confirm what they just did, so it
  # has to distinguish "moved" from "stayed".
  test "the notice names both the movement and the resulting ceiling" do
    patch plan_platform_hotel_path(@hotel), params: { hotel: { plan: "essentials", room_limit: "" } }
    assert_match(/moved from Service to Essentials/, flash[:notice])
    assert_match(/up to 20 rooms/, flash[:notice])

    patch plan_platform_hotel_path(@hotel), params: { hotel: { plan: "essentials", room_limit: "30" } }
    assert_match(/stays on Essentials/, flash[:notice])
    assert_match(/up to 30 rooms/, flash[:notice])
  end

  # Two doors to a plan change, one of them unlogged, is the thing this design
  # exists to prevent.
  test "the shared edit form cannot change the plan" do
    patch platform_hotel_path(@hotel), params: { hotel: { name: "Renamed", plan: "essentials" } }

    assert_equal "service", @hotel.reload.plan, "plan changed through #update, bypassing the audit log"
    assert_equal "Renamed", @hotel.name
  end

  test "a new hotel is born on the plan the form chose" do
    assert_difference -> { Hotel.count }, 1 do
      post platform_hotels_path, params: {
        hotel: { name: "Hotel Novi", slug: "hotel-novi", timezone: "Europe/Sarajevo",
                 staff_locale: "bs", plan: "essentials" }
      }
    end

    assert_equal "essentials", Hotel.find_by(slug: "hotel-novi").plan
  end

  test "a hotel created with no plan named lands on Essentials, which is what we sell" do
    post platform_hotels_path, params: {
      hotel: { name: "Hotel Bezimeni", slug: "hotel-bezimeni", timezone: "Europe/Sarajevo", staff_locale: "bs" }
    }

    assert_equal "essentials", Hotel.find_by(slug: "hotel-bezimeni").plan
  end

  # Note what this does and does not prove: Platform::BaseController's
  # require_platform_admin refuses a hotel_admin before Pundit is ever
  # consulted, so this pins the namespace's own gate. HotelPolicy#plan? is the
  # second, independent layer and is tested directly in
  # test/policies/hotel_policy_test.rb — an assertion here alone would stay
  # green even if that policy said `true`.
  test "the platform namespace refuses a hotel admin outright" do
    sign_in users(:stari_admin)

    patch plan_platform_hotel_path(@hotel), params: { hotel: { plan: "essentials" } }

    assert_response :forbidden
    assert_equal "service", @hotel.reload.plan
  end
end
