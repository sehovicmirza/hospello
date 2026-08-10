module Staff
  # The reception inbox — the screen that makes "a guest can always reach a
  # human" true rather than aspirational. Everything is scoped through
  # Current.hotel (set by Staff::BaseController from the signed-in user's
  # own hotel, never a URL parameter), so another hotel's conversation id
  # raises RecordNotFound and 404s before Pundit is even consulted.
  class ConversationsController < BaseController
    # The three lenses a receptionist actually switches between. Declared
    # as a constant, not read straight from params, so an unknown ?filter=
    # value falls back to :all instead of reaching a scope lookup — and so
    # the view can render the tabs from the same list the controller
    # honours, rather than a second hand-written copy that can drift.
    FILTERS = {
      all: :all,
      needs_attention: :needs_attention,
      resolved: :settled
    }.freeze

    DEFAULT_FILTER = :all

    before_action :set_conversation, only: %i[show ai_mode resolve]

    def index
      authorize Conversation

      @filter = requested_filter
      @query = params[:q].to_s.strip
      @conversations = Current.hotel.conversations
        .public_send(FILTERS.fetch(@filter))
        .matching(@query)
        .inbox_order
        .includes(:guest_session, :room)
        .limit(MAX_INBOX_ROWS)

      # Counts come from the unfiltered set on purpose: a tab whose count
      # changed with the current search would tell a receptionist their
      # queue had shrunk when all they did was type.
      @counts = inbox_counts
      @previews = latest_guest_visible_messages(@conversations)
    end

    def show
      authorize @conversation

      # Opening a conversation is what marks it read — server-side, on the
      # request that actually rendered it, never nudged from the browser
      # (see Conversation#mark_read_by_staff!). Done before the transcript
      # is read so the badge in the same render is already correct.
      @conversation.mark_read_by_staff!

      # Staff see everything, internal notes included — this is the one
      # read of `messages` in the app that deliberately carries no
      # visibility scope.
      @messages = @conversation.messages.chronological.to_a
    end

    # The Pause AI / Return to AI toggle. Nothing reads ai_mode until Slice
    # 3, but the control and the internal trail it writes
    # (Conversation#pause_ai!/#resume_ai!) belong with the inbox that
    # operates it.
    def ai_mode
      authorize @conversation, :toggle_ai?

      if @conversation.paused?
        @conversation.resume_ai!(user: Current.user)
        redirect_to staff_conversation_path(@conversation), notice: "Returned to the assistant."
      else
        @conversation.pause_ai!(user: Current.user)
        redirect_to staff_conversation_path(@conversation), notice: "You have taken over this conversation."
      end
    end

    # Without this, the "Resolved" tab could never fill up — and a
    # receptionist would have no way to clear a finished conversation off
    # the top of a list sorted by activity.
    def resolve
      authorize @conversation, :resolve?

      @conversation.update!(status: :resolved)
      redirect_to staff_conversations_path, notice: "Conversation marked resolved."
    end

    private
      # An upper bound on one screen, not a pagination scheme: a hotel's
      # live inbox is tens of rows, and a hotel that somehow has thousands
      # should get a fast page showing the most urgent of them rather than
      # a slow page showing all of them. Revisit with real pagination when
      # a pilot hotel actually approaches it.
      MAX_INBOX_ROWS = 200

      # Finds only — each action authorizes with its own explicit query.
      # Pundit's implicit query is derived from action_name, which would
      # ask for a non-existent `ai_mode?` on this controller's two member
      # actions and raise NoMethodError instead of denying anything.
      def set_conversation
        @conversation = Current.hotel.conversations.find(params[:id])
      end

      def requested_filter
        filter = params[:filter].to_s.to_sym
        FILTERS.key?(filter) ? filter : DEFAULT_FILTER
      end

      # One query for every row's "last message" preview instead of one per
      # row. DISTINCT ON is Postgres-specific and this app is Postgres-only
      # (see config/database.yml on why there is exactly one database).
      # Message is TenantScoped, so this is already confined to
      # Current.hotel before the conversation ids are even applied.
      #
      # Guest-visible only: an internal note is staff bookkeeping and does
      # not move last_message_at either, so previewing one would make the
      # row's text and its timestamp describe two different messages.
      def latest_guest_visible_messages(conversations)
        ids = conversations.map(&:id)
        return {} if ids.empty?

        Message.guest_visible
          .where(conversation_id: ids)
          .select("DISTINCT ON (conversation_id) conversation_id, body, sender_role, created_at")
          .order("conversation_id, id DESC")
          .index_by(&:conversation_id)
      end

      def inbox_counts
        all = Current.hotel.conversations
        {
          all: all.count,
          needs_attention: all.needs_attention.count,
          resolved: all.settled.count
        }
      end
  end
end
