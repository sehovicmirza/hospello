# Shared by every guest-facing controller (Guest::EntriesController
# directly; Guest::BaseController, and so everything under it, via its own
# around_action) to scope I18n.locale to the guest's own language for
# exactly one request. The landing page, the entry form, and the chat are
# all guest-supplied-language surfaces end to end — not just the language
# <select>'s preselected option (brief Step 5) — so this runs on every
# request in this namespace, not only the ones that show the form.
#
# `I18n.with_locale(locale) { yield }`, not a bare `I18n.locale = locale`:
# I18n.locale is thread-local, *process*-lived state with no framework
# hook that resets it between requests on its own — a bare assignment
# would leak whatever a guest last chose (say, :ar) into the next request
# Puma happens to run on that same thread, guest or not, including a
# staff member's session or an unrelated model-level test. with_locale
# restores the prior value in an ensure block when this request's block
# returns, however it returns (render, redirect, or a raised exception).
module GuestLocalization
  extend ActiveSupport::Concern

  private
    # `wanted` may be blank, garbage, or a locale this app doesn't support
    # (a tampered param, a guest session row that somehow predates a locale
    # being dropped) — falls back to Accept-Language detection rather than
    # ever raising.
    def guest_locale_for(wanted)
      resolved = GuestLocaleHelper::SUPPORTED_LOCALES.include?(wanted.to_s) ? wanted.to_s : GuestLocaleHelper.detect(request.headers["Accept-Language"])
      resolved.to_sym
    end
end
