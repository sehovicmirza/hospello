module Whatsapp
  # Meta's own rule, not Hospello's, and it cannot be negotiated: more than
  # 24 hours after a guest's last inbound message, only a pre-approved
  # template (#send_template) may be sent — a free-form #send_text is
  # refused before it ever reaches the network.
  #
  # Raised by the provider itself (see Whatsapp::Provider's class comment for
  # why it lives there rather than in every future caller), so this is
  # always a signal to fall back to a template or wait for the guest to
  # message again — never a transient failure worth retrying as-is.
  class WindowClosedError < Error; end
end
