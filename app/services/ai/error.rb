module Ai
  # Base class for every failure the AI seam is allowed to surface.
  #
  # Nothing outside `Ai::Client` rescues an `Anthropic::Errors::*` class. That
  # is the whole point of the seam: swapping or upgrading the SDK, or putting
  # the calls behind a proxy, touches one file instead of every job, service and
  # controller that ever talks to a model.
  #
  # `rescue Ai::Error` is the catch-all for "the model call did not work". Rescue
  # a subclass when the difference matters — the circuit breaker counts timeouts
  # and 5xx but must not open on a 400, because a malformed request will fail
  # identically forever and tripping the breaker on it would take the concierge
  # down for every hotel over one bad prompt.
  class Error < StandardError; end
end
