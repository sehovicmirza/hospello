module Whatsapp
  # Base class for every failure Whatsapp::Provider is allowed to surface.
  #
  # Nothing outside a Provider adapter (MetaCloudProvider today) rescues an
  # HTTP status or a transport exception directly — the same seam discipline
  # Ai::Error documents around the Anthropic SDK. `rescue Whatsapp::Error` is
  # the catch-all for "the send did not work"; rescue a subclass when the
  # difference matters (a caller must treat WindowClosedError as "ask the
  # guest to message first, or use a template" and AuthenticationError as
  # "wake someone up to fix the config" — very different responses to the
  # same broad failure).
  class Error < StandardError; end
end
