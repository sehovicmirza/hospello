# A question a guest asked that the hotel's knowledge base could not answer.
#
# This is the mechanism that makes the concierge get better at one specific
# hotel over time, and it is the honest answer to "what happens when the AI
# doesn't know?" — it says so, hands the guest to reception, and writes the
# gap down where the hotel will see it.
class CreateUnansweredQuestions < ActiveRecord::Migration[8.0]
  def change
    create_table :unanswered_questions do |t|
      # Same cascade reasoning as rooms — see create_rooms.rb.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }, index: false

      # Nullified rather than cascaded: the gap outlives the conversation
      # that revealed it. That is the whole point of the table.
      t.references :conversation, foreign_key: { on_delete: :nullify }

      # `question` is the normalized English-ish form the model produced;
      # `question_original` is what the guest actually typed, in their own
      # language. Both are kept because the staff screen groups by the first
      # and a hotel writing the answer needs to read the second.
      t.text :question, null: false
      t.text :question_original
      t.string :locale

      # A digest of the normalized question. Deduplication has to happen in
      # the database rather than in Ruby: two guests asking the same thing at
      # the same moment is exactly the case a find-then-create would get
      # wrong, and a list that shows "is there a pool?" fourteen times is a
      # list nobody reads.
      t.string :normalized_hash, null: false

      # What the hotel most needs to write down, first. Ordering the staff
      # screen by this is the only reason the count is stored rather than
      # derived.
      t.integer :asked_count, null: false, default: 1

      # new: 0, answered: 1, dismissed: 2.
      t.integer :status, null: false, default: 0

      # Set when a hotel answers the gap by writing a KB entry, so the screen
      # can show what the question turned into.
      t.references :kb_entry, foreign_key: { on_delete: :nullify }

      t.timestamps
    end

    # The deduplication guarantee itself, enforced by Postgres rather than by
    # application care. Scoped to the hotel so two hotels each keep their own
    # copy of the same question.
    add_index :unanswered_questions, [ :hotel_id, :normalized_hash ], unique: true

    # The staff screen's own read: this hotel's open gaps, most-asked first.
    add_index :unanswered_questions, [ :hotel_id, :status, :asked_count ]
  end
end
