module Ai
  # What one concierge turn produced — the thing `Ai::GenerateReplyJob` acts
  # on, and the thing an `AiRun` row is written from.
  #
  # It reports failure as data rather than as an exception on purpose. Every
  # failure mode here has the same handling (write the run, post the
  # pre-translated fallback, escalate), and expressing that as five rescue
  # clauses in the job would make it easy for a sixth failure to arrive later
  # with no handling at all.
  class Outcome
    # Deliberately the same names as AiRun's status enum, so the job never has
    # to translate between two vocabularies for the same concept.
    STATUSES = %i[success timeout api_error refusal].freeze

    attr_reader :status, :text, :cited_kb_entry_ids, :usage, :model, :latency_ms, :error_class

    def initialize(
      status:, text: "", cited_kb_entry_ids: [], usage: Result::Usage.new,
      model: nil, latency_ms: nil, error_class: nil
    )
      raise ArgumentError, "unknown status #{status.inspect}" unless STATUSES.include?(status)

      @status = status
      @text = text
      @cited_kb_entry_ids = cited_kb_entry_ids
      @usage = usage
      @model = model
      @latency_ms = latency_ms
      @error_class = error_class
    end

    # The only question the job asks before deciding between posting this and
    # posting the fallback. Anything that is not a plain, complete, non-empty
    # answer is not a reply, however successful the HTTP request was.
    def replied? = status == :success
  end
end
