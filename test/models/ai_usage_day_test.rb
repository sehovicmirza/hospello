require "test_helper"

# The rollup every analytics number and the daily budget guard read.
#
# One property carries this whole file: **the addition happens in Postgres.**
# Two AI calls finishing in the same instant must both be counted, and a
# read-modify-write loses one of them silently — a number quietly 3% low
# forever is worse than one that is obviously broken. Everything else here is
# about the second-most-likely mistake, which is reading "today" off the
# server's clock instead of the hotel's.
class AiUsageDayTest < ActiveSupport::TestCase
  setup do
    @hotel = hotels(:stari_grad)
    ActsAsTenant.current_tenant = @hotel
  end

  test "a first run creates the day and counts itself" do
    record(input_tokens: 900, output_tokens: 100, cache_read_tokens: 800)

    day = AiUsageDay.sole
    assert_equal 1, day.runs
    assert_equal 900, day.input_tokens
    assert_equal 100, day.output_tokens
    assert_equal 800, day.cache_read_tokens
    assert_equal 1000, day.total_tokens
    assert_equal 0, day.failures
  end

  # The one that matters. Broken into find_or_initialize + save, this passes
  # in a test and loses rows in production; the only way to see the difference
  # is to assert the sum.
  test "a second run adds to the first rather than replacing it" do
    3.times { record(input_tokens: 100, output_tokens: 10) }

    day = AiUsageDay.sole
    assert_equal 3, day.runs
    assert_equal 300, day.input_tokens
    assert_equal 30, day.output_tokens
  end

  # **This asserts the mechanism, not the outcome, and that is deliberate.**
  #
  # Every other test in this file passes just as happily against a
  # read-modify-write — measured, not assumed: replacing the upsert with
  # `find_or_initialize_by` + Ruby addition leaves the whole file green,
  # because a single-threaded test never produces the interleaving that loses
  # an update. The defect is invisible until production, which is exactly what
  # makes it worth a test of its own.
  #
  # So this pins the thing that provides the guarantee: the counters are
  # incremented by SQL that reads the row's *current* value inside one
  # statement Postgres executes, rather than by a number Ruby worked out from
  # an earlier read. Same reasoning, and the same shape, as this project's
  # constant-time signature test — assert the comparison used, not the timing.
  test "the counters are incremented by the database inside one statement" do
    statements = capture_sql { record(input_tokens: 5) }
    upsert = statements.find { |sql| sql.include?("ai_usage_days") && sql.include?("ON CONFLICT") }

    assert upsert, "the write is not an upsert at all: #{statements.inspect}"
    AiUsageDay::COUNTERS.each do |counter|
      assert_includes upsert, "#{counter} = ai_usage_days.#{counter} + EXCLUDED.#{counter}",
        "#{counter} is not accumulated by the database — a concurrent run will be lost silently"
    end
  end

  # An `after_create_commit` does not necessarily fire where the record was
  # built: wrap `with_tenant { AiRun.create! }` in an outer transaction and the
  # callback runs after that block has exited, with no tenant set. Every write
  # then raised `NoTenantSet` and the rollup silently recorded nothing.
  #
  # Nothing caught this because jobs hold the tenant for their whole duration
  # — db/seeds/demo.rb was the first caller with an enclosing transaction, and
  # it lost all 125 of its rollup writes on the first run.
  test "a run recorded from a commit outside any tenant still lands" do
    ActsAsTenant.current_tenant = nil

    ApplicationRecord.transaction do
      ActsAsTenant.with_tenant(@hotel) do
        AiRun.create!(hotel: @hotel, kind: :reply, status: :success, input_tokens: 250)
      end
    end

    assert_equal 250, with_tenant(@hotel) { AiUsageDay.sole.input_tokens }
  end

  # --- Failures ---------------------------------------------------------------

  # "How often did guests get the fallback message" is the health question
  # this table exists to make cheap.
  test "a failed run is counted as a failure and still counted as a run" do
    record(status: :timeout, input_tokens: 40)

    day = AiUsageDay.sole
    assert_equal 1, day.runs
    assert_equal 1, day.failures
    assert_equal 0, day.successes
  end

  # A call that timed out was still billed for whatever it consumed before
  # giving up, and a budget that ignored that would be a budget in name only.
  test "a failed run's tokens still count against the day" do
    record(status: :api_error, input_tokens: 500, output_tokens: 50)

    assert_equal 550, AiUsageDay.sole.total_tokens
  end

  # budget_blocked and circuit_open never reached the network at all, so
  # ai_runs leaves their token columns null. nil + integer raises inside the
  # upsert, which would take down the write path for the runs that most need
  # recording — they are the only trace that a guest got a fallback.
  test "a run that never reached the API records cleanly, with no tokens" do
    record(status: :circuit_open, input_tokens: nil, output_tokens: nil, cache_read_tokens: nil)

    day = AiUsageDay.sole
    assert_equal 1, day.runs
    assert_equal 1, day.failures
    assert_equal 0, day.total_tokens
  end

  test "successes and failures on one day are counted separately" do
    record(input_tokens: 10)
    record(status: :refusal, input_tokens: 10)

    day = AiUsageDay.sole
    assert_equal 2, day.runs
    assert_equal 1, day.failures
    assert_equal 1, day.successes
  end

  # --- Which day, and whose ------------------------------------------------

  # A Sarajevo hotel's day ends at 23:59 Sarajevo time. Anything reading the
  # server's date puts a late-evening conversation on tomorrow, which makes
  # both the analytics page and the budget guard wrong at exactly the hour a
  # hotel is busiest.
  test "the day is the hotel's own, not the server's" do
    assert_equal "Europe/Sarajevo", @hotel.timezone

    # 22:30 UTC on the 11th is 00:30 on the 12th in Sarajevo.
    record(created_at: Time.utc(2026, 8, 11, 22, 30))

    assert_equal Date.new(2026, 8, 12), AiUsageDay.sole.usage_on
  end

  test "two calendar days are two rows" do
    record(created_at: Time.utc(2026, 8, 10, 9))
    record(created_at: Time.utc(2026, 8, 11, 9))

    assert_equal [ Date.new(2026, 8, 10), Date.new(2026, 8, 11) ], AiUsageDay.ordered.pluck(:usage_on)
  end

  # "What did the concierge cost us versus translation" is the first question
  # anyone asks of these numbers, and a rollup that has already merged them
  # cannot answer it.
  test "the concierge and translation are counted apart" do
    record(kind: :reply, input_tokens: 900)
    record(kind: :translation, input_tokens: 60)

    assert_equal({ "reply" => 900, "translation" => 60 },
                 AiUsageDay.ordered.to_h { |day| [ day.kind, day.input_tokens ] })
  end

  # The mapping is AiRun's own, shared rather than copied — these two must
  # agree about which integer means `translation` forever.
  test "the kinds cannot drift from AiRun's" do
    assert_equal AiRun.kinds, AiUsageDay.kinds
  end

  # --- Tenancy --------------------------------------------------------------

  test "each hotel's usage lands on its own row" do
    record(input_tokens: 100)
    with_tenant(hotels(:vrelo)) { record(hotel: hotels(:vrelo), input_tokens: 7) }

    assert_equal 100, AiUsageDay.sole.input_tokens
    assert_equal 7, with_tenant(hotels(:vrelo)) { AiUsageDay.sole.input_tokens }
  end

  # --- The budget guard reads this now ----------------------------------------
  #
  # AiRun.tokens_used_today changed what it *reads*, not what it means. Its own
  # tests in ai_run_test.rb were not edited — if one had needed editing, that
  # would have been a product decision rather than a refactor.

  test "the budget guard sees a run the moment it is recorded" do
    assert_equal 0, AiRun.tokens_used_today(@hotel)

    record(input_tokens: 400, output_tokens: 100)

    assert_equal 500, AiRun.tokens_used_today(@hotel)
  end

  # Cached reads are billed at a fraction of the input price but are still
  # input tokens, and are already inside input_tokens — counting them a second
  # time would make the ceiling arbitrarily wrong for a hotel whose prompt is
  # mostly cache hits, which is every hotel with a knowledge base.
  test "cache reads are not double-counted against the budget" do
    record(input_tokens: 400, output_tokens: 100, cache_read_tokens: 350)

    assert_equal 500, AiRun.tokens_used_today(@hotel)
  end

  test "yesterday's usage does not count against today's budget" do
    record(created_at: 2.days.ago, input_tokens: 10_000)

    assert_equal 0, AiRun.tokens_used_today(@hotel)
  end

  # --- The backfill -----------------------------------------------------------
  #
  # Its one hard property is the opposite of #record!'s: running it twice must
  # produce the same numbers, not double them. Two write paths with opposite
  # semantics in one file is the most dangerous thing here, which is why they
  # are separate methods named for what they do.

  test "the backfill rebuilds a hotel's days from the runs that already exist" do
    record(input_tokens: 100, created_at: Time.utc(2026, 8, 10, 9))
    record(input_tokens: 40, created_at: Time.utc(2026, 8, 10, 11))
    record(kind: :translation, input_tokens: 6, created_at: Time.utc(2026, 8, 10, 11))
    AiUsageDay.delete_all

    assert_equal 2, AiUsageDay.rebuild_for(@hotel)

    assert_equal({ "reply" => 140, "translation" => 6 },
                 AiUsageDay.ordered.to_h { |day| [ day.kind, day.input_tokens ] })
  end

  # The backfill has to read the hotel's calendar too, and it is easy to write
  # one that does not — the live path and the rebuild compute the date in
  # separate places. Both timestamps below are the same UTC day and *different*
  # Sarajevo days, so a rebuild grouping on the server's date produces one row
  # where there should be two. Without this, `run.created_at.to_date` passes
  # every backfill test — measured.
  test "the backfill groups by the hotel's calendar, not the server's" do
    record(input_tokens: 5, created_at: Time.utc(2026, 8, 10, 9))   # 11:00 on the 10th in Sarajevo
    record(input_tokens: 9, created_at: Time.utc(2026, 8, 10, 22, 30)) # 00:30 on the 11th
    AiUsageDay.delete_all

    AiUsageDay.rebuild_for(@hotel)

    assert_equal [ [ Date.new(2026, 8, 10), 5 ], [ Date.new(2026, 8, 11), 9 ] ],
                 AiUsageDay.ordered.map { |day| [ day.usage_on, day.input_tokens ] }
  end

  test "running the backfill twice does not double the numbers" do
    record(input_tokens: 100)
    record(input_tokens: 40)

    2.times { AiUsageDay.rebuild_for(@hotel) }

    day = AiUsageDay.sole
    assert_equal 2, day.runs
    assert_equal 140, day.input_tokens
  end

  # A rebuild is also the repair anyone reaches for when the numbers are
  # doubted, so it has to correct a wrong row rather than add to it.
  test "the backfill corrects a row that had drifted" do
    record(input_tokens: 100)
    AiUsageDay.sole.update!(input_tokens: 999_999, runs: 42)

    AiUsageDay.rebuild_for(@hotel)

    day = AiUsageDay.sole
    assert_equal 100, day.input_tokens
    assert_equal 1, day.runs
  end

  # What this really guards is that a rebuild is *scoped*, not that it clears
  # the table and starts again — the obvious way to make "replace rather than
  # accumulate" true is a `delete_all` first, and that would take every other
  # hotel's rollup with it.
  #
  # It does NOT prove `hotel.ai_runs` is what provides the scoping: under the
  # rake task each hotel is wrapped in `with_tenant`, so a bare `AiRun.all`
  # is scoped identically and swapping them leaves this green (measured).
  # `hotel.ai_runs` earns its place against a caller that passes one hotel
  # while another is the ambient tenant, which is a caller bug rather than
  # something this test can produce.
  test "rebuilding one hotel leaves every other hotel's rollup alone" do
    with_tenant(hotels(:vrelo)) { record(hotel: hotels(:vrelo), input_tokens: 7) }
    record(input_tokens: 100)

    AiUsageDay.rebuild_for(@hotel)

    assert_equal 7, with_tenant(hotels(:vrelo)) { AiUsageDay.sole.input_tokens }
    assert_equal 100, AiUsageDay.sole.input_tokens
  end

  test "a hotel with no runs at all rebuilds to nothing, without raising" do
    assert_equal 0, AiUsageDay.rebuild_for(@hotel)
    assert_empty AiUsageDay.all
  end

  private
    # A real AiRun, saved — the rollup is written by AiRun's own
    # after_create_commit, so building one by hand here would test a method
    # nothing calls.
    def record(hotel: @hotel, kind: :reply, status: :success, created_at: nil,
               input_tokens: 0, output_tokens: 0, cache_read_tokens: 0)
      create = lambda do
        AiRun.create!(
          hotel: hotel, kind: kind, status: status, model: "claude-opus-5",
          input_tokens: input_tokens, output_tokens: output_tokens, cache_read_tokens: cache_read_tokens
        )
      end

      # travel_to rather than stamping created_at afterwards: the rollup is
      # written by AiRun's own after_create_commit, so the run has to actually
      # be created at that moment for the row to land on the right day — a
      # created_at patched in later would leave the rollup on today.
      created_at ? travel_to(created_at) { create.call } : create.call
    end

    def capture_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql]
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
