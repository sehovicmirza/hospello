# Throttles the app's unauthenticated public surface — the endpoints an
# attacker (or a mis-behaving script) can hit without ever having an
# account. Guests scan a QR code straight into these paths with no session
# and no CSRF-protected form to slow a script down, so IP-based throttling
# at the Rack layer is the only cheap backstop before Slice 2's actual guest
# controllers exist. Every throttle here keys on req.ip: returning nil from
# a throttle block (as these do for any request the block's condition
# doesn't match) tells Rack::Attack "this rule doesn't apply," not "block
# it" — Rack::Attack's own documented behavior.
#
# Disabled by default in test (config/environments/test.rb) so shared
# throttle counters can't make unrelated tests flaky — see
# test/integration/rack_attack_test.rb for the tests that turn it back on.
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
