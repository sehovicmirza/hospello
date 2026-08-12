class CreateAiUsageDays < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_usage_days do |t|
      # Cascades at the DB level rather than a Ruby-level dependent: :destroy,
      # for the same ActsAsTenant::Errors::NoTenantSet reasoning documented on
      # Hotel's other associations. index: false — the composite unique index
      # below already leads with hotel_id.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }, index: false

      # The date **in the hotel's own timezone**, not the server's. A Sarajevo
      # hotel's day ends at 23:59 Sarajevo time, and a guest who messages at
      # 00:30 local is on the new day even though UTC still says yesterday.
      # A `date`, not a datetime: this column is the grouping key, and storing
      # a moment would invite a second, subtly different reading of "which
      # day" every time something queried it.
      t.date :usage_on, null: false

      # Mirrors ai_runs.kind (reply: 0, translation: 1) rather than summing
      # across both, because "what did the concierge cost us versus
      # translation" is the first question anyone asks of these numbers, and a
      # rollup that has already thrown that distinction away cannot answer it.
      t.integer :kind, null: false

      # Counts, added to atomically by Postgres itself — see
      # AiUsageDay.record!. Never read-modify-written in Ruby: two AI calls
      # finishing in the same instant must both be counted, and a lost update
      # here is invisible forever rather than loud.
      t.integer :runs, null: false, default: 0
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.integer :cache_read_tokens, null: false, default: 0

      # Runs that did not end in `success` — timeouts, API errors, refusals,
      # and the two that never reached the network at all (budget_blocked,
      # circuit_open). Counted separately rather than derived, because "how
      # often did guests get the fallback message" is the health question this
      # table exists to make cheap. Their tokens are still counted above: a
      # failed call is still billed.
      t.integer :failures, null: false, default: 0

      t.timestamps
    end

    # One row per hotel per day per kind — and the conflict target the atomic
    # upsert keys on, which is the only reason this index is load-bearing
    # rather than merely useful.
    add_index :ai_usage_days, %i[hotel_id usage_on kind], unique: true
  end
end
