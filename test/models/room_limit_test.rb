require "test_helper"

# The room ceiling a plan is sold with — 20 on Essentials, none above it —
# and the per-hotel override that lets one hotel be sold something else
# without inventing a fourth plan.
#
# The rule that matters most here is the one about downgrades: a hotel moved
# to a smaller plan keeps every room it already has. Deactivating rooms
# someone is standing in would be data loss dressed up as a billing rule.
class RoomLimitTest < ActiveSupport::TestCase
  setup do
    @hotel = hotels(:stari_grad)
    ActsAsTenant.current_tenant = @hotel
  end

  test "Essentials is capped at twenty rooms and Service is not capped" do
    @hotel.update!(plan: :essentials)
    assert_equal 20, @hotel.effective_room_limit

    @hotel.update!(plan: :service)
    assert_nil @hotel.effective_room_limit
  end

  # nil is "follow the plan", not "no ceiling" — the override is only consulted
  # when someone actually wrote a number.
  test "a per-hotel limit overrides the plan's, in both directions" do
    @hotel.update!(plan: :essentials, room_limit: 35)
    assert_equal 35, @hotel.effective_room_limit

    @hotel.update!(plan: :service, room_limit: 5)
    assert_equal 5, @hotel.effective_room_limit
  end

  # Distinct from nil, and deliberately the opposite reading to
  # AiRun#budget_exhausted_for?, where 0 means exhausted rather than unlimited.
  test "a limit of zero means zero rooms, not unlimited" do
    @hotel.update!(plan: :service, room_limit: 0)

    assert_equal 0, @hotel.effective_room_limit
    assert_not @hotel.rooms.new(number: "1").valid?
  end

  test "a room over the limit is refused, and the message says the number" do
    @hotel.update!(plan: :essentials, room_limit: 2)
    fill_to_limit(2)

    room = @hotel.rooms.new(number: "999")

    assert_not room.valid?
    assert_includes room.errors.full_messages.join, "up to 2 rooms"
  end

  test "a room under the limit is allowed" do
    @hotel.update!(plan: :essentials, room_limit: 5)
    fill_to_limit(2)

    assert @hotel.rooms.new(number: "999").valid?
  end

  test "an uncapped hotel is never refused" do
    @hotel.update!(plan: :service, room_limit: nil)
    fill_to_limit(3)

    assert @hotel.rooms.new(number: "999").valid?
  end

  # The downgrade case. Nothing is deleted, deactivated or hidden — the hotel
  # simply cannot add more.
  test "a hotel downgraded below its room count keeps every room it has" do
    @hotel.update!(plan: :service, room_limit: nil)
    fill_to_limit(4)
    existing = @hotel.rooms.count

    @hotel.update!(plan: :essentials, room_limit: 2)

    assert_equal existing, @hotel.rooms.count
    assert_equal existing, @hotel.rooms.active.count, "existing rooms must stay usable"
    assert_not @hotel.rooms.new(number: "999").valid?, "but no new ones"
  end

  # Editing a room that is already over the ceiling must keep working — the
  # validation is on: :create for exactly this reason.
  test "an existing room can still be edited when the hotel is over its limit" do
    @hotel.update!(plan: :service, room_limit: nil)
    fill_to_limit(3)
    @hotel.update!(room_limit: 1)
    room = @hotel.rooms.order(:id).last

    room.active = false

    assert room.valid?, room.errors.full_messages.to_sentence
    assert room.save
  end

  private
    def fill_to_limit(count)
      @hotel.rooms.destroy_all
      count.times { |i| @hotel.rooms.create!(number: "10#{i}") }
    end
end
