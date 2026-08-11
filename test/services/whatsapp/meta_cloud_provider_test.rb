require "test_helper"

module Whatsapp
  # This is the only file in the app that builds a WhatsApp HTTP request or
  # parses one of Meta's responses — the same seam discipline
  # test/services/ai/client_test.rb documents around Ai::Client and
  # Anthropic. WebMock intercepts every request; nothing here ever reaches
  # the network (test_helper.rb calls WebMock.disable_net_connect!).
  #
  # Per the brief: assert the URL, the Authorization header, and the exact
  # JSON body against Meta Cloud's documented shape. A test that only checks
  # what #send_text returns would be a mock of this class asserting on
  # itself — rule 1 of docs/plan/engineering-rules.md, and reportedly this
  # project's most common defect by a wide margin.
  #
  # Deliberately does NOT build a real Conversation/GuestSession/Hotel graph
  # (and needs no ActsAsTenant.with_tenant anywhere in this file) to supply
  # the 24-hour-window tests their guest's-last-message timestamp:
  # #send_text's `conversation:` argument is duck-typed on
  # #last_guest_message_at alone, so a plain Struct is the real collaborator
  # here, not a stand-in for one — see #conversation_with below. That keeps
  # this file testing exactly one thing: what MetaCloudProvider does with
  # whatever it is handed.
  class MetaCloudProviderTest < ActiveSupport::TestCase
    ACCESS_TOKEN = "test-system-user-token"
    API_VERSION = "v22.0"

    setup do
      @provider = MetaCloudProvider.new(access_token: ACCESS_TOKEN, api_version: API_VERSION)
      @channel = whatsapp_channels(:stari_grad_whatsapp)
      @open_conversation = conversation_with(last_guest_message_at: 1.hour.ago)
    end

    # --- What leaves this process on the wire --------------------------------

    test "send_text posts to this channel's own phone_number_id, on the configured API version" do
      capture_request

      send_text

      assert_requested :post, messages_url
    end

    test "send_text authenticates with a Bearer token and sends JSON" do
      headers = capture_request_headers

      send_text

      assert_equal "Bearer #{ACCESS_TOKEN}", headers[:sent]["Authorization"]
      assert_equal "application/json", headers[:sent]["Content-Type"]
    end

    test "send_text's body matches Meta Cloud API's documented text-message shape exactly" do
      body = capture_request

      send_text(to: "+38761999888", body: "Your room is ready.")

      assert_equal({
        "messaging_product" => "whatsapp",
        "recipient_type" => "individual",
        "to" => "+38761999888",
        "type" => "text",
        "text" => { "body" => "Your room is ready." }
      }, body[:parsed])
    end

    test "send_text returns the provider message id Meta hands back" do
      stub_success(message_id: "wamid.HBGLTEST123")

      result = send_text

      assert_equal "wamid.HBGLTEST123", result
    end

    test "send_template's body matches Meta Cloud API's documented template shape, components included" do
      body = capture_request
      components = [ { type: "body", parameters: [ { type: "text", text: "Amila" } ] } ]

      send_template(components: components)

      assert_equal({
        "messaging_product" => "whatsapp",
        "recipient_type" => "individual",
        "to" => "+38761999888",
        "type" => "template",
        "template" => {
          "name" => "welcome_opt_in",
          "language" => { "code" => "bs" },
          "components" => [ { "type" => "body", "parameters" => [ { "type" => "text", "text" => "Amila" } ] } ]
        }
      }, body[:parsed])
    end

    test "send_template omits components entirely when there are none, rather than sending an empty array" do
      body = capture_request

      send_template(components: [])

      assert_not body[:parsed]["template"].key?("components")
    end

    test "send_template returns the provider message id" do
      stub_success(message_id: "wamid.TEMPLATE456")

      result = send_template

      assert_equal "wamid.TEMPLATE456", result
    end

    # --- Failure mapping -------------------------------------------------------
    #
    # Nothing outside this class may rescue an HTTP status directly — each of
    # these is part of the seam's contract, the same discipline
    # test/services/ai/client_test.rb documents for Ai::Client.

    test "a 401 becomes Whatsapp::AuthenticationError — someone must fix the configured token" do
      stub_error(401, message: "Error validating access token: Session has expired", type: "OAuthException", code: 190)

      error = assert_raises(Whatsapp::AuthenticationError) { send_text }

      assert_match(/access token/, error.message)
    end

    test "a 429 becomes Whatsapp::RateLimitedError carrying Meta's own retry advice" do
      stub_request(:post, messages_url).to_return(
        status: 429,
        headers: { "content-type" => "application/json", "retry-after" => "30" },
        body: { error: { message: "(#80007) Too many messages", type: "OAuthException", code: 80007 } }.to_json
      )

      error = assert_raises(Whatsapp::RateLimitedError) { send_text }

      assert_equal 30, error.retry_after
    end

    test "a 429 with no retry-after header reports no advice, not an immediate retry" do
      stub_error(429, message: "Too many messages", code: 80007)

      error = assert_raises(Whatsapp::RateLimitedError) { send_text }

      assert_nil error.retry_after
    end

    test "any other failure becomes Whatsapp::ApiError carrying the HTTP status" do
      stub_error(500, message: "Upstream said no", code: 1)

      error = assert_raises(Whatsapp::ApiError) { send_text }

      assert_equal 500, error.status
    end

    test "a 400 becomes Whatsapp::ApiError too, distinguishable from the 401/429 cases by type alone" do
      stub_error(400, message: "Invalid parameter", type: "OAuthException", code: 100)

      error = assert_raises(Whatsapp::ApiError) { send_text }

      assert_equal 400, error.status
    end

    test "every mapped failure is a Whatsapp::Error, so one rescue covers them all" do
      [ Whatsapp::AuthenticationError, Whatsapp::RateLimitedError, Whatsapp::ApiError, Whatsapp::WindowClosedError ].each do |klass|
        assert_operator klass, :<, Whatsapp::Error
      end
    end

    # --- The 24-hour customer service window ----------------------------------
    #
    # Meta's own rule, not Hospello's, and it cannot be negotiated: more than
    # 24 hours after the guest's last inbound message, only a pre-approved
    # template (#send_template) may be sent. Lives here, in the provider, so
    # every future caller inherits it and none can forget it — see the brief
    # and Whatsapp::Provider's class comment.

    test "send_text succeeds just inside the 24-hour window" do
      stub_success
      conversation = conversation_with(last_guest_message_at: 24.hours.ago + 1.second)

      assert_nothing_raised { send_text(conversation: conversation) }
    end

    # The boundary is exclusive on the CLOSED side (Time.current > last +
    # 24.hours) — exactly at 24 hours the window has not yet closed.
    #
    # with_usec: true is load-bearing here, not decoration: travel_to
    # truncates to whole seconds by default (ActiveSupport::Testing::
    # TimeHelpers#travel_to(date_or_time, with_usec: false)), so without it
    # the frozen "now" lands up to ~999ms *before* last_guest_message_at +
    # 24.hours whenever the captured timestamp carries sub-second
    # precision — which real timestamps always do. That slack made this
    # test pass under both `>` and a wrongly-inclusive `>=`, so it was
    # proving nothing about the exact instant despite its name. Confirmed by
    # deliberately reintroducing that exact bug (`>=`) — with the default
    # travel_to this test stayed green; only with_usec: true turned it red.
    test "send_text succeeds at the exact boundary moment" do
      last_guest_message_at = 24.hours.ago
      conversation = conversation_with(last_guest_message_at: last_guest_message_at)
      stub_success

      travel_to(last_guest_message_at + 24.hours, with_usec: true) do
        assert_nothing_raised { send_text(conversation: conversation) }
      end
    end

    test "send_text raises WindowClosedError one second past the boundary, and calls the network not at all" do
      last_guest_message_at = 24.hours.ago
      conversation = conversation_with(last_guest_message_at: last_guest_message_at)

      travel_to(last_guest_message_at + 24.hours + 1.second) do
        assert_raises(Whatsapp::WindowClosedError) { send_text(conversation: conversation) }
      end

      assert_not_requested :post, messages_url
    end

    test "send_text well outside the window raises WindowClosedError" do
      conversation = conversation_with(last_guest_message_at: 3.days.ago)

      assert_raises(Whatsapp::WindowClosedError) { send_text(conversation: conversation) }
      assert_not_requested :post, messages_url
    end

    test "send_text raises WindowClosedError when the guest has never sent an inbound message at all" do
      conversation = conversation_with(last_guest_message_at: nil)

      assert_raises(Whatsapp::WindowClosedError) { send_text(conversation: conversation) }
      assert_not_requested :post, messages_url
    end

    # The escape hatch Meta's own rule requires: a pre-approved template is
    # exactly what a business is allowed to send outside the window, so it
    # must never be subject to this guard.
    test "send_template ignores the 24-hour window entirely, even when it has been closed for days" do
      capture_request

      send_template

      assert_requested :post, messages_url
    end

    # --- The seam's own factory ------------------------------------------------

    test "Provider.for returns a MetaCloudProvider for a channel on the meta_cloud provider" do
      assert_instance_of MetaCloudProvider, Provider.for(@channel)
    end

    test "Provider.for raises for a BSP with no adapter implemented yet, rather than silently guessing" do
      @channel.provider = :twilio

      assert_raises(ArgumentError) { Provider.for(@channel) }
    end

    # --- Guards ------------------------------------------------------------------

    test "refuses to send with no access token configured, and sends nothing" do
      unconfigured = MetaCloudProvider.new(access_token: nil, api_version: API_VERSION)

      error = assert_raises(Whatsapp::ApiError) do
        unconfigured.send_text(channel: @channel, to: "+38761999888", body: "hi", conversation: @open_conversation)
      end

      assert_match(/WHATSAPP_ACCESS_TOKEN/, error.message)
      assert_not_requested :post, messages_url
    end

    test "an empty-string access token counts as no token at all" do
      unconfigured = MetaCloudProvider.new(access_token: "", api_version: API_VERSION)

      assert_raises(Whatsapp::ApiError) do
        unconfigured.send_text(channel: @channel, to: "+38761999888", body: "hi", conversation: @open_conversation)
      end
      assert_not_requested :post, messages_url
    end

    private

    def send_text(to: "+38761999888", body: "Test message", conversation: @open_conversation)
      @provider.send_text(channel: @channel, to: to, body: body, conversation: conversation)
    end

    def send_template(to: "+38761999888", name: "welcome_opt_in", locale: "bs", components: [])
      @provider.send_template(channel: @channel, to: to, name: name, locale: locale, components: components)
    end

    # The only thing #send_text's window guard actually needs — see the file
    # header for why this is a real collaborator, not a mock standing in for
    # one.
    def conversation_with(last_guest_message_at:)
      Struct.new(:last_guest_message_at).new(last_guest_message_at)
    end

    def messages_url
      "https://graph.facebook.com/#{API_VERSION}/#{@channel.phone_number_id}/messages"
    end

    def capture_request
      body = {}
      stub_request(:post, messages_url)
        .with { |request| body[:parsed] = JSON.parse(request.body) }
        .to_return(status: 200, headers: json_headers, body: success_body.to_json)
      body
    end

    def capture_request_headers
      headers = {}
      stub_request(:post, messages_url)
        .with { |request| headers[:sent] = request.headers }
        .to_return(status: 200, headers: json_headers, body: success_body.to_json)
      headers
    end

    def stub_success(message_id: "wamid.DEFAULT")
      stub_request(:post, messages_url).to_return(status: 200, headers: json_headers, body: success_body(message_id: message_id).to_json)
    end

    def stub_error(status, message:, code:, type: "OAuthException")
      stub_request(:post, messages_url).to_return(
        status: status, headers: json_headers,
        body: { error: { message: message, type: type, code: code } }.to_json
      )
    end

    def json_headers = { "content-type" => "application/json" }

    def success_body(message_id: "wamid.DEFAULT")
      {
        messaging_product: "whatsapp",
        contacts: [ { input: "+38761999888", wa_id: "38761999888" } ],
        messages: [ { id: message_id } ]
      }
    end
  end
end
