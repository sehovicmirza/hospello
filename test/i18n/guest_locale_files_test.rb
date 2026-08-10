require "test_helper"

# CRITICAL 2 (review round 1): before this test existed, deleting every key
# from config/locales/guest.ar.yml (or any of the other three) left the
# entire suite green — config.i18n.fallbacks = true quietly absorbed a
# missing key by rendering the English string instead, with nothing
# checking that each locale actually still carries its own copy. This reads
# the four files directly off disk (not through I18n's own lookup, which
# would apply that same fallback and could pass vacuously against a broken
# file) and compares their key sets and interpolation variables structurally.
#
# It covers every guest-facing locale family, not just `guest.*`. The
# `degraded.*` family matters at least as much: those strings are what a guest
# sees when the model is unavailable, and a missing Arabic key there would
# silently answer an Arabic-speaking guest in English at the exact moment the
# product is already failing.
class GuestLocaleFilesTest < ActiveSupport::TestCase
  LOCALES = GuestLocaleHelper::SUPPORTED_LOCALES
  FAMILIES = %w[guest degraded requests].freeze

  test "every guest locale file declares exactly the same set of translation keys" do
    FAMILIES.each do |family|
      key_sets = LOCALES.index_with { |locale| flattened_translations(family, locale).keys.to_set }

      reference_locale = LOCALES.first
      reference_keys = key_sets.fetch(reference_locale)

      key_sets.each do |locale, keys|
        next if locale == reference_locale

        missing = (reference_keys - keys).to_a.sort
        extra = (keys - reference_keys).to_a.sort

        assert_empty missing,
          "#{family}.#{locale}.yml is missing keys present in #{family}.#{reference_locale}.yml: #{missing.join(', ')}"
        assert_empty extra,
          "#{family}.#{locale}.yml has keys not present in #{family}.#{reference_locale}.yml: #{extra.join(', ')}"
      end
    end
  end

  test "every guest locale file uses the same %{interpolation} variables for a given key" do
    FAMILIES.each do |family|
      translations_by_locale = LOCALES.index_with { |locale| flattened_translations(family, locale) }
      all_keys = translations_by_locale.values.flat_map(&:keys).uniq

      mismatches = all_keys.filter_map do |key|
        variables_by_locale = LOCALES.index_with do |locale|
          interpolation_variables(translations_by_locale.dig(locale, key))
        end

        next if variables_by_locale.values.map(&:sort).uniq.size <= 1

        "#{key}: " + variables_by_locale.map { |locale, vars| "#{locale}=#{vars.sort.inspect}" }.join(", ")
      end

      assert_empty mismatches,
        "interpolation variables differ across #{family} locale files:\n  #{mismatches.join("\n  ")}"
    end
  end

  test "no guest locale file has a blank translation for a key another locale fills in" do
    FAMILIES.each do |family|
      translations_by_locale = LOCALES.index_with { |locale| flattened_translations(family, locale) }

      blanks = translations_by_locale.flat_map do |locale, translations|
        translations.filter_map { |key, value| "#{locale}: #{key}" if value.blank? }
      end

      assert_empty blanks, "these #{family} locale keys are present but blank:\n  #{blanks.join("\n  ")}"
    end
  end

  # A guest whose language has no translation of the fallback message is a
  # guest who, at the worst possible moment, gets English. Asserted through
  # I18n rather than off disk on purpose — this one is about what a real
  # request would render, and it is the complement to the structural checks
  # above.
  #
  # Both keys are ones a *controller or a job* posts, with no model involved:
  # the degradation notice when the assistant is unavailable, and the receipt
  # when a guest taps Confirm on a summary card. Neither can fall back to a
  # live translation, so the file on disk is the only thing standing between a
  # guest and a message in the wrong language.
  UNTRANSLATABLE_AT_RUNTIME = %w[degraded.reception_will_reply requests.sent_to_reception].freeze

  test "every guest language has its own words for the messages nothing can translate later" do
    UNTRANSLATABLE_AT_RUNTIME.each do |key|
      rendered = LOCALES.index_with { |locale| I18n.t(key, locale: locale) }

      assert_equal LOCALES.length, rendered.values.uniq.length,
        "two languages share #{key}, which means at least one is falling back to another: #{rendered.inspect}"
      rendered.each_value { |string| assert_no_match(/translation missing/i, string) }
    end
  end

  private
    def flattened_translations(family, locale, hash = nil, prefix = nil)
      hash ||= load_locale_yaml(family, locale)

      hash.each_with_object({}) do |(key, value), result|
        full_key = prefix ? "#{prefix}.#{key}" : key.to_s
        if value.is_a?(Hash)
          result.merge!(flattened_translations(family, locale, value, full_key))
        else
          result[full_key] = value
        end
      end
    end

    def load_locale_yaml(family, locale)
      # Rails.root.join keeps this test independent of I18n's own load path
      # / fallback configuration — it must see exactly what's on disk for
      # this one file, nothing merged in from another locale.
      YAML.load_file(Rails.root.join("config/locales/#{family}.#{locale}.yml")).fetch(locale.to_s)
    end

    def interpolation_variables(value)
      value.to_s.scan(/%\{(\w+)\}/).flatten.sort
    end
end
