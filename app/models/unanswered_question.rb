# Something a guest asked that this hotel had never written down.
#
# The concierge only answers from the hotel's published knowledge base, so
# every gap in that knowledge base is a guest who got "I'll pass that to
# reception" instead of an answer. This is where those land, deduplicated and
# counted, so a hotel can see what it is repeatedly failing to answer and fix
# it once.
class UnansweredQuestion < ApplicationRecord
  include TenantScoped

  MAX_QUESTION_LENGTH = 500

  # `prefix: true` because the plain value name is `new`, and an enum scope
  # called `new` would shadow the class constructor. The stored integers are
  # unchanged; only the Ruby spelling gains the prefix (`status_new?`).
  enum :status, { new: 0, answered: 1, dismissed: 2 }, prefix: true

  belongs_to :conversation, optional: true
  belongs_to :kb_entry, optional: true

  validates :question, presence: true, length: { maximum: MAX_QUESTION_LENGTH }
  validates :normalized_hash, presence: true

  before_validation :assign_normalized_hash

  # What the staff screen shows: open gaps, most-asked first. The count is
  # the whole point of the ordering — a hotel should write the answer to the
  # question fourteen guests asked before the one asked once.
  scope :open_gaps, -> { status_new.order(asked_count: :desc, id: :asc) }

  class << self
    # Record a gap, or count another guest hitting the same one.
    #
    # Deduplication is done by the database, not by a find-then-create: two
    # guests asking the same thing in the same second is exactly the race a
    # Ruby-level check loses, and the result would be a list showing the same
    # question twice with a count of 1 each. The unique index on
    # [hotel_id, normalized_hash] is what actually guarantees this; the
    # rescue below is the loser of that race counting itself in.
    #
    # A repeat never overwrites the stored text or re-opens a dismissed
    # question — a hotel that decided a question was not worth answering
    # should not have that decision undone by the next guest to ask it.
    def record!(hotel:, question:, question_original: nil, locale: nil, conversation: nil)
      question = question.to_s.strip.truncate(MAX_QUESTION_LENGTH)
      digest = normalize_and_digest(question)

      create!(
        hotel: hotel, conversation: conversation, question: question,
        question_original: question_original.presence&.truncate(MAX_QUESTION_LENGTH),
        locale: locale, normalized_hash: digest
      )
    rescue ActiveRecord::RecordNotUnique
      existing = find_by!(normalized_hash: digest)
      existing.increment!(:asked_count)
      existing
    end

    # Case, punctuation and spacing are noise here: "Is there a pool?",
    # "is there a pool" and "Is  there  a POOL ?" are one gap, and a hotel
    # seeing them as three would conclude the feature is broken.
    #
    # Deliberately not stemming or lemmatizing. That would fold genuinely
    # different questions together ("can I book a taxi" / "can I book a
    # table") and a false merge is much worse than a false split: the split
    # is visible and tidy-able, the merge silently hides a question.
    def normalize_and_digest(question)
      normalized = question.to_s.downcase.gsub(/[^\p{Alnum}\s]/, " ").squish
      Digest::SHA256.hexdigest(normalized)
    end
  end

  private
    def assign_normalized_hash
      self.normalized_hash = self.class.normalize_and_digest(question) if normalized_hash.blank?
    end
end
