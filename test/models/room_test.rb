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

  # Review round 1: MAX_BULK_RANGE alone caps one "from-to" token, but many
  # individually-legal ranges combine past it — 200 ranges of exactly 500
  # (the cap) is still 100,000 rooms from one paste. This is the shape
  # measured taking ~153s and ~200,000 queries against the unfixed
  # bulk_add loop.
  test "parse_bulk refuses combined legal ranges that would still create too many rooms" do
    text = (1..200).map { |i| "#{(i - 1) * 500 + 1}-#{i * 500}" }.join(",")

    assert_raises(Room::BulkRangeTooLarge) { Room.parse_bulk(text) }
  end

  test "parse_bulk allows combined ranges at exactly the 2,000-room total cap" do
    assert_equal 2000, Room.parse_bulk("1-500,501-1000,1001-1500,1501-2000").size
  end

  test "parse_bulk refuses combined ranges one room over the total cap" do
    assert_raises(Room::BulkRangeTooLarge) { Room.parse_bulk("1-500,501-1000,1001-1500,1501-2000,2001") }
  end

  # Review round 1: a hotel with rooms 001-050 that bulk-adds "001-050" saw
  # "50 rooms added" but every one was actually stored unpadded ("1".."50"),
  # so a guest typing the number printed on the door (e.g. "007") was always
  # turned away — normalize_number("007") is "007" and never matches the
  # stored "7". The single-add path already preserved this; only the range
  # expander destroyed it.
  test "parse_bulk preserves a leading-zero width written on either end of a range" do
    assert_equal %w[001 002 003], Room.parse_bulk("001-003")
  end

  test "parse_bulk does not invent padding for a range with no leading zero on either end" do
    assert_equal %w[101 102 103], Room.parse_bulk("101-103")
  end

  test "parse_bulk pads to the wider end when only one side of a range has a leading zero" do
    assert_equal %w[005 006 007 008 009 010], Room.parse_bulk("005-010")
  end

  # Review round 1: a paste from Word, Excel, or a PDF export routinely
  # carries a non-breaking space or a zero-width character that
  # String#squish (built on ASCII \s) leaves untouched — the room would
  # save with an invisible character baked into `number`, which no guest
  # could ever type a matching string for.
  test "parse_bulk strips non-breaking spaces that a paste can carry" do
    non_breaking_space = 0x00A0.chr(Encoding::UTF_8)
    assert_equal %w[PH1], Room.parse_bulk("#{non_breaking_space}PH1#{non_breaking_space}")
  end

  test "parse_bulk strips zero-width characters that a paste can carry" do
    zero_width_space = 0x200B.chr(Encoding::UTF_8)
    assert_equal %w[PH1], Room.parse_bulk("P#{zero_width_space}H1")
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

  # Blank is the most common bad input this method sees in practice (an
  # empty guest entry form field) — behavior was already safe (normalizes
  # to "", which no room's number can equal), just unpinned by a test.
  test "find_active_room returns nil for blank or nil input rather than raising or matching everything" do
    hotel = hotels(:stari_grad)
    with_tenant(hotel) do
      assert_nil hotel.find_active_room("")
      assert_nil hotel.find_active_room("   ")
      assert_nil hotel.find_active_room(nil)
    end
  end
end
