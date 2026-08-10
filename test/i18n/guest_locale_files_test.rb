require "test_helper"

# CRITICAL 2 (review round 1): before this test existed, deleting every key
# from config/locales/guest.ar.yml (or any of the other three) left the
# entire suite green — config.i18n.fallbacks = true quietly absorbed a
# missing key by rendering the English string instead, with nothing
# checking that each locale actually still carries its own copy. This reads
# the four files directly off disk (not through I18n's own lookup, which
# would apply that same fallback and could pass vacuously against a broken
# file) and compares their key sets and interpolation variables structurally.
class GuestLocaleFilesTest < ActiveSupport::TestCase
  LOCALES = GuestLocaleHelper::SUPPORTED_LOCALES

  test "every guest locale file declares exactly the same set of translation keys" do
    key_sets = LOCALES.index_with { |locale| flattened_translations(locale).keys.to_set }

    reference_locale = LOCALES.first
    reference_keys = key_sets.fetch(reference_locale)

    key_sets.each do |locale, keys|
      next if locale == reference_locale

      missing = (reference_keys - keys).to_a.sort
      extra = (keys - reference_keys).to_a.sort

      assert_empty missing, "guest.#{locale}.yml is missing keys present in guest.#{reference_locale}.yml: #{missing.join(', ')}"
      assert_empty extra, "guest.#{locale}.yml has keys not present in guest.#{reference_locale}.yml: #{extra.join(', ')}"
    end
  end

  test "every guest locale file uses the same %{interpolation} variables for a given key" do
    translations_by_locale = LOCALES.index_with { |locale| flattened_translations(locale) }
    all_keys = translations_by_locale.values.flat_map(&:keys).uniq

    mismatches = all_keys.filter_map do |key|
      variables_by_locale = LOCALES.index_with do |locale|
        interpolation_variables(translations_by_locale.dig(locale, key))
      end

      next if variables_by_locale.values.map(&:sort).uniq.size <= 1

      "#{key}: " + variables_by_locale.map { |locale, vars| "#{locale}=#{vars.sort.inspect}" }.join(", ")
    end

    assert_empty mismatches, "interpolation variables differ across guest locale files:\n  #{mismatches.join("\n  ")}"
  end

  test "no guest locale file has a blank translation for a key another locale fills in" do
    translations_by_locale = LOCALES.index_with { |locale| flattened_translations(locale) }

    blanks = translations_by_locale.flat_map do |locale, translations|
      translations.filter_map { |key, value| "#{locale}: #{key}" if value.blank? }
    end

    assert_empty blanks, "these guest locale keys are present but blank:\n  #{blanks.join("\n  ")}"
  end

  private
    def flattened_translations(locale, hash = load_guest_yaml(locale), prefix = nil)
      hash.each_with_object({}) do |(key, value), result|
        full_key = prefix ? "#{prefix}.#{key}" : key.to_s
        if value.is_a?(Hash)
          result.merge!(flattened_translations(locale, value, full_key))
        else
          result[full_key] = value
        end
      end
    end

    def load_guest_yaml(locale)
      # Rails.root.join keeps this test independent of I18n's own load path
      # / fallback configuration — it must see exactly what's on disk for
      # this one file, nothing merged in from another locale.
      YAML.load_file(Rails.root.join("config/locales/guest.#{locale}.yml")).fetch(locale.to_s)
    end

    def interpolation_variables(value)
      value.to_s.scan(/%\{(\w+)\}/).flatten.sort
    end
end
