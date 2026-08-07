class Room < ApplicationRecord
  include TenantScoped

  # A typo like "1-99999" must not silently generate 99,999 rows on a pilot
  # database — this is a real guard, not a nicety.
  class BulkRangeTooLarge < StandardError; end

  MAX_BULK_RANGE = 500

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
      raw.to_s.squish.upcase
    end

    # Parses the bulk-add textarea into a deduplicated array of normalized
    # room-number strings, expanding numeric ranges like "101-110". Splits on
    # commas and newlines so either (or a mix) works as a separator.
    def parse_bulk(text)
      tokens = text.to_s.split(/[,\n]/).map { |token| normalize_number(token) }.reject(&:blank?)

      tokens.flat_map { |token| expand_token(token) }.uniq
    end

    private
      def expand_token(token)
        match = token.match(/\A(\d+)-(\d+)\z/)
        return [ token ] unless match && match[1].to_i <= match[2].to_i

        expand_range(match[1].to_i, match[2].to_i)
      end

      def expand_range(from, to)
        count = to - from + 1
        if count > MAX_BULK_RANGE
          raise BulkRangeTooLarge, "a range of #{count} rooms exceeds the #{MAX_BULK_RANGE}-room bulk-add limit"
        end

        (from..to).map(&:to_s)
      end
  end

  private
    def normalize_number
      self.number = self.class.normalize_number(number)
    end
end
