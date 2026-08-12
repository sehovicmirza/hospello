require "test_helper"

module Analytics
  # The one object both analytics pages read, so that a hotel and the platform
  # can never see different numbers for the same thing.
  #
  # Two kinds of test here. The counting ones are ordinary. The **range** ones
  # are the reason the file is long: every date in this product is the hotel's
  # own date, and a report built from the server's calendar is wrong by a day
  # at exactly the hour a hotel is busiest — which is also the hour nobody is
  # looking at an analytics page to notice.
  class HotelReportTest < ActiveSupport::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      ActsAsTenant.current_tenant = @hotel
      # The fixtures ship one conversation and one message per hotel; every
      # count below is asserted as a delta against that, so a report that
      # silently returned everything ever would not pass by coincidence.
      #
      # Snapshotted as numbers, not as a HotelReport — the object queries
      # lazily on every call, so holding one and reading it after the test has
      # created rows returns the *new* count and the delta is always satisfied.
      # That mistake made four tests here pass against nothing at all.
      @baseline = {
        conversations: report.conversations, guests: report.guests,
        guest_messages: report.guest_messages, escalated: report.escalated,
        handled_by_assistant: report.handled_by_assistant
      }
    end

    # --- How much was it used --------------------------------------------------

    test "counts conversations, the distinct guests behind them, and what guests said" do
      2.times { |index| conversation_with_messages(guest_name: "Guest #{index}", messages: 2) }

      assert_equal @baseline[:conversations] + 2, report.conversations
      assert_equal @baseline[:guests] + 2, report.guests
      assert_equal @baseline[:guest_messages] + 4, report.guest_messages
    end

    # One guest whose chat was resolved and who started another is one person
    # served. Counting them twice flatters the number in exactly the situation
    # that is worst for them.
    test "one guest with two conversations is one guest, not two" do
      session = fresh_guest_session
      first = Conversation.create!(guest_session: session)
      first.update!(status: :resolved)
      Conversation.create!(guest_session: session)

      assert_equal @baseline[:conversations] + 2, report.conversations
      assert_equal @baseline[:guests] + 1, report.guests
    end

    # --- What the assistant handled ---------------------------------------------

    test "separates what the assistant finished from what a person had to take" do
      conversation_with_messages(guest_name: "Handled")
      escalated = conversation_with_messages(guest_name: "Escalated")
      escalated.update!(status: :escalated, escalated_at: Time.current, escalation_reason: :ai_uncertain)

      assert_equal @baseline[:escalated] + 1, report.escalated
      assert_equal @baseline[:handled_by_assistant] + 1, report.handled_by_assistant
    end

    # "0% escalated" reads as a triumph. A hotel with no traffic has not
    # achieved one, and a page that says so is lying with a true number.
    test "the escalation rate is absent rather than zero when nothing happened" do
      Conversation.destroy_all

      assert_equal 0, report.conversations
      assert_nil report.escalation_rate
    end

    test "the escalation rate is the share of conversations a person had to take" do
      Conversation.destroy_all
      3.times { |index| conversation_with_messages(guest_name: "G#{index}") }
      Conversation.last.update!(status: :escalated, escalated_at: Time.current, escalation_reason: :ai_uncertain)

      assert_in_delta 1.0 / 3, report.escalation_rate, 0.001
    end

    # --- What the hotel could not answer ----------------------------------------

    # The most actionable thing on the page, and the only one that comes back
    # as a list rather than a count: "guests keep asking about parking" tells a
    # hotel exactly what to go and write down.
    test "names the questions guests asked most, not the ones asked last" do
      UnansweredQuestion.record!(hotel: @hotel, question: "Asked once?")
      3.times { UnansweredQuestion.record!(hotel: @hotel, question: "Is there parking?") }
      2.times { UnansweredQuestion.record!(hotel: @hotel, question: "Do you have a gym?") }

      assert_equal [ "Is there parking?", "Do you have a gym?", "Asked once?" ],
                   report.top_unanswered.map(&:question)
    end

    # A question already written into the knowledge base is work somebody has
    # done; leaving it on the list asks them to do it twice.
    test "a question that has been answered drops off the list" do
      UnansweredQuestion.record!(hotel: @hotel, question: "Is there parking?")
      UnansweredQuestion.sole.update!(status: :answered)

      assert_empty report.top_unanswered
    end

    test "the list is capped so the page stays readable" do
      (HotelReport::TOP_QUESTIONS + 3).times { |index| UnansweredQuestion.record!(hotel: @hotel, question: "Q#{index}?") }

      assert_equal HotelReport::TOP_QUESTIONS, report.top_unanswered.size
    end

    # --- Requests ----------------------------------------------------------------

    test "counts requests and how many were finished" do
      request(status: :completed)
      request(quantity: "3")

      assert_equal 2, report.requests
      assert_equal 1, report.requests_completed
    end

    # Median, not mean: one request nobody noticed over a weekend drags an
    # average into uselessness, and what a hotel wants is "what usually
    # happens" rather than "what happened on average including the disaster".
    test "response time is the median, so one weekend disaster does not define it" do
      acknowledged_after(10.minutes, quantity: "1")
      acknowledged_after(20.minutes, quantity: "2")
      acknowledged_after(3.days, quantity: "3")

      assert_equal 20, report.median_response_minutes
    end

    test "response time is absent when nothing has been picked up yet" do
      request(quantity: "9")

      assert_nil report.median_response_minutes
    end

    # Deliberately not scoped to the range. "What is late" is a question about
    # right now, and a request that went overdue last month and is still
    # sitting there is the most urgent thing on the page.
    test "what is overdue is about now, not about the range" do
      @hotel.update!(overdue_after_minutes: 30)
      old = request(quantity: "7")
      old.update_columns(created_at: 90.days.ago)

      assert_equal 0, report.requests, "precondition: it is outside the reporting range"
      assert_equal 1, report.overdue_now
    end

    # --- The assistant ------------------------------------------------------------

    test "reports how much the assistant ran and how often it failed" do
      ai_run(input_tokens: 900, output_tokens: 100)
      ai_run(input_tokens: 400, output_tokens: 100, status: :timeout)

      assert_equal 2, report.ai_runs
      assert_equal 1, report.ai_failures
      assert_equal 1500, report.tokens
    end

    test "the concierge and translation are reported apart" do
      ai_run(input_tokens: 900)
      ai_run(input_tokens: 60, kind: :translation)

      assert_equal({ "reply" => 900, "translation" => 60 }, report.tokens_by_kind)
    end

    # The one AI number a hotel can act on: crossing this is what silences
    # their assistant. Token totals are the platform's cost driver, not the
    # hotel's — a hotel pays Hospello, not per token.
    test "budget usage is today's, against this hotel's own ceiling" do
      @hotel.update!(ai_daily_token_budget: 1000)
      ai_run(input_tokens: 400, output_tokens: 100)

      assert_in_delta 0.5, report.budget_used_fraction, 0.001
    end

    test "no budget set means no fraction, rather than a division by zero" do
      @hotel.update!(ai_daily_token_budget: 0)

      assert_nil report.budget_used_fraction
    end

    # --- The date range ------------------------------------------------------------

    test "the default range ends today and looks back a month" do
      assert_equal today_here, report.to
      assert_equal HotelReport::DEFAULT_DAYS, report.days
    end

    # A conversation at 23:30 in Sarajevo is inside the day a hotelier would
    # say it was, even though UTC has already moved on.
    test "a late-evening conversation belongs to the hotel's day, not UTC's" do
      late = conversation_with_messages(guest_name: "Late")
      # 22:30 UTC is 00:30 the next day in Sarajevo — so on the *previous*
      # Sarajevo day this row must fall outside, and on its own day inside.
      late.update_columns(created_at: Time.utc(2026, 8, 10, 22, 30))
      Conversation.where.not(id: late.id).destroy_all

      assert_equal 1, report(from: Date.new(2026, 8, 11), to: Date.new(2026, 8, 11)).conversations
      assert_equal 0, report(from: Date.new(2026, 8, 10), to: Date.new(2026, 8, 10)).conversations
    end

    test "a range that ends in the future is pulled back to today" do
      assert_equal today_here, report(to: today_here + 90).to
    end

    # A typo, not an error worth refusing over.
    test "a start after the end is clamped rather than raising" do
      built = report(from: today_here, to: today_here - 7)

      assert_operator built.from, :<=, built.to
    end

    test "an absurdly wide range is capped, and the report says what it really covers" do
      built = report(from: today_here - 5.years, to: today_here)

      assert_equal HotelReport::MAX_DAYS, built.days
    end

    # --- Isolation -------------------------------------------------------------------

    # The two hotels are given deliberately different numbers, so a report
    # accidentally scoped to every hotel is visibly wrong rather than
    # coincidentally right.
    #
    # What provides the isolation is **acts_as_tenant**, not the `hotel.`
    # prefix on each query — measured: swapping `hotel.unanswered_questions`
    # for a bare `UnansweredQuestion.all` leaves this green, because both are
    # tenant-scoped. The prefix still earns its place, and this is where the
    # two differ: built for hotel B while hotel A is the ambient tenant,
    # `hotel.unanswered_questions` returns nothing (both conditions apply,
    # nothing satisfies them) while `UnansweredQuestion.all` would confidently
    # report hotel A's numbers under hotel B's name. Failing empty is
    # recoverable; reporting the wrong hotel's data is not.
    test "one hotel's report can never include another hotel's activity" do
      with_tenant(hotels(:vrelo)) do
        4.times { |index| UnansweredQuestion.record!(hotel: hotels(:vrelo), question: "Vrelo #{index}?") }
      end

      assert_equal 0, report.unanswered_questions
      assert_equal 4, with_tenant(hotels(:vrelo)) { HotelReport.new(hotel: hotels(:vrelo)).unanswered_questions }
    end

    private
      def report(from: nil, to: nil) = HotelReport.new(hotel: @hotel, from: from, to: to)

      def today_here = Time.current.in_time_zone(@hotel.timezone).to_date

      def fresh_guest_session(name: "Analytics Guest")
        @hotel.guest_sessions.create!(
          guest_name: name, room: rooms(:stari_301), locale: "en", privacy_accepted_at: Time.current,
          expires_at: 7.days.from_now, token_digest: GuestSession.digest(SecureRandom.hex(16))
        )
      end

      def conversation_with_messages(guest_name:, messages: 0)
        conversation = Conversation.create!(guest_session: fresh_guest_session(name: guest_name))
        messages.times do |index|
          conversation.messages.create!(hotel: @hotel, sender_role: :guest, body: "Message #{index}")
        end
        conversation
      end

      def request(status: :new, quantity: "2")
        conversation = conversations(:stari_conversation)
        category = request_categories(:stari_towels)
        details = { "quantity" => quantity }

        ServiceRequest.create!(
          hotel: @hotel, conversation: conversation, guest_session: conversation.guest_session,
          room: conversation.guest_session.room, request_category: category, department: category.department,
          summary: "Towels x#{quantity}", details: details, channel: :web, status: status,
          dedupe_key: ServiceRequest.dedupe_key_for(conversation: conversation, category: category, details: details)
        )
      end

      def acknowledged_after(duration, quantity:)
        created = 5.days.ago
        request(quantity: quantity).tap do |built|
          built.update_columns(created_at: created, acknowledged_at: created + duration,
                               status: ServiceRequest.statuses[:accepted])
        end
      end

      def ai_run(kind: :reply, status: :success, input_tokens: 0, output_tokens: 0)
        AiRun.create!(hotel: @hotel, kind: kind, status: status, model: "claude-opus-5",
                      input_tokens: input_tokens, output_tokens: output_tokens)
      end
  end
end
