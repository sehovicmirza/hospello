require "test_helper"

# The budget guard is the only thing standing between a hotel and an
# unbounded API bill, and it reads exclusively from this table. Everything
# asserted here is about that reading being right — in the hotel's own
# timezone, counting the tokens that actually cost money, and failing towards
# "stop" rather than "carry on" when the numbers are missing or zero.
class AiRunTest < ActiveSupport::TestCase
  setup { @hotel = hotels(:stari_grad) }

  test "counts input and output tokens spent today" do
    with_tenant(@hotel) do
      record_run(input_tokens: 1_000, output_tokens: 200)
      record_run(input_tokens: 500, output_tokens: 50)

      assert_equal 1_750, AiRun.tokens_used_today(@hotel)
    end
  end

  # Guarded and failed runs write rows with missing token counts, and a
  # refusal can legitimately report input tokens with no output. In SQL a
  # NULL in either half makes the whole row's sum NULL, and SUM then skips
  # that row entirely — so without COALESCE a hotel's spend silently drops
  # every partially-counted run and the budget guard under-counts forever.
  test "a run with only half its token counts still contributes what it has" do
    with_tenant(@hotel) do
      record_run(status: :refusal, input_tokens: 100, output_tokens: nil)
      record_run(status: :circuit_open, input_tokens: nil, output_tokens: nil)

      assert_equal 100, AiRun.tokens_used_today(@hotel)
    end
  end

  # "Today" is the hotel's today. A Sarajevo hotel's budget must reset at
  # midnight in Sarajevo, not at midnight UTC — otherwise the reset lands in
  # the middle of the evening and the busiest hours run on yesterday's spend.
  test "today is measured in the hotel's own timezone" do
    with_tenant(@hotel) do
      local_midnight = Time.current.in_time_zone(@hotel.timezone).beginning_of_day

      record_run(input_tokens: 700, created_at: local_midnight + 5.minutes)
      record_run(input_tokens: 900, created_at: local_midnight - 5.minutes)

      assert_equal 700, AiRun.tokens_used_today(@hotel)
    end
  end

  # Asked for the hotel it was given, not for whichever hotel happens to be
  # the current tenant. The tenant scope alone would answer "how much has the
  # *current* hotel spent", which is the same number right up until a job
  # asks about a different one — and then it is silently the wrong hotel's
  # budget being enforced.
  test "counts the hotel it was asked about, not the current tenant" do
    with_tenant(@hotel) do
      record_run(input_tokens: 9_000, output_tokens: 9_000)

      assert_equal 0, AiRun.tokens_used_today(hotels(:vrelo))
    end
  end

  test "the concierge stops at 90% while translation may run to 100%" do
    with_tenant(@hotel) do
      @hotel.update!(ai_daily_token_budget: 1_000)
      record_run(input_tokens: 950, output_tokens: 0)

      assert AiRun.budget_exhausted_for?(@hotel, fraction: 0.9),
             "the concierge must stop at 90% so translation still has room"
      assert_not AiRun.budget_exhausted_for?(@hotel, fraction: 1.0),
                 "translation is the guest-to-receptionist lifeline and runs to the full budget"
    end
  end

  # A hotel typing 0 into a field labelled "daily token budget" means no AI.
  # Reading it as "unlimited" would hand them uncapped spend.
  test "a zero budget means no AI, not unlimited AI" do
    with_tenant(@hotel) do
      @hotel.update!(ai_daily_token_budget: 0)

      assert AiRun.budget_exhausted_for?(@hotel)
    end
  end

  private

  def record_run(status: :success, input_tokens: 0, output_tokens: 0, created_at: nil)
    AiRun.create!(
      hotel: @hotel, kind: :reply, status: status,
      input_tokens: input_tokens, output_tokens: output_tokens,
      created_at: created_at || Time.current
    )
  end
end
