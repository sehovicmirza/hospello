class Room < ApplicationRecord
  include TenantScoped
  include Activatable

  # A typo like "1-99999" must not silently generate 99,999 rows on a pilot
  # database — this is a real guard, not a nicety.
  class BulkRangeTooLarge < StandardError; end

  # Caps a single "from-to" range token.
  MAX_BULK_RANGE = 500

  # Caps the *total* rooms a single bulk-add would create, checked after
  # expanding every range and deduplicating. MAX_BULK_RANGE alone is not
  # enough: many individually-legal ranges (e.g. 200 comma-separated
  # "1-500"-shaped tokens) combine to the same six-figure-row problem
  # MAX_BULK_RANGE exists to prevent, from an input a few KB long. Review
  # round 1 measured ~153s and ~200,000 queries for exactly this shape
  # against the unbatched bulk_add loop in Staff::RoomsController — this
  # check rejects it before that loop ever starts.
  MAX_BULK_TOTAL = 2_000

  # A pasted list (Word, Excel, a PDF export) routinely carries characters
  # that read as whitespace but that String#squish, built on ASCII \s,
  # leaves untouched: NBSP renders as a normal space so it is treated as
  # one; zero-width characters render as nothing so they are dropped
  # outright. Left alone, either would save silently inside `number`,
  # producing a room no guest can type a matching string for. Built from
  # codepoints, not literal characters, so the source file itself stays
  # plain ASCII -- immune to an editor, terminal, or copy/paste silently
  # mangling an invisible character into a different one.
  NO_BREAK_SPACE = 0x00A0.chr(Encoding::UTF_8) # NO-BREAK SPACE
  ZERO_WIDTH_CODEPOINTS = [
    0x200B, # ZERO WIDTH SPACE
    0x200C, # ZERO WIDTH NON-JOINER
    0x200D, # ZERO WIDTH JOINER
    0xFEFF  # ZERO WIDTH NO-BREAK SPACE (byte-order mark)
  ].freeze
  ZERO_WIDTH_CHARACTERS = Regexp.union(ZERO_WIDTH_CODEPOINTS.map { |codepoint| codepoint.chr(Encoding::UTF_8) })

  before_validation :normalize_number

  validates :number, presence: true, uniqueness: { scope: :hotel_id }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:number) }

  class << self
    # The single normalization rule shared by every path that writes or reads
    # a room number: a room saved here, a guest typing " ph1 " into Slice 2's
    # entry form, and Slice 6's WhatsApp set_guest_room tool call all funnel
    # through this so they agree on what "the same room number" means.
    def normalize_number(raw)
      raw.to_s.tr(NO_BREAK_SPACE, " ").gsub(ZERO_WIDTH_CHARACTERS, "").squish.upcase
    end

    # Parses the bulk-add textarea into a deduplicated array of normalized
    # room-number strings, expanding numeric ranges like "101-110". Splits on
    # commas and newlines so either (or a mix) works as a separator.
    def parse_bulk(text)
      tokens = text.to_s.split(/[,\n]/).map { |token| normalize_number(token) }.reject(&:blank?)
      expanded = tokens.flat_map { |token| expand_token(token) }.uniq

      if expanded.size > MAX_BULK_TOTAL
        raise BulkRangeTooLarge,
          "this bulk add would create #{expanded.size} rooms, over the #{MAX_BULK_TOTAL}-room total limit"
      end

      expanded
    end

    private
      def expand_token(token)
        match = token.match(/\A(\d+)-(\d+)\z/)
        return [ token ] unless match

        from_str, to_str = match[1], match[2]
        from, to = from_str.to_i, to_str.to_i
        return [ token ] unless from <= to

        expand_range(from, to, leading_zero_width(from_str, to_str))
      end

      # A range's own display width, when either end was written with a
      # leading zero (its literal length exceeds its value's natural
      # length) — "001-003" must expand to ["001","002","003"], not
      # ["1","2","3"], or every room saved this way silently drops the
      # padding a guest would still be typing. "101-103" (no leading zero
      # on either end) is unaffected: width comes back 0, so rjust is a
      # no-op.
      def leading_zero_width(from_str, to_str)
        [ from_str, to_str ].map { |str| str.length > str.to_i.to_s.length ? str.length : 0 }.max
      end

      def expand_range(from, to, width)
        count = to - from + 1
        if count > MAX_BULK_RANGE
          raise BulkRangeTooLarge, "a range of #{count} rooms exceeds the #{MAX_BULK_RANGE}-room bulk-add limit"
        end

        (from..to).map { |n| n.to_s.rjust(width, "0") }
      end
  end

  private
    def normalize_number
      self.number = self.class.normalize_number(number)
    end
end
