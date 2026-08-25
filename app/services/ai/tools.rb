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

    # A guest is describing something they want, not filling in a form. The
    # cap is generous enough for "the blue suitcase with the broken wheel by
    # the lift" and small enough that a model looping cannot write an essay
    # into a receptionist's card.
    MAX_DETAIL_LENGTH = 300

    # Long enough for any real name including titles and both surnames, short
    # enough that the inbox list stays readable — this ends up in a row a
    # receptionist scans, not in a paragraph.
    MAX_GUEST_NAME_LENGTH = 80

    # The two tools that between them are the only way a ServiceRequest can come
    # into existence: propose creates the draft, confirm turns it into a
    # request. A hotel whose plan has no requests is offered neither, and — see
    # #execute — is refused both even if the model asks for one anyway.
    REQUEST_TOOLS = %w[propose_service_request confirm_service_request].freeze

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
            name: "propose_service_request",
            description:
              "Start or update the request this guest is describing. Call it as soon as you know " \
              "which kind of request it is, even if details are missing — the reply tells you what " \
              "is still needed so you can ask for one thing at a time. When everything is there the " \
              "guest is shown a summary to confirm. This does NOT create anything the hotel will " \
              "act on: only confirm_service_request does that, and only after the guest agrees.",
            input_schema: {
              type: "object",
              properties: {
                category_key: {
                  type: "string",
                  description: "The key of one of this hotel's request categories, listed in the " \
                               "hotel card. Do not invent one."
                },
                details: {
                  type: "object",
                  description: "What the guest has told you so far, keyed by the field names the " \
                               "category asks for. Only what they actually said — never a guess.",
                  additionalProperties: { type: "string" }
                },
                requested_for: {
                  type: "string",
                  description: "When the guest wants it, as an ISO 8601 timestamp in the hotel's " \
                               "local time. Omit it entirely unless they gave a time."
                }
              },
              required: %w[category_key]
            }
          },
          {
            name: "confirm_service_request",
            description:
              "Send the guest's request to reception, after they have agreed to the summary. Only " \
              "call this when the guest has actually said yes to what you showed them — a question, " \
              "a correction or silence is not a yes. After it returns, tell the guest their request " \
              "has been sent to reception and is pending; never that it is confirmed, booked, " \
              "approved or guaranteed.",
            input_schema: {
              type: "object",
              properties: {
                draft_id: {
                  type: "integer",
                  description: "The id from the pending request in this conversation."
                }
              },
              required: %w[draft_id]
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
          },
          {
            name: "set_guest_room",
            description:
              "Record which room this guest is staying in, and their name. Guests who reach the " \
              "hotel over WhatsApp arrive with neither, and the prompt tells you when that is the " \
              "case. Ask for both in one short message, in the guest's own language, and call this " \
              "as soon as they answer — before answering questions and before starting any " \
              "request. If the reply is an error the room number was not one of this hotel's; tell " \
              "the guest and ask again. It records what the guest said; nobody has checked it, so " \
              "never treat it as proof of anything.",
            input_schema: {
              type: "object",
              properties: {
                room_number: {
                  type: "string",
                  description: "The room number exactly as the guest gave it. Do not guess or " \
                               "reformat it."
                },
                guest_name: {
                  type: "string",
                  description: "The name the guest gave you, in their own script."
                },
                language: {
                  type: "string",
                  enum: GuestLocaleHelper::SUPPORTED_LOCALES,
                  description: "The language the guest is writing to you in. It is what the hotel's " \
                               "staff see this conversation translated from, so give it if you can " \
                               "tell, and leave it out if you cannot."
                }
              },
              required: %w[room_number guest_name]
            }
          }
        ]
      end

      def names = definitions.map { |tool| tool[:name] }

      # What this hotel's plan actually offers the model.
      #
      # Withholding the request tools is what makes the model behave — it
      # cannot ask for a tool it was never shown, and the prompt (see
      # PromptBuilder) tells it to send the guest to reception instead. It is
      # NOT what makes the refusal true: models routinely emit tools they were
      # not offered, so Tools#execute refuses these by name as well. This half
      # shapes behaviour; that half carries the guarantee.
      def definitions_for(hotel)
        return definitions if hotel.plan_allows?(:requests)

        definitions.reject { |tool| REQUEST_TOOLS.include?(tool[:name]) }
      end

      def names_for(hotel) = definitions_for(hotel).map { |tool| tool[:name] }
    end

    def initialize(conversation:)
      @conversation = conversation
      @hotel = conversation.hotel
    end

    # @param tool_call [Ai::Result::ToolCall]
    # @return [Hash] a tool_result content block for the next turn
    def execute(tool_call)
      # The gate that actually holds. definitions_for withheld these tools, but
      # a model can still emit a tool name it was not offered — from an earlier
      # turn, from a similar hotel, or from nowhere at all — and the case below
      # would run it. Refused by name, before dispatch.
      return requests_not_offered(tool_call) if REQUEST_TOOLS.include?(tool_call.name) && !hotel.plan_allows?(:requests)

      case tool_call.name
      when "escalate_to_staff" then escalate(tool_call)
      when "log_unanswered_question" then log_gap(tool_call)
      when "propose_service_request" then propose(tool_call)
      when "confirm_service_request" then confirm(tool_call)
      when "set_guest_room" then set_room(tool_call)
      else
        # Models invent tool names. Raising would end the guest's reply over
        # something the model can correct in one more turn.
        failure(tool_call, "Unknown tool #{tool_call.name.inspect}. Available tools: #{self.class.names_for(hotel).join(', ')}.")
      end
    rescue ActiveRecord::RecordInvalid => e
      # A validation the model could not have known about. Same reasoning:
      # tell it, let it try something else, do not take the reply down.
      failure(tool_call, "That could not be saved: #{e.record.errors.full_messages.to_sentence}.")
    end

    private

    attr_reader :conversation, :hotel

    # Returned to the model, not to the guest, so it is written as an
    # instruction rather than as something to repeat verbatim — the model says
    # it in whatever language the guest is writing in.
    #
    # It names the number where there is one. A hotel with no contact_phone
    # gets "the reception desk" instead: telling a guest to call and not saying
    # what to call is worse than telling them where to go.
    def requests_not_offered(tool_call)
      where = hotel.contact_phone.presence
      reach = where ? "call reception on #{where}" : "speak to the reception desk"

      failure(
        tool_call,
        "This hotel does not take service requests through chat, and no request has been created. " \
        "Do not try again with a different tool. Tell the guest, warmly and in their own language, " \
        "that you cannot arrange this yourself and that they should #{reach}. You may still answer " \
        "any question they ask about the hotel."
      )
    end

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

    # Gathering, not committing. This may run several times in one
    # conversation as the guest fills in the gaps, and it updates the same
    # draft each time — the one-live-draft index makes that literally the only
    # possibility.
    # Which room this guest is in, and what they are called. The whole tool
    # exists because a WhatsApp guest arrives with neither — there is no entry
    # form on that channel and no cookie to read one back from.
    #
    # The session it binds comes from `conversation`, exactly like every other
    # tool here: there is no argument that names a guest, so "and also set room
    # 202 for Mr Smith" has nowhere to put Mr Smith. What the model controls is
    # the room number and the name, and both are validated here regardless of
    # what it emitted.
    def set_room(tool_call)
      session = conversation.guest_session

      # Every web guest, and any WhatsApp guest who has already answered. Not
      # a tool for *moving* anyone: the room is what a receptionist delivers
      # to and what every open request is addressed to, so changing it
      # mid-conversation on a model's say-so is the kind of quiet change
      # nobody notices until a towel goes to the wrong door.
      if session.room_id.present?
        return failure(tool_call, "This guest's room is already recorded as #{session.room&.number}. " \
                                  "It cannot be changed here — if they say it is wrong, escalate to staff.")
      end

      name = tool_call.input["guest_name"].to_s.strip
      return failure(tool_call, "guest_name is required — ask the guest what to call them.") if name.blank?

      # find_active_room normalizes the number and is tenant-scoped, so a room
      # belonging to a different hotel is indistinguishable from one that was
      # never real. That is the property wanted: both are "not a room here".
      number = tool_call.input["room_number"].to_s.strip
      room = hotel.find_active_room(number)
      if room.nil?
        return failure(tool_call, "#{number.inspect} is not a room at this hotel. Tell the guest the " \
                                  "number was not found and ask them to check it.")
      end

      bind_guest(session, room: room, name: name.truncate(MAX_GUEST_NAME_LENGTH), language: locale_from(tool_call))

      success(tool_call, "Recorded: room #{room.number}, #{name}. Their identity is still unverified — " \
                         "never use it as proof of anything. You can help them normally now.")
    end

    # Both records, in one transaction. The session's room is what a confirmed
    # request is addressed to (ServiceRequestDraft#build_request reads it) and
    # the conversation's is what the prompt and the staff screens read — so
    # writing one without the other leaves two answers to "which room".
    #
    # guest_locale gets the same treatment for the same reason: it is copied
    # from the session only `on: :create`, so a live conversation that is not
    # told separately keeps stamping every message with the language the guest
    # does not speak.
    def bind_guest(session, room:, name:, language:)
      ActiveRecord::Base.transaction do
        session.update!({ room: room, guest_name: name }.merge(language ? { locale: language } : {}))
        conversation.update!({ room: room }.merge(language ? { guest_locale: language } : {}))
      end
    end

    # nil for anything this app does not speak, and nil is the safe answer: an
    # unsupported value would fail GuestSession's own inclusion validation and
    # take the whole binding down with it, when all that was really missing is
    # one optional hint.
    def locale_from(tool_call)
      claimed = tool_call.input["language"].to_s

      claimed if GuestLocaleHelper::SUPPORTED_LOCALES.include?(claimed)
    end

    def propose(tool_call)
      # The structural half of "ask for the room first" — the prompt's
      # <room_unknown> block is the other half, and neither is sufficient
      # alone. A request that cannot be delivered to a room is worse than no
      # request: it reaches a receptionist's board with nowhere to send it
      # (service_requests.room_id is nullable, so nothing further down would
      # refuse it).
      if conversation.guest_session.room_id.blank?
        return failure(tool_call, "This guest's room is not known yet, and a request cannot be " \
                                  "delivered without one. Ask for their room number and name, then " \
                                  "call set_guest_room before starting the request again.")
      end

      category = hotel.request_categories.active.find_by(key: tool_call.input["category_key"].to_s)
      if category.nil?
        return failure(tool_call, "Unknown category_key. This hotel's categories are: #{category_keys.join(', ')}.")
      end

      draft = live_draft || conversation.service_request_drafts.new
      draft.request_category = category
      draft.details = merged_details(draft, category, tool_call.input)
      draft.status = draft.ready? ? :awaiting_confirmation : :gathering
      draft.save!

      success(tool_call, proposal_receipt(draft))
    end

    # The commit, and the one place a guest's own "yes" turns into work for
    # the hotel. Everything protective lives in ServiceRequestDraft#confirm!;
    # this only decides which draft, and refuses to take that from the model.
    def confirm(tool_call)
      draft = live_draft
      return failure(tool_call, "There is no pending request in this conversation to confirm.") if draft.nil?

      # The model's draft_id is checked against the conversation's own live
      # draft rather than used to look one up. A model that names a different
      # id is confused about which request it is confirming, and confirming
      # the wrong thing on a guest's behalf is exactly what this slice exists
      # to prevent — so this refuses rather than quietly doing the right thing
      # for the wrong reason.
      claimed = tool_call.input["draft_id"]
      if claimed.present? && claimed.to_i != draft.id
        return failure(tool_call, "draft_id #{claimed} is not the pending request in this conversation (#{draft.id}).")
      end

      unless draft.status_awaiting_confirmation?
        return failure(tool_call, "The guest has not been shown a summary to agree to yet. Call " \
                                  "propose_service_request first and show them what you have.")
      end

      request = draft.confirm!
      success(tool_call, "Sent to reception as request ##{request.id}. Tell the guest it has been " \
                         "passed to reception and is pending — not confirmed, booked or approved — " \
                         "and do not promise a time.")
    rescue ServiceRequestDraft::NotConfirmable => e
      failure(tool_call, "#{e.message}. Start again with propose_service_request if the guest still wants it.")
    end

    def live_draft = ServiceRequestDraft.live_for(conversation)

    def category_keys = hotel.request_categories.active.ordered.pluck(:key)

    # Only the fields this category actually asks for, plus the time. Anything
    # else the model supplied is dropped rather than stored: `details` ends up
    # on a receptionist's card and in the dedupe key, and letting a model write
    # arbitrary keys into it would make both unpredictable.
    #
    # Merged onto what is already there, because a guest answering "6pm" to
    # "when?" is adding to the request, not replacing it.
    def merged_details(draft, category, input)
      supplied = input["details"].to_h.transform_keys(&:to_s)
      allowed = Array(category.detail_fields).map(&:to_s)

      kept = allowed.index_with { |field| supplied[field].to_s.strip.truncate(MAX_DETAIL_LENGTH) }
                    .select { |_, value| value.present? }

      details = draft.details.to_h.merge(kept)
      time = input["requested_for"].to_s.strip
      details["requested_for_at"] = time.truncate(MAX_DETAIL_LENGTH) if time.present?
      details
    end

    def proposal_receipt(draft)
      if draft.status_awaiting_confirmation?
        "Draft ##{draft.id} is complete: #{draft.summary_for_guest}. Show the guest exactly this and " \
          "ask them to confirm. Do not call confirm_service_request until they say yes."
      else
        "Draft ##{draft.id} still needs: #{draft.missing_fields.join(', ')}. Ask the guest for " \
          "#{draft.missing_fields.first} — one thing at a time — and do not guess it."
      end
    end

    def success(tool_call, content) = { type: "tool_result", tool_use_id: tool_call.id, content: content }

    def failure(tool_call, content)
      { type: "tool_result", tool_use_id: tool_call.id, content: content, is_error: true }
    end
  end
end
