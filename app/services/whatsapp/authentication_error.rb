module Whatsapp
  # HTTP 401 — an invalid or expired WHATSAPP_ACCESS_TOKEN (Meta reports this
  # as an OAuthException, error code 190).
  #
  # Not something a retry ever fixes: someone has to correct the configured
  # token. Kept as its own type, distinct from Whatsapp::ApiError, so a
  # caller (and any future alerting) can tell "our credentials are wrong"
  # apart from "Meta had a bad minute" without string-matching a message —
  # see docs/plan/slice-6-tasks.md's "typed errors" requirement.
  class AuthenticationError < Error; end
end
