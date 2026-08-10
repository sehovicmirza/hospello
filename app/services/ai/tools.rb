module Ai
  # The only way the assistant can affect anything in this system.
  #
  # That sentence is the whole design. A prompt injection that persuades the
  # model to say anything at all still has to come through here to change a
  # record, and here the model controls only the arguments — never the hotel,
  # never the conversation, never the guest. Those come from the job's own
  # context, which the model has no way to address. An injection that makes the
  # model emit a different hotel id is not *rejected*; there is simply nowhere
  # for that id to go.
  #
  # Slice 4 adds the service-request tools. The shape they follow is here:
  # declare the schema, validate every argument again on the server, and return
  # a tool_result the model can read — including for failures, because a model
  # that gets told what was wrong can fix it on the next turn, while an
  # exception ends the guest's reply entirely.
  class Tools
    # The reasons a *model* may choose. The rest of Conversation's
    # escalation_reason enum — ai_unavailable, budget_exhausted, staff_manual —
    # describes things the system or a person decided, and letting a model
    # claim one would corrupt the only record of why the AI stopped answering.
    MODEL_ESCALATION_REASONS = %w[guest_requested ai_uncertain].freeze
    DEFAULT_ESCALATION_REASON = "ai_uncertain".freeze

    MAX_SUMMARY_LENGTH = 500

    class << self
      # Sent to the API on every turn. Descriptions are written for the model,
      # not for us: they are the only place it learns when a tool is
      # appropriate, and vague wording here shows up as a concierge that either
      # never escalates or escalates everything.
      def definitions
        [
          {
            name: "escalate_to_staff",
            description:
              "Hand this conversation to a human receptionist. Use when the guest asks for a person, " \
              "when they are upset or complaining, when the matter involves safety, money, or a " \
              "commitment the hotel would have to honour, or when you cannot help. The guest is told " \
              "someone will reply personally; do not promise when.",
            input_schema: {
              type: "object",
              properties: {
                reason: {
                  type: "string",
                  enum: MODEL_ESCALATION_REASONS,
                  description: "guest_requested when the guest asked for a person; " \
                               "ai_uncertain when you cannot answer confidently."
                },
                summary: {
                  type: "string",
                  description: "One or two sentences telling the receptionist what the guest needs, " \
                               "in English. This is read by staff, not by the guest."
                }
              },
              required: %w[reason summary]
            }
          },
          {
            name: "log_unanswered_question",
            description:
              "Record a question this hotel's knowledge base could not answer, so the hotel can write " \
              "the answer down for next time. Call this whenever you have to tell a guest you do not " \
              "have something written down. It does not reply to the guest — you still do that.",
            input_schema: {
              type: "object",
              properties: {
                question: {
                  type: "string",
                  description: "The question in English, phrased generally enough that another guest " \
                               "asking the same thing would match it."
                },
                question_original: {
                  type: "string",
                  description: "The guest's own words, in their own language."
                }
              },
              required: %w[question]
            }
          }
        ]
      end

      def names = definitions.map { |tool| tool[:name] }
    end

    def initialize(conversation:)
      @conversation = conversation
      @hotel = conversation.hotel
    end

    # @param tool_call [Ai::Result::ToolCall]
    # @return [Hash] a tool_result content block for the next turn
    def execute(tool_call)
      case tool_call.name
      when "escalate_to_staff" then escalate(tool_call)
      when "log_unanswered_question" then log_gap(tool_call)
      else
        # Models invent tool names. Raising would end the guest's reply over
        # something the model can correct in one more turn.
        failure(tool_call, "Unknown tool #{tool_call.name.inspect}. Available tools: #{self.class.names.join(', ')}.")
      end
    rescue ActiveRecord::RecordInvalid => e
      # A validation the model could not have known about. Same reasoning:
      # tell it, let it try something else, do not take the reply down.
      failure(tool_call, "That could not be saved: #{e.record.errors.full_messages.to_sentence}.")
    end

    private

    attr_reader :conversation, :hotel

    def escalate(tool_call)
      summary = tool_call.input["summary"].to_s.strip
      return failure(tool_call, "summary is required — tell the receptionist what the guest needs.") if summary.blank?

      reason = tool_call.input["reason"].to_s
      reason = DEFAULT_ESCALATION_REASON unless MODEL_ESCALATION_REASONS.include?(reason)

      unless conversation.escalate_from_ai!(reason: reason, summary: summary.truncate(MAX_SUMMARY_LENGTH))
        return failure(tool_call, "This conversation is closed and cannot be escalated.")
      end

      success(tool_call, "Escalated. A receptionist can see this conversation now. Tell the guest someone " \
                         "will reply personally, without promising a time.")
    end

    def log_gap(tool_call)
      question = tool_call.input["question"].to_s.strip
      return failure(tool_call, "question is required.") if question.blank?

      # hotel and conversation come from this object, never from the call.
      UnansweredQuestion.record!(
        hotel: hotel,
        conversation: conversation,
        question: question,
        question_original: tool_call.input["question_original"],
        locale: conversation.guest_locale
      )

      success(tool_call, "Logged for the hotel to answer. Tell the guest you do not have that written " \
                         "down and offer to pass it to reception.")
    end

    def success(tool_call, content) = { type: "tool_result", tool_use_id: tool_call.id, content: content }

    def failure(tool_call, content)
      { type: "tool_result", tool_use_id: tool_call.id, content: content, is_error: true }
    end
  end
end
