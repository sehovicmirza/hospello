require "test_helper"

# Bulk-adding rooms into a plan's ceiling.
#
# This is the path that actually hits the cap: a hotel setting itself up pastes
# "101-140" once. Before the ceiling existed the loop called save!, so crossing
# it would have been a 500 rather than something a receptionist could read.
class Staff::RoomLimitBulkTest < ActionDispatch::IntegrationTest
  setup do
    @hotel = hotels(:stari_grad)
    ActsAsTenant.current_tenant = @hotel
    @hotel.rooms.destroy_all
    sign_in users(:stari_admin)
  end

  test "a bulk paste that crosses the ceiling adds what fits and says why" do
    @hotel.update!(plan: :essentials, room_limit: 3)

    post bulk_create_staff_rooms_path, params: { bulk: { numbers: "101-110" } }

    assert_redirected_to staff_rooms_path
    assert_equal 3, @hotel.rooms.count, "it should have filled exactly to the ceiling"
    # Bosnian: stari_admin's workspace language. Pasted literally rather than
    # looked up, so this cannot pass by reading the same source the app does.
    assert_match(/vaš plan pokriva do 3 soba/i, flash[:notice])
  end

  test "a bulk paste inside the ceiling still says nothing about limits" do
    @hotel.update!(plan: :essentials, room_limit: 20)

    post bulk_create_staff_rooms_path, params: { bulk: { numbers: "101-105" } }

    assert_equal 5, @hotel.rooms.count
    assert_no_match(/pokriva do/i, flash[:notice])
  end

  # The single-room form, not the bulk one — the ceiling has to hold on both.
  test "adding one room past the ceiling re-renders with the error" do
    @hotel.update!(plan: :essentials, room_limit: 1)
    @hotel.rooms.create!(number: "101")

    assert_no_difference -> { Room.unscoped.count } do
      post staff_rooms_path, params: { room: { number: "102" } }
    end

    assert_response :unprocessable_content
    assert_match(/pokriva do 1/i, response.body)
  end

  test "an uncapped hotel bulk-adds the lot" do
    @hotel.update!(plan: :service, room_limit: nil)

    post bulk_create_staff_rooms_path, params: { bulk: { numbers: "101-130" } }

    assert_equal 30, @hotel.rooms.count
    assert_no_match(/pokriva do/i, flash[:notice])
  end
end
