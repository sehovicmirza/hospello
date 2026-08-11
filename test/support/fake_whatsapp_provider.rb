# A Whatsapp::Provider that never touches the network, and is the real port —
# not a mock standing in for one. Same reasoning, and the same shape, as
# FakeClaude around Ai::Client: it subclasses the port so it cannot drift from
# the interface, returns the same kind of value the real adapter returns (a
# provider message id String), and raises the same typed errors.
#
# What goes out *on the wire* is not this class's business and is never
# asserted through it — test/services/whatsapp/meta_cloud_provider_test.rb
# pins the exact URL, header and JSON body against WebMock. This exists so a
# caller (Whatsapp::SendMessageJob) can be tested for what it does with a
# send, a refusal, and a failure.
class FakeWhatsappProvider < Whatsapp::Provider
  attr_reader :sends, :templates

  def initialize
    @sends = []
    @templates = []
    @failures = []
    @next_id = 0
  end

  # Scripts the *next* send to raise. Queued rather than set as one sticky
  # value so a test can drive "fails, then succeeds on the retry" without
  # reaching in between calls.
  def script_failure(error)
    @failures << error
    self
  end

  def send_text(channel:, to:, body:, conversation:)
    @sends << { channel: channel, to: to, body: body, conversation: conversation }
    raise_if_scripted

    next_message_id
  end

  def send_template(channel:, to:, name:, locale:, components: [])
    @templates << { channel: channel, to: to, name: name, locale: locale, components: components }
    raise_if_scripted

    next_message_id
  end

  # The last thing actually handed to the provider, which is what a caller's
  # test usually wants to assert on.
  def last_send = sends.last

  def sent_bodies = sends.map { |send| send[:body] }

  private
    def raise_if_scripted
      failure = @failures.shift
      raise failure if failure
    end

    # Shaped like Meta's own ids so a test reading one can tell at a glance
    # what it is looking at.
    def next_message_id = "wamid.FAKE#{@next_id += 1}"
end
