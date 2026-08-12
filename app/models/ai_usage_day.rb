# One row per hotel per day per kind — the table every analytics number and
# the daily budget guard read.
#
# **Why a rollup at all, when `ai_runs` already has every call:** an analytics
# page shows a month and the platform rollup shows every hotel at once. Both
# are `GROUP BY` over a table that grows by one row per AI call forever, and
# the first hotel with a busy fortnight makes those pages the slowest thing in
# the app. This table is bounded by hotels × days × 2.
#
# **The addition happens in Postgres, never in Ruby.** Two AI calls finishing
# in the same instant must both be counted, and a read-modify-write loses one
# of them silently — a number quietly 3% low forever is worse than one that is
# obviously broken. Same reasoning as Message#claim_translation! and
# #claim_delivery!, applied to arithmetic rather than to a state change.
class AiUsageDay < ApplicationRecord
  include TenantScoped

  # Literally AiRun's own mapping, not a copy of it: these two must agree
  # about which integer means `translation` forever, and a second hand-written
  # hash is a second thing to get wrong.
  enum :kind, AiRun.kinds

  scope :ordered, -> { order(:usage_on, :kind) }
  scope :between, ->(from, to) { where(usage_on: from..to) }

  # The columns Postgres adds to on conflict. Named once so the upsert below
  # and any future caller cannot disagree about what accumulates.
  COUNTERS = %i[runs input_tokens output_tokens cache_read_tokens failures].freeze

  class << self
    # Records one AiRun into its hotel's day.
    #
    # Called from AiRun's own after_create_commit rather than from the two
    # jobs that build them, so a third caller cannot forget it and the two
    # cannot drift — the same reasoning Conversation#broadcast_new_message
    # documents about having one guard in one place rather than six.
    #
    # upsert_all, not find_or_initialize: this is the atomic guarantee above,
    # and it is expressed as Rails' own upsert rather than raw SQL precisely
    # so it does not need one of the tenant-scope escape hatches
    # test/tenancy/without_tenant_grep_test.rb polices.
    # Sets its own tenant from the run rather than relying on an ambient one.
    #
    # This is called from an `after_create_commit`, and a commit does not
    # necessarily happen where the record was built: wrap an
    # `ActsAsTenant.with_tenant(hotel) { AiRun.create!(...) }` in an outer
    # transaction and the callback fires *after* that block has exited, with
    # no tenant set, and every one of these raises `NoTenantSet`. Jobs happen
    # not to do that — they hold the tenant for their whole duration — which is
    # why nothing caught it until db/seeds/demo.rb wrapped a seed in one
    # transaction and lost all 125 of its rollup writes.
    #
    # The run knows its own hotel, so nothing here needs to be told: narrowing
    # to that hotel is always correct and never widens past one.
    def record!(run)
      ActsAsTenant.with_tenant(run.hotel) do
        upsert_all(
          [ row_for(run) ],
          unique_by: %i[hotel_id usage_on kind],
          on_duplicate: accumulate
        )
      end
    end

    # Rebuilds a hotel's rollup from the `ai_runs` rows that already exist —
    # for the one-off backfill (lib/tasks/ai_usage.rake), and as the repair
    # anyone reaches for if these numbers are ever doubted.
    #
    # **Replaces rather than accumulates**, which is the opposite of #record!
    # and is the whole reason it is a separate method: running a backfill twice
    # must produce the same numbers, and an accumulating upsert would double
    # them. That difference is the single most dangerous thing in this file, so
    # the two write paths are named for what they do rather than sharing one
    # method with a flag.
    #
    # Runs entirely in Ruby rather than in a `GROUP BY` over an expression like
    # `(created_at AT TIME ZONE ...)::date`: the grouping key is the hotel's
    # own date, one hotel at a time, and the SQL version would need a
    # tenant-scope escape hatch (see test/tenancy/without_tenant_grep_test.rb)
    # to be worth writing. At pilot scale this is a few thousand rows.
    def rebuild_for(hotel)
      rows = hotel.ai_runs.find_each.group_by { |run| [ usage_date_for(run), run.kind ] }.map do |(date, kind), runs|
        now = Time.current

        {
          hotel_id: hotel.id, usage_on: date, kind: kinds.fetch(kind),
          runs: runs.size,
          input_tokens: runs.sum { |run| run.input_tokens.to_i },
          output_tokens: runs.sum { |run| run.output_tokens.to_i },
          cache_read_tokens: runs.sum { |run| run.cache_read_tokens.to_i },
          failures: runs.count { |run| !run.success? },
          created_at: now, updated_at: now
        }
      end
      return 0 if rows.empty?

      upsert_all(rows, unique_by: %i[hotel_id usage_on kind], on_duplicate: replace)
      rows.size
    end

    # The date is the **hotel's**, not the server's: a Sarajevo hotel's day
    # ends at 23:59 Sarajevo time, and a run at 00:30 local belongs to the new
    # day even though UTC still says yesterday. Derived from the run's own
    # created_at rather than from Time.current so a backfill lands rows on the
    # day they actually happened.
    def usage_date_for(run)
      run.created_at.in_time_zone(run.hotel.timezone).to_date
    end

    private
      def row_for(run)
        now = Time.current

        {
          hotel_id: run.hotel_id,
          usage_on: usage_date_for(run),
          kind: kinds.fetch(run.kind),
          runs: 1,
          # to_i on all three: ai_runs allows nulls (a run blocked by the
          # budget or an open breaker never reached the API and has no token
          # counts at all), and nil + integer would raise inside the upsert.
          input_tokens: run.input_tokens.to_i,
          output_tokens: run.output_tokens.to_i,
          cache_read_tokens: run.cache_read_tokens.to_i,
          # Their tokens are still counted above — a failed call is still
          # billed — but "how often did guests get the fallback message" is
          # the health question this table exists to make cheap.
          failures: run.success? ? 0 : 1,
          created_at: now, updated_at: now
        }
      end

      def accumulate
        sums = COUNTERS.map { |column| "#{column} = ai_usage_days.#{column} + EXCLUDED.#{column}" }

        Arel.sql((sums + [ "updated_at = EXCLUDED.updated_at" ]).join(", "))
      end

      # `=` rather than `+=` — see .rebuild_for for why that distinction is
      # load-bearing rather than cosmetic.
      def replace
        sets = COUNTERS.map { |column| "#{column} = EXCLUDED.#{column}" }

        Arel.sql((sets + [ "updated_at = EXCLUDED.updated_at" ]).join(", "))
      end
  end

  def total_tokens = input_tokens + output_tokens

  # Runs that actually reached the model and came back. Derived rather than
  # stored: one number that can never disagree with the two it comes from.
  def successes = runs - failures
end
