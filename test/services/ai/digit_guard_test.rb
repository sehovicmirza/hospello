require "test_helper"

module Ai
  # A table rather than a handful of examples, because the guard's value is
  # entirely in its edges: the interesting rows are the transposition, the
  # invented number, and the correctly-translated Arabic numerals that must
  # NOT trip it — a guard that fires on every correct Arabic translation gets
  # switched off within a day, and a switched-off guard protects nothing.
  class DigitGuardTest < ActiveSupport::TestCase
    SAFE = [
      [ "identical text", "Breakfast is at 07:00", "Breakfast is at 07:00" ],
      [ "a real translation, numbers intact", "Breakfast is at 07:00", "Doručak je u 07:00" ],
      [ "Arabic-Indic numerals", "Room 305", "الغرفة ٣٠٥" ],
      [ "Persian numerals", "Room 305", "اتاق ۳۰۵" ],
      [ "full-width numerals", "Room 305", "Room ３０５" ],
      [ "a dropped leading zero", "Breakfast at 07:00", "Doručak u 7:00" ],
      [ "a decimal comma", "It costs 12.5 KM", "Košta 12,5 KM" ],
      [ "no numbers at all on either side", "Extra towels please", "Molim dodatne peškire" ],
      [ "numbers in a different order", "Rooms 305 and 306", "306 i 305" ],
      [ "a repeated number kept twice", "2 towels and 2 pillows", "2 peškira i 2 jastuka" ]
    ].freeze

    UNSAFE = [
      [ "a transposition", "Room 305", "Room 350" ],
      [ "an invented leading digit", "Breakfast at 07:00", "Doručak u 17:00" ],
      [ "an extra number invented", "Room 305", "Rooms 305 and 306" ],
      [ "a number dropped entirely", "Is breakfast at 07:00 or 08:00?", "Kada je doručak?" ],
      [ "a repeat collapsed to one", "2 towels and 2 pillows", "2 peškira i jastuka" ],
      [ "a price changed", "It costs 12 KM", "Košta 20 KM" ],
      [ "a price changed after the decimal point", "It costs 12.5 KM", "Košta 12.9 KM" ],
      [ "a number spelled as a word", "2 towels", "Par peškira" ]
    ].freeze

    SAFE.each do |name, original, translation|
      test "safe: #{name}" do
        assert Ai::DigitGuard.safe?(original: original, translation: translation),
               "#{original.inspect} → #{translation.inspect} should have passed"
      end
    end

    UNSAFE.each do |name, original, translation|
      test "unsafe: #{name}" do
        assert_not Ai::DigitGuard.safe?(original: original, translation: translation),
                   "#{original.inspect} → #{translation.inspect} should have been caught"
      end
    end

    # The cost of strictness, asserted rather than left as a comment: a
    # translation that writes a number as a word is refused, the guest's own
    # words are delivered instead, and nobody is told a wrong number. If this
    # turns out to fire often in a pilot, the fix is the translator's prompt,
    # not a looser guard.
    test "the strict rule is deliberate: a number written as a word does not pass" do
      assert_not Ai::DigitGuard.safe?(original: "2 towels", translation: "A pair of towels")
    end

    test "numbers are extracted as integers, whatever script they were written in" do
      assert_equal [ 305 ], Ai::DigitGuard.numbers_in("الغرفة ٣٠٥")
      assert_equal [ 7, 0 ], Ai::DigitGuard.numbers_in("07:00")
      assert_equal [], Ai::DigitGuard.numbers_in("no numbers here")
      assert_equal [], Ai::DigitGuard.numbers_in(nil)
    end

    test "folding leaves everything that is not a digit alone" do
      assert_equal "الغرفة 305", Ai::DigitGuard.fold("الغرفة ٣٠٥")
      assert_equal "Soba 305", Ai::DigitGuard.fold("Soba 305")
    end
  end
end
