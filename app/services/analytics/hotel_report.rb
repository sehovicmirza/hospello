module Analytics
  # Everything one hotel can see about its own use of this product, over one
  # date range.
  #
  # **One object, not queries scattered through two controllers.** The platform
  # rollup asks the same questions of every hotel, and two implementations of
  # "how many conversations did a person have to take over" would disagree
  # within a month — at which point nobody could say which page was lying.
  #
  # It answers five questions and deliberately nothing else. A page with twelve
  # numbers on it is a page nobody reads twice, so the test applied to each
  # candidate here was: *does this change what somebody would do?*
  #
  #   1. How much was it used?
  #   2. How much did the assistant handle without a person?
  #   3. **What did guests ask that this hotel could not answer?** — the most
  #      actionable number on the page, and the only one that comes with a list
  #      rather than a count.
  #   4. How quickly did requests get picked up, and what is late right now?
  #   5. Is the assistant working, and how close is it to this hotel's budget?
  #
  # **"What is this costing us" is deliberately absent from the hotel's own
  # page**, which is a departure from the slice brief's own wording. A hotel
  # does not pay per token — it pays Hospello — so a token count is a number it
  # cannot act on. What it *can* act on is proximity to the daily budget that
  # will silence its assistant, which is `#budget_used_fraction`. Tokens belong
  # on the platform page, where they really are the cost driver.
  #
  # Every range is in the **hotel's own timezone**. A Sarajevo hotel's day ends
  # at 23:59 Sarajevo time, and a report built from `Date.current` would be off
  # by a day at exactly the hour a hotel is busiest.
  class HotelReport
    # Long enough to see a trend, short enough that the answer is about now.
    DEFAULT_DAYS = 30

    # A range wider than this scans more of the rollup than any question here
    # justifies. Clamped rather than refused — a hotelier who types a wide
    # range wants "as much as you have", not an error — and the page says which
    # range it is really showing.
    MAX_DAYS = 366

    # How many unanswered questions to name. A list, not a count, because
    # "guests keep asking about parking" is the one thing on this page that
    # tells a hotel exactly what to go and write down.
    TOP_QUESTIONS = 5

    attr_reader :hotel, :from, :to

    # @param from [Date, nil] inclusive, in the hotel's timezone
    # @param to [Date, nil] inclusive
    def initialize(hotel:, from: nil, to: nil)
      @hotel = hotel
      @to = clamp_end(to)
      @from = clamp_start(from, @to)
    end

    def days = (from..to).count

    # --- 1. How much was it used? --------------------------------------------

    def conversations = for_hotel { scoped(Conversation).count }

    # Distinct guests, not conversations: one guest whose chat was resolved and
    # who started another is one person served, and counting them twice would
    # flatter the number in exactly the situation that is worst for them.
    def guests = for_hotel { scoped(Conversation).distinct.count(:guest_session_id) }

    def guest_messages = for_hotel { scoped(hotel.messages.where(sender_role: :guest)).count }

    # --- 2. What did the assistant handle? -----------------------------------

    def escalated = for_hotel { scoped(Conversation).where.not(escalated_at: nil).count }

    def handled_by_assistant = conversations - escalated

    # nil rather than 0 when there were no conversations at all: "0% escalated"
    # reads as a triumph, and a hotel with no traffic has not achieved one.
    def escalation_rate
      return nil if conversations.zero?

      escalated.fdiv(conversations)
    end

    # --- 3. What could this hotel not answer? --------------------------------

    def unanswered_questions = for_hotel { scoped(hotel.unanswered_questions).count }

    # Ordered by how often each was asked, not by recency: the question five
    # guests asked matters more than the one asked last night. A question
    # already answered into the knowledge base — or dismissed — is work
    # somebody has already done, and leaving it here asks them to do it twice.
    #
    # `open_gaps` is the knowledge-gap screen's own scope, reused rather than
    # restated: this list and that screen must never disagree about which
    # questions are still outstanding.
    def top_unanswered
      # .to_a, not a relation: a relation is lazy, and this is read by a view
      # that runs outside whatever tenant block built the report. See #for_hotel.
      for_hotel { scoped(hotel.unanswered_questions).open_gaps.limit(TOP_QUESTIONS).to_a }
    end

    # --- 4. Requests ----------------------------------------------------------

    def requests = for_hotel { scoped(hotel.service_requests).count }

    def requests_completed = for_hotel { scoped(hotel.service_requests).where(status: :completed).count }

    # Median, not mean: one request nobody noticed over a weekend drags an
    # average into uselessness, and the number a hotel wants is "what usually
    # happens" rather than "what happened on average including the disaster".
    #
    # Measured to the moment a person *accepted* it, not to completion — that
    # is the number reception controls, and the one a guest feels.
    def median_response_minutes
      seconds = for_hotel do
        scoped(hotel.service_requests).where.not(acknowledged_at: nil)
          .pluck(:created_at, :acknowledged_at).map { |created, acknowledged| acknowledged - created }
      end
      return nil if seconds.empty?

      (median(seconds) / 60).round
    end

    # Deliberately **not** scoped to the range: "what is late" is a question
    # about right now, and a request that went overdue last month and is still
    # sitting there is the most urgent thing on this page. Reads the same
    # ServiceRequest#overdue? every other screen does.
    def overdue_now = for_hotel { hotel.service_requests.open_requests.select(&:overdue?).count }

    # --- 5. Is the assistant working? -----------------------------------------

    def ai_runs = for_hotel { usage.sum(:runs) }

    def ai_failures = for_hotel { usage.sum(:failures) }

    def tokens = for_hotel { usage.sum(Arel.sql("input_tokens + output_tokens")) }

    def tokens_by_kind = for_hotel { usage.group(:kind).sum(Arel.sql("input_tokens + output_tokens")) }

    # Today's usage against this hotel's daily budget — the one AI number a
    # hotel can act on, because crossing it is what silences the assistant.
    # nil when no budget is set at all, rather than dividing by zero.
    def budget_used_fraction
      budget = hotel.ai_daily_token_budget.to_i
      return nil if budget.zero?

      for_hotel { AiRun.tokens_used_today(hotel) }.fdiv(budget)
    end

    private
      # Every reader runs inside its own hotel's tenant, so a report is safe to
      # read from anywhere — including a view rendering long after whatever
      # block built it. That is not a convenience: the platform rollup builds
      # one report per hotel in a controller and reads them all in a template,
      # and without this every query lands outside the tenant and
      # acts_as_tenant raises NoTenantSet. It did, which is the fail-closed
      # behaviour working exactly as designed.
      #
      # Nesting is harmless where a tenant is already set (the staff page), and
      # this is with_tenant — never one of the escape hatches
      # test/tenancy/without_tenant_grep_test.rb polices, which is the whole
      # point: the report narrows to one hotel, it never widens past one.
      def for_hotel(&block) = ActsAsTenant.with_tenant(hotel, &block)

      # Every range is the hotel's own calendar, which is also how
      # AiUsageDay#usage_on is stored — so the rollup needs no conversion and
      # cannot disagree with the row-level queries beside it.
      def today = Time.current.in_time_zone(hotel.timezone).to_date

      def clamp_end(given)
        [ given&.to_date || today, today ].min
      end

      # A start after the end is a typo, not an error worth refusing over —
      # and a range longer than MAX_DAYS is clamped rather than run.
      def clamp_start(given, ending)
        earliest = ending - (MAX_DAYS - 1)
        requested = given&.to_date || (ending - (DEFAULT_DAYS - 1))

        [ [ requested, ending ].min, earliest ].max
      end

      # The range as timestamps, for the tables that store one. Built from the
      # hotel's own midnights so a conversation at 23:30 local is inside the
      # day a hotelier would say it was.
      def window
        zone = ActiveSupport::TimeZone[hotel.timezone]

        zone.local(from.year, from.month, from.day).beginning_of_day..
          zone.local(to.year, to.month, to.day).end_of_day
      end

      def scoped(relation) = relation.where(created_at: window)

      def usage = hotel.ai_usage_days.where(usage_on: from..to)

      def median(values)
        sorted = values.sort
        middle = sorted.size / 2

        sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
      end
  end
end
