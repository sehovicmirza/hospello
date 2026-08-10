# The four languages the guest-facing surface is translated into (Slice 2's
# entry form, chat, and privacy notice — see config/locales/guest.*.yml).
# The single source of truth for "what is a valid guest locale": GuestSession
# validates against this same list, so a locale that can't be detected here
# can't be saved there either.
module GuestLocaleHelper
  SUPPORTED_LOCALES = %w[bs en de ar].freeze
  DEFAULT_LOCALE = "en".freeze

  # Each guest locale's own name for itself, in the order offered on the
  # entry form's language <select> — not the guest's current locale (a
  # Bosnian speaker choosing their language still needs to recognize
  # "Deutsch", not see it as "Njemački").
  LOCALE_NAMES = {
    "bs" => "Bosanski",
    "en" => "English",
    "de" => "Deutsch",
    "ar" => "العربية"
  }.freeze

  # Arabic is the only guest locale that reads right-to-left; kept as a set
  # (not a single `== "ar"` check scattered around) so a future guest
  # locale that is also RTL is one line here, not a hunt through every
  # `== "ar"`.
  RTL_LOCALES = %w[ar].freeze

  module_function

  def rtl?(locale)
    RTL_LOCALES.include?(locale.to_s)
  end

  # Picks the best of SUPPORTED_LOCALES from a raw `Accept-Language` header,
  # e.g. "bs-BA,bs;q=0.9,en;q=0.8" or "de-DE,de;q=0.9,*;q=0.5" — parsing the
  # quality value (`;q=`) properly rather than just taking the first tag, and
  # matching on the language subtag alone (`bs-BA` -> `bs`) since the header
  # carries region variants none of the four guest locales distinguish.
  # Falls back to DEFAULT_LOCALE for a blank, malformed, or entirely
  # unsupported header — this must never raise, since it runs on every
  # unauthenticated guest landing-page hit.
  def detect(accept_language_header)
    return DEFAULT_LOCALE if accept_language_header.blank?

    ranked_languages(accept_language_header).each do |language|
      match = SUPPORTED_LOCALES.find { |locale| language == locale || language.start_with?("#{locale}-") }
      return match if match
    end

    DEFAULT_LOCALE
  end

  # Parses "en-US;q=0.8, bs;q=0.9, *;q=0.1" into language tags ordered from
  # highest quality to lowest, ignoring any token that isn't shaped like a
  # language tag (a malformed header degrades to "no match", not a raise).
  def ranked_languages(header)
    header.to_s.split(",").filter_map do |part|
      tag, *params = part.strip.split(";").map(&:strip)
      next if tag.blank?

      quality = params
        .find { |param| param.start_with?("q=") }
        &.delete_prefix("q=")
        &.then { |value| Float(value, exception: false) } || 1.0

      [ tag.downcase, quality ]
    end.sort_by { |(_tag, quality)| -quality }.map(&:first)
  end
end
