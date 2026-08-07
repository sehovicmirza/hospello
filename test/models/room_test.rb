require "test_helper"

class RoomTest < ActiveSupport::TestCase
  test "parse_bulk expands numeric ranges and splits on commas and newlines" do
    assert_equal %w[101 102 103 201 202], Room.parse_bulk("101-103, 201\n202")
  end

  test "parse_bulk keeps non-numeric room labels intact" do
    assert_equal %w[PH1 A12], Room.parse_bulk("PH1, A12")
  end

  test "parse_bulk deduplicates and ignores blanks" do
    assert_equal %w[101 102], Room.parse_bulk("101, 101, ,102")
  end

  test "parse_bulk refuses an absurd range rather than generating 100k rooms" do
    assert_raises(Room::BulkRangeTooLarge) { Room.parse_bulk("1-99999") }
  end

  # The cap itself needs its own boundary test — "refuses an absurd range"
  # above would still pass if the real cap were 10 or 10,000; only a test at
  # the exact edge pins it at 500 rooms.
  test "parse_bulk allows a range at exactly the 500-room cap" do
    assert_equal 500, Room.parse_bulk("1-500").size
  end

  test "parse_bulk refuses a range one room over the cap" do
    assert_raises(Room::BulkRangeTooLarge) { Room.parse_bulk("1-501") }
  end

  test "parse_bulk normalizes case and whitespace on non-numeric labels too" do
    assert_equal %w[PH1], Room.parse_bulk(" ph1 ")
  end

  test "number is required" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      room = hotel.rooms.new(number: "")
      assert_not room.valid?
    end
  end

  test "number must be unique within a hotel, case- and whitespace-insensitively" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      hotel.rooms.create!(number: "101")
      duplicate = hotel.rooms.new(number: " 101 ")

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:number], "has already been taken"
    end
  end

  test "the same number may be reused by a different hotel" do
    with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).rooms.create!(number: "101") }

    with_tenant(hotels(:vrelo)) do
      room = hotels(:vrelo).rooms.new(number: "101")
      assert room.valid?
    end
  end

  test "find_active_room normalizes case and whitespace" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      room = hotel.rooms.create!(number: "PH1")
      assert_equal room, hotel.find_active_room(" ph1 ")
      assert_nil hotel.find_active_room("PH2")
    end
  end

  test "find_active_room ignores inactive rooms" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      hotel.rooms.create!(number: "999", active: false)
      assert_nil hotel.find_active_room("999")
    end
  end
end
