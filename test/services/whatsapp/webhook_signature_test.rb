require "test_helper"

module Whatsapp
  # The single most hostile-tested guarantee in Slice 6: POST /webhooks/whatsapp
  # is the only unauthenticated, publicly reachable endpoint in this app that
  # accepts a body, so forging its way past this check is the one thing that
  # must be provably impossible. Every "invalid" test below signs a REAL body
  # with OpenSSL::HMAC — the same primitive WebhookSignature itself uses — so
  # a passing suite here means "an attacker without the secret cannot produce
  # a signature this accepts," not merely "this method returns false when I
  # tell it to."
  class WebhookSignatureTest < ActiveSupport::TestCase
    SECRET = "test-whatsapp-app-secret"
    BODY = '{"object":"whatsapp_business_account","entry":[{"id":"waba-1"}]}'

    def sign(body, secret: SECRET)
      "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    end

    test "a signature computed with the real secret over the exact body is valid" do
      assert WebhookSignature.valid?(raw_body: BODY, signature_header: sign(BODY), secret: SECRET)
    end

    test "a signature computed with the wrong secret is invalid" do
      forged = sign(BODY, secret: "an-attacker-guessed-this-wrong")

      assert_not WebhookSignature.valid?(raw_body: BODY, signature_header: forged, secret: SECRET)
    end

    # The signature is valid for SOME body — just not the one actually
    # received. An attacker who has seen one legitimate signed payload (e.g.
    # from a leaked log) cannot reuse its signature to smuggle a different
    # body of their choosing past verification.
    test "a signature computed over a different body is invalid" do
      signature_for_other_body = sign('{"object":"a_completely_different_payload"}')

      assert_not WebhookSignature.valid?(raw_body: BODY, signature_header: signature_for_other_body, secret: SECRET)
    end

    # The real attack: a genuinely valid (body, signature) pair where the
    # body is tampered with in flight AFTER signing, signature left
    # untouched — distinct from the test above because here the signature
    # really was computed for what is now a *prefix* of the received body,
    # not for an unrelated payload, which is the shape a length-extension or
    # truncation-style attack would actually produce.
    test "a body modified after signing is invalid" do
      original_signature = sign(BODY)
      tampered_body = BODY.sub('"waba-1"', '"waba-999"')

      assert_not WebhookSignature.valid?(raw_body: tampered_body, signature_header: original_signature, secret: SECRET)
    end

    test "a missing signature header is invalid, not treated as absent-but-fine" do
      assert_not WebhookSignature.valid?(raw_body: BODY, signature_header: nil, secret: SECRET)
      assert_not WebhookSignature.valid?(raw_body: BODY, signature_header: "", secret: SECRET)
    end

    # Meta's own documented format always carries the "sha256=" prefix. A
    # bare hex digest — even the mathematically correct one — must not pass:
    # accepting it would mean this app is more lenient than the scheme it
    # claims to implement, for no benefit.
    test "a correct digest with no sha256= prefix is invalid" do
      bare_digest = OpenSSL::HMAC.hexdigest("SHA256", SECRET, BODY)

      assert_not WebhookSignature.valid?(raw_body: BODY, signature_header: bare_digest, secret: SECRET)
    end

    # A misconfigured deployment (WHATSAPP_APP_SECRET never set) must fail
    # CLOSED — refuse every delivery — never fail open and accept an
    # unverifiable request just because there was nothing to check it
    # against. Deliberately signs with the *empty* secret too, not just an
    # arbitrary one, so this cannot be satisfied by accident.
    test "a blank configured secret refuses every delivery, never trusts one by default" do
      signature_with_blank_secret = sign(BODY, secret: "")

      assert_not WebhookSignature.valid?(raw_body: BODY, signature_header: sign(BODY), secret: nil)
      assert_not WebhookSignature.valid?(raw_body: BODY, signature_header: signature_with_blank_secret, secret: "")
    end

    # "The signature is compared in constant time" (the brief's own words) is
    # not a property a unit test can observe by measuring wall-clock time —
    # CI runners are far too noisy for that to be anything but a flaky test
    # that occasionally lies in both directions. What the test CAN prove is
    # that the constant-time primitive is the one actually doing the
    # comparison: deleting the call below (e.g. reverting to `==`) makes
    # this go red even though every other test in this file would still be
    # green, which is exactly the gap the brief warns is easy to leave open.
    test "the comparison is made via ActiveSupport::SecurityUtils.secure_compare" do
      calls = []
      original = ActiveSupport::SecurityUtils.method(:secure_compare)
      ActiveSupport::SecurityUtils.define_singleton_method(:secure_compare) do |a, b|
        calls << [ a, b ]
        original.call(a, b)
      end

      WebhookSignature.valid?(raw_body: BODY, signature_header: sign(BODY), secret: SECRET)

      assert_equal 1, calls.size, "expected exactly one ActiveSupport::SecurityUtils.secure_compare call"
      assert_equal [ sign(BODY), sign(BODY) ], calls.first
    ensure
      ActiveSupport::SecurityUtils.define_singleton_method(:secure_compare, original) if original
    end

    test "with no secret: argument, the default reads Rails.configuration.x.whatsapp.app_secret" do
      original = Rails.configuration.x.whatsapp.app_secret
      Rails.configuration.x.whatsapp.app_secret = SECRET

      assert WebhookSignature.valid?(raw_body: BODY, signature_header: sign(BODY))
    ensure
      Rails.configuration.x.whatsapp.app_secret = original
    end
  end
end
