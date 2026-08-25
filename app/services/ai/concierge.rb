module Ai
  # One concierge turn: build the prompt, ask the model, run any tools it
  # asked for, ask again, and hand back an `Ai::Outcome`.
  #
  # It persists nothing about the conversation itself. Deciding whether the
  # guest actually gets this reply belongs to `Ai::GenerateReplyJob`, which
  # re-checks `ai_mode` inside the transaction that writes the message — a
  # receptionist can take over while this class is mid-flight, and the answer
  # to that must be decided at write time, not here.
  class Concierge
    # A turn that needs more rounds than this is a turn that has gone wrong.
    # No tool here takes an argument the model has to discover by trying — the
    # one that comes closest, set_guest_room, is answered by the guest rather
    # than guessed at — so the cap exists to stop a model that loops from
    # billing a hotel indefinitely while a guest watches a typing indicator,
    # not to allow for exploration. Raising it is almost never the right
    # response to a turn that hits it.
    MAX_TOOL_ROUNDS = 3

    # Our own marker, not an API feature: the last line of a reply, listing
    # the knowledge-base entries the model used. It is stripped before the
    # guest sees anything — a guest reading "[kb: 12]" would rightly conclude
    # the software is broken — and it is the only reason `ai_runs` can say
    # which entries are earning their keep.
    CITATION_PATTERN = /\n*^\[kb:\s*([\d,\s]*)\]\s*\z/

    def initialize(conversation:, client: Ai::Client.new)
      @conversation = conversation
      @hotel = conversation.hotel
      @client = client
      @model = Rails.configuration.x.ai.model
      @usage = Result::Usage.new
    end

    def reply
      started_at = monotonic_ms
      prompt = PromptBuilder.new(conversation: conversation).build
      messages = prompt.messages.dup
      rounds = 0

      loop do
        result = ask(prompt.system_blocks, messages)

        return outcome(:refusal, started_at) if result.refusal?
        return outcome(:api_error, started_at) if result.truncated?

        unless result.tool_calls?
          text, cited = split_citations(result.text)
          return outcome(:api_error, started_at) if text.blank?

          return outcome(:success, started_at, text: text, cited_kb_entry_ids: cited)
        end

        rounds += 1
        # Out of rounds with only tool calls to show for it: there is no
        # answer to post, and posting nothing is worse for the guest than the
        # fallback message the job will send instead.
        return outcome(:api_error, started_at) if rounds > MAX_TOOL_ROUNDS

        messages.push(assistant_turn(result), tool_results_turn(result))
      end
    rescue Ai::TimeoutError => e
      outcome(:timeout, started_at, error_class: e.class.name)
    rescue Ai::Error => e
      outcome(:api_error, started_at, error_class: e.class.name)
    end

    private

    attr_reader :conversation, :hotel, :client, :model, :usage

    def ask(system_blocks, messages)
      result = client.chat(system: system_blocks, messages: messages, tools: Tools.definitions_for(hotel), model: model)
      accumulate(result.usage)
      result
    end

    # Usage is summed across every call in the turn, not taken from the last
    # one. A turn that ran two tools and then answered has been billed three
    # times, and a budget guard reading only the final call would under-count
    # exactly the expensive turns.
    def accumulate(call_usage)
      @usage = Result::Usage.new(
        input_tokens: usage.input_tokens + call_usage.input_tokens,
        output_tokens: usage.output_tokens + call_usage.output_tokens,
        cache_read_input_tokens: usage.cache_read_input_tokens + call_usage.cache_read_input_tokens
      )
    end

    # The model's own turn, replayed back to it. Both blocks matter: without
    # the tool_use blocks the API rejects the tool_result that follows, and
    # without the text the model loses whatever it had already started saying.
    def assistant_turn(result)
      content = []
      content << { type: "text", text: result.text } if result.text.present?
      content.concat(
        result.tool_calls.map do |call|
          { type: "tool_use", id: call.id, name: call.name, input: call.input }
        end
      )

      { role: "assistant", content: content }
    end

    # Tool results come back as a *user* turn — that is the API's shape, not a
    # mistake. Every call gets a result block, including the ones that failed,
    # because a missing result is a malformed request.
    def tool_results_turn(result)
      tools = Tools.new(conversation: conversation)

      { role: "user", content: result.tool_calls.map { |call| tools.execute(call) } }
    end

    # Ids the model made up are dropped rather than recorded: `ai_runs` is
    # read to decide whether a hotel's knowledge base is working, and a
    # hallucinated citation would make an unused entry look load-bearing.
    def split_citations(text)
      match = CITATION_PATTERN.match(text.to_s)
      return [ text.to_s.strip, [] ] if match.nil?

      claimed = match[1].split(",").filter_map { |id| Integer(id.strip, exception: false) }
      real = hotel.published_kb_entries.where(id: claimed).pluck(:id)

      [ text.to_s.sub(CITATION_PATTERN, "").strip, real ]
    end

    def outcome(status, started_at, text: "", cited_kb_entry_ids: [], error_class: nil)
      Outcome.new(
        status: status, text: text, cited_kb_entry_ids: cited_kb_entry_ids,
        usage: usage, model: model, latency_ms: monotonic_ms - started_at, error_class: error_class
      )
    end

    def monotonic_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
  end
end
