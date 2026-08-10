# Throttles the app's unauthenticated public surface — the endpoints an
# attacker (or a mis-behaving script) can hit without ever having an
# account. Guests scan a QR code straight into these paths with no session
# and no CSRF-protected form to slow a script down, so IP-based throttling
# at the Rack layer is the only cheap backstop before Slice 2's actual guest
# controllers exist. Returning nil from a throttle block (as these do for
# any request the block's condition doesn't match) tells Rack::Attack "this
# rule doesn't apply," not "block it" — Rack::Attack's own documented
# behavior.
#
# Disabled by default in test (config/environments/test.rb) so shared
# throttle counters can't make unrelated tests flaky — see
# test/integration/rack_attack_test.rb for the tests that turn it back on,
# including the proxy/spoofing tests for Rack::Attack::Request below.

# Every throttle below keys on req.ip, which now means something different
# than the plain Rack::Request#ip a first pass at this file used.
# config.force_ssl = true (config/environments/production.rb) confirms
# there's an SSL-terminating proxy in front of Puma on Render, so req.ip has
# to decide which REMOTE_ADDRs to trust before it can believe
# X-Forwarded-For at all — and stock Rack::Request#ip makes that call with
# its own hardcoded proxy list, entirely independent of
# config.action_dispatch.trusted_proxies (see config/environments/production.rb
# for what that's set to, and why). Left alone, that independence is a real
# risk in both directions: if trusted_proxies is ever tuned to match
# Render's actual edge, req.ip would silently keep using its own stale
# answer instead and collapse every guest into one throttle bucket; and
# Rack::Request#ip's default trust list, taken as-is, has no opinion about
# *this* app's proxy at all.
#
# Rack::Attack::Request is the gem's own documented customization point for
# exactly this (see the comment the generator leaves in
# rack/attack/request.rb) — overriding #trusted_proxy? here, on this
# subclass only, makes every throttle's trust decision follow the app's
# single configured source of truth without globally patching
# Rack::Request for every other piece of code in the process that
# constructs one.
class Rack::Attack::Request < ::Rack::Request
  def trusted_proxy?(ip)
    trusted_proxies = Rails.application.config.action_dispatch.trusted_proxies.presence ||
      ActionDispatch::RemoteIp::TRUSTED_PROXIES

    trusted_proxies.any? { |proxy| proxy === ip }
  rescue IPAddr::Error
    # A malformed value in REMOTE_ADDR or X-Forwarded-For can't be trusted
    # by definition — fail closed (not a proxy), not open.
    false
  end
end

class Rack::Attack
  # Slice 2's room/QR entry form — where a guest lands right after scanning
  # the printed card and types (or confirms) a room number.
  throttle("guest_entry/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.post? && req.path.start_with?("/h/")
  end

  # Slice 2's guest chat — sending a message to the concierge.
  throttle("guest_messages/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.post? && req.path.start_with?("/guest/")
  end

  # The sign-in form is the other unauthenticated surface every staff member
  # and platform admin reaches before a session exists — bounding attempts
  # here backstops bcrypt's own cost factor against a brute-force script.
  throttle("logins/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/session"
  end

  # Load balancers and uptime monitors (Render's health check, this app's
  # own Ops::HeartbeatJob target) hit /up constantly and must never be
  # throttled, or the health check itself starts failing.
  safelist("health_check") do |req|
    req.path == "/up"
  end

  # Reserved: Slice 6 adds POST /webhooks/whatsapp. A throttled webhook
  # delivery reads to Meta as a failure and makes it back off — which
  # silently drops guest messages arriving over WhatsApp, the opposite of
  # what this file is for. When that endpoint exists, safelist requests that
  # already carry a *verified* WhatsApp signature (never an unauthenticated
  # safelist — that would just move the abuse surface instead of closing
  # it):
  #
  #   safelist("whatsapp_webhook") { |req| req.path == "/webhooks/whatsapp" && verified_whatsapp_signature?(req) }
end
