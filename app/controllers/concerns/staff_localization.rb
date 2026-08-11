# Scopes I18n.locale to the signed-in staff member's own language for
# exactly one request. Included by Staff::BaseController, so every staff
# screen renders in the language the person reading it actually speaks.
#
# This is deliberately keyed off **User#locale**, never Hotel#staff_locale:
# the hotel-level setting is the *translation target* for guest<->staff
# overlays (Message#translation_target_locale, the request-summary overlay —
# one fixed language per hotel, because that copy is written once and read by
# whoever is on shift), while the UI chrome a given person reads is a
# property of that person. A Bosnian receptionist and an English-speaking
# manager work the same hotel and must each see their own language — keying
# this off the hotel would show them both the same one.
#
# `I18n.with_locale(locale) { yield }`, not a bare assignment, for the exact
# reason GuestLocalization documents: I18n.locale is thread-local, process-
# lived state with no framework hook that resets it between requests, so an
# assignment would leak one staff member's language into the next request
# Puma happens to run on that same thread — guest or staff, including a
# platform admin's own (currently English-only) screens.
module StaffLocalization
  extend ActiveSupport::Concern

  private
    # `wanted` may be blank or a locale this workspace no longer offers (a
    # stale value from before Hotel::STAFF_LOCALES changed, or simply a
    # platform admin — who has no hotel and today always reads en) — falls
    # back to the default locale rather than ever raising or rendering a
    # "translation missing" string.
    def staff_locale_for(wanted)
      resolved = Hotel::STAFF_LOCALES.include?(wanted.to_s) ? wanted.to_s : GuestLocaleHelper::DEFAULT_LOCALE
      resolved.to_sym
    end
end
