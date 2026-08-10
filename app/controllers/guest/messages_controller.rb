# Guest::BaseController (inherited) does all the tenant/session/locale
# work — see that controller. Every conversation this controller ever
# touches comes from Conversation.live_for(Current.guest_session), never
# from a client-supplied conversation id or hotel id: there is nothing
# tenant-identifying anywhere in this namespace's routes on purpose (see
# Guest::BaseController's own comment), and this controller doesn't invent
# an exception to that just because a form could technically submit one.
module Guest
  class MessagesController < BaseController
    # Independent of rack-attack's IP-level guest_messages/ip throttle
    # (config/initializers/rack_attack.rb, matches any POST under
    # "/guest/") — keyed by guest_session id instead of IP, so one abusive
    # session gets throttled without punishing every other guest sharing
    # the same hotel wifi/NAT. A dedicated MemoryStore, not the app's
    # general cache_store: the test environment's cache_store is
    # :null_store (config/environments/test.rb) specifically so shared
    # counters can't make unrelated tests flaky, which would make this
    # throttle silently never engage under test — the one environment
    # where "does this actually throttle" has to be provable.
    RATE_LIMIT_MAX = 100
    RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new

    rate_limit to: RATE_LIMIT_MAX, within: 1.minute, only: :create,
      by: -> { Current.guest_session.id }, store: RATE_LIMIT_STORE

    # An upper bound on a single resync response, not a pagination scheme:
    # a guest who was offline for a long time still only needs "everything
    # since I last saw," and this keeps one resync fetch from ever trying
    # to render an unbounded transcript.
    MAX_RESYNC_MESSAGES = 200

    def create
      @conversation = Conversation.live_for(Current.guest_session)
      @message = @conversation.post_guest_message!(
        body: message_params[:body], client_message_id: message_params[:client_message_id]
      )

      render :create
    rescue ActiveRecord::RecordInvalid => invalid
      @error_message = friendly_error_message(invalid.record)
      render :create_error, status: :unprocessable_content
    end

    # The resilience layer's resync endpoint
    # (app/javascript/controllers/chat_resilience_controller.js) —
    # "?after=<id>" returns only messages newer than that id, so a dropped
    # WebSocket costs one poll interval, never a lost message: the
    # database is the source of truth here, the live broadcast
    # (Conversation#post_guest_message!/#post_staff_message!) is only ever
    # an enhancement on top of it.
    def index
      @conversation = Conversation.live_for(Current.guest_session)
      @messages = @conversation.messages.chronological.after_id(params[:after]).limit(MAX_RESYNC_MESSAGES)

      render :index
    end

    private
      def message_params
        params.require(:message).permit(:body, :client_message_id)
      end

      # Message's own validations only ever fail one of two ways in
      # practice (blank, or over MAX_BODY_LENGTH) — naming both explicitly
      # in the guest's own language reads far better than surfacing
      # ActiveRecord's raw (English-only, and not fully guest-facing-i18n'd)
      # error text.
      def friendly_error_message(message)
        if message.errors[:body].any? { |error| error.include?("too long") }
          t("guest.chats.composer.too_long_error")
        else
          t("guest.chats.composer.blank_error")
        end
      end
  end
end
