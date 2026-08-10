# One row per attempt to use a model, whatever the outcome.
#
# This is not a log table — logs get rotated and nobody reads them. It is the
# answer to the four questions this product will actually be asked: what did
# the AI cost us this month, is it working, which hotel's knowledge base is
# doing the work, and why did a guest get a "reception will reply personally"
# message at 02:00 last Tuesday. A run is written for the guarded cases too
# (budget blocked, breaker open) precisely because those are the ones where
# nothing else leaves a trace.
class CreateAiRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_runs do |t|
      # Same cascade reasoning as rooms — see create_rooms.rb.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }, index: false

      # Both nullable: a run can be blocked before a reply message exists,
      # and nullify-on-delete rather than cascade so that deleting a
      # conversation does not silently erase the spend it accounted for.
      t.references :conversation, foreign_key: { on_delete: :nullify }
      t.references :message, foreign_key: { on_delete: :nullify }

      # reply: 0, translation: 1. Translation (Slice 5) shares this table
      # because "what did AI cost this hotel" has to be one query, not two.
      t.integer :kind, null: false

      # The resolved model id, recorded rather than assumed: AI_MODEL can
      # change between two runs, and a cost or quality regression that
      # followed a model change is unreadable without this column.
      t.string :model

      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cache_read_tokens
      t.integer :latency_ms

      # success: 0, timeout: 1, api_error: 2, refusal: 3, budget_blocked: 4,
      # circuit_open: 5.
      t.integer :status, null: false

      # Which knowledge-base entries the model said it used. An array rather
      # than a join table: it is written once, read for analytics, and never
      # queried the other way round ("which conversations cited entry 12" is
      # not a question this product asks).
      t.integer :cited_kb_entry_ids, array: true, null: false, default: []

      t.string :error_class

      t.timestamps
    end

    # The two reads this table exists for: today's token spend for a hotel
    # (the budget guard, which runs before every single AI turn) and the
    # hotel's recent run history.
    add_index :ai_runs, [ :hotel_id, :created_at ]
    add_index :ai_runs, [ :hotel_id, :status, :created_at ]
  end
end
