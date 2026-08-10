# Shared by every guest-facing controller (Guest::EntriesController
# directly; Guest::BaseController, and so everything under it, via its own
# call) to activate I18n.locale for the guest's own language before
# rendering. The landing page, the entry form, and the chat are all
# guest-supplied-language surfaces end to end — not just the language
# <select>'s preselected option (brief Step 5) — so this runs on every
# request in this namespace, not only the ones that show the form.
module GuestLocalization
  extend ActiveSupport::Concern

  private
    # `wanted` may be blank, garbage, or a locale this app doesn't support
    # (a tampered param, a guest session row that somehow predates a locale
    # being dropped) — falls back to Accept-Language detection rather than
    # ever raising or leaving I18n.locale on whatever the previous request
    # in this process left it on.
    def activate_guest_locale(wanted)
      resolved = GuestLocaleHelper::SUPPORTED_LOCALES.include?(wanted.to_s) ? wanted.to_s : GuestLocaleHelper.detect(request.headers["Accept-Language"])
      I18n.locale = resolved.to_sym
    end
end
