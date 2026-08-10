module Ai
  # The one mechanical check standing between a fluent translation and a
  # harmful one.
  #
  # "Room 305" delivered as "room 350", "07:00" as "17:00", "12 KM" as
  # "20 KM" — each is a confident, well-formed sentence that a receptionist
  # will act on, and none of them look wrong. Everything else in the
  # translation pipeline is machinery; this is what decides whether the
  # machinery is safe to switch on.
  #
  # **The rule is strict equality of the numbers, as a multiset.** Not "no
  # invented numbers", which would let a translation quietly drop the time out
  # of "is breakfast at 07:00 or 08:00" and hand a receptionist a question
  # they cannot answer. The cost of strictness is real and worth stating: a
  # translation that spells a number as a word ("two towels" → a language's
  # word for a pair) fails the guard and falls back to the original. That
  # costs readability — the receptionist reads the guest's own language and
  # has to tap — and never costs correctness, which is the right way round.
  # The translator's prompt therefore insists on digits.
  class DigitGuard
    # Every digit system a guest of these hotels might plausibly type, folded
    # to ASCII before anything is compared. Without this, an Arabic message
    # whose numbers came back correctly — as ٣٠٥ — would read as "all numbers
    # lost" and fall back every single time, which is the failure mode that
    # turns a safety check into a switched-off safety check.
    DIGIT_FOLDS = {
      "٠" => "0", "١" => "1", "٢" => "2", "٣" => "3", "٤" => "4", # Arabic-Indic ٠-٤
      "٥" => "5", "٦" => "6", "٧" => "7", "٨" => "8", "٩" => "9", # Arabic-Indic ٥-٩
      "۰" => "0", "۱" => "1", "۲" => "2", "۳" => "3", "۴" => "4", # Persian ۰-۴
      "۵" => "5", "۶" => "6", "۷" => "7", "۸" => "8", "۹" => "9", # Persian ۵-۹
      "０" => "0", "１" => "1", "２" => "2", "３" => "3", "４" => "4", # full-width ０-４
      "５" => "5", "６" => "6", "７" => "7", "８" => "8", "９" => "9"  # full-width ５-９
    }.freeze

    class << self
      def safe?(original:, translation:)
        numbers_in(original).tally == numbers_in(translation).tally
      end

      # Maximal digit runs, compared as integers.
      #
      # Runs rather than whole numeric tokens, and integers rather than
      # strings, so that the differences that are only formatting stop being
      # differences: "07:00" and "7:00" both give [7, 0], and "12.5" and
      # "12,5" both give [12, 5]. What is left is the thing that matters —
      # which numbers were said.
      def numbers_in(text)
        fold(text).scan(/\d+/).map(&:to_i)
      end

      def fold(text)
        text.to_s.gsub(/[#{DIGIT_FOLDS.keys.join}]/, DIGIT_FOLDS)
      end
    end
  end
end
