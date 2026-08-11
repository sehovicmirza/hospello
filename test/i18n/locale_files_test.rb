require "test_helper"

# CRITICAL 2 (review round 1): before this test existed, deleting every key
# from config/locales/guest.ar.yml (or any of the other three) left the
# entire suite green — config.i18n.fallbacks = true quietly absorbed a
# missing key by rendering the English string instead, with nothing
# checking that each locale actually still carries its own copy. This reads
# the files directly off disk (not through I18n's own lookup, which would
# apply that same fallback and could pass vacuously against a broken file)
# and compares their key sets and interpolation variables structurally.
#
# Renamed from guest_locale_files_test.rb (Slice 5 Task 4): it stopped being
# guest-only the moment `staff` joined the family list below. `staff` has
# its own reason to matter here as much as the guest families do — a
# missing Bosnian key in the staff workspace would quietly show a Bosnian
# receptionist an English sentence, via the exact same fallback mechanism
# that this test exists to catch on the guest side.
#
# FAMILY_LOCALES, not one shared LOCALES constant: the guest-facing families
# (guest itself, degraded, requests) are translated into all four guest
# languages, but the staff workspace only ever speaks Hotel::STAFF_LOCALES
# (bs/en) — conflating the two lists would either demand Arabic and German
# staff copy nobody asked for, or silently stop checking German and Arabic
# guest copy. Keeping a locale set per family is what makes both mistakes
# impossible rather than merely unlikely.
class LocaleFilesTest < ActiveSupport::TestCase
  FAMILY_LOCALES = {
    "guest" => GuestLocaleHelper::SUPPORTED_LOCALES,
    "degraded" => GuestLocaleHelper::SUPPORTED_LOCALES,
    "requests" => GuestLocaleHelper::SUPPORTED_LOCALES,
    "staff" => Hotel::STAFF_LOCALES
  }.freeze

  # A pluralised key is one key, not one key per grammatical form. Bosnian
  # needs three forms where English needs two (1 soba, 2 sobe, 5 soba), so
  # comparing raw leaf paths across a family would demand English grow a
  # `few` it has no use for — and the only way to satisfy that is to write
  # English twice and call it a translation. Plural groups collapse to the
  # group path here; the forms inside them are checked, per locale and
  # against that locale's own rule, by the test below this one.
  PLURAL_FORMS = %w[zero one two few many other].freeze

  # `other` on its own does not make a group plural — `staff.common.kb_categories`
  # is a list of knowledge-base categories, one of which is literally called
  # "other", and reading that as a pluralisation would demand Bosnian forms of
  # a category name. A group counts as plural only when every leaf is a plural
  # form AND at least one of them is count-specific.
  COUNT_SPECIFIC_FORMS = %w[zero one two few many].freeze

  test "every locale file declares exactly the same set of translation keys as its own family" do
    FAMILY_LOCALES.each do |family, locales|
      key_sets = locales.index_with { |locale| translation_keys_collapsing_plurals(family, locale) }

      reference_locale = locales.first
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

  # The only thing standing between a missing Bosnian plural form and a hotel.
  #
  # config/initializers/pluralization.rb gives each locale its real rule, so
  # I18n asks Bosnian for `few` at count 2. A key that carries only
  # `one`/`other` does not raise — measured, not assumed: I18n falls back to
  # `other` and renders "2 soba dodano" where the language wants "2 sobe
  # dodane". Nothing in the app ever reports that, which is exactly why it
  # needs a test rather than a runtime guard. Checked per locale against that
  # locale's own declared forms, because the families disagree: Bosnian needs
  # three, English two.
  test "every pluralised key carries exactly the forms its own language's rule asks for" do
    FAMILY_LOCALES.each do |family, locales|
      locales.each do |locale|
        required = I18n.t("i18n.plural.keys", locale: locale, default: nil)&.map(&:to_s) || %w[one other]

        plural_groups(family, locale).each do |group, forms|
          missing = required - forms
          extra = forms - required

          assert_empty missing,
            "#{family}.#{locale}.yml: #{group} is missing #{missing.join(', ')} — " \
            "#{locale} pluralisation asks for #{required.join('/')}, so this raises at those counts"
          assert_empty extra,
            "#{family}.#{locale}.yml: #{group} has #{extra.join(', ')}, which #{locale} never asks for"
        end
      end
    end
  end

  test "every locale file uses the same %{interpolation} variables for a given key" do
    FAMILY_LOCALES.each do |family, locales|
      translations_by_locale = locales.index_with { |locale| flattened_translations(family, locale) }
      all_keys = translations_by_locale.values.flat_map(&:keys).uniq
        .reject { |key| PLURAL_FORMS.include?(key.split(".").last) }

      mismatches = all_keys.filter_map do |key|
        variables_by_locale = locales.index_with do |locale|
          interpolation_variables(translations_by_locale.dig(locale, key))
        end

        next if variables_by_locale.values.map(&:sort).uniq.size <= 1

        "#{key}: " + variables_by_locale.map { |locale, vars| "#{locale}=#{vars.sort.inspect}" }.join(", ")
      end

      assert_empty mismatches,
        "interpolation variables differ across #{family} locale files:\n  #{mismatches.join("\n  ")}"
    end
  end

  test "no locale file has a blank translation for a key another locale in its family fills in" do
    FAMILY_LOCALES.each do |family, locales|
      translations_by_locale = locales.index_with { |locale| flattened_translations(family, locale) }

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
  # guest and a message in the wrong language. Guest-facing only — the staff
  # workspace has no equivalent "posted with no model in the loop and must
  # never fall back" message; every staff string is either static chrome
  # (which the tests above already cover) or copy already reused from the
  # guest families (config/locales/guest.*.yml — see the staff translation
  # overlay's fallback note, which does exactly that).
  UNTRANSLATABLE_AT_RUNTIME = %w[degraded.reception_will_reply requests.sent_to_reception].freeze

  test "every guest language has its own words for the messages nothing can translate later" do
    locales = GuestLocaleHelper::SUPPORTED_LOCALES

    UNTRANSLATABLE_AT_RUNTIME.each do |key|
      rendered = locales.index_with { |locale| I18n.t(key, locale: locale) }

      assert_equal locales.length, rendered.values.uniq.length,
        "two languages share #{key}, which means at least one is falling back to another: #{rendered.inspect}"
      rendered.each_value { |string| assert_no_match(/translation missing/i, string) }
    end
  end

  private
    # Every leaf path, with a plural group's forms folded back into the group
    # itself — so `…created_phrase.one` and `…created_phrase.few` both read as
    # `…created_phrase`, one key that every language in the family must carry.
    def translation_keys_collapsing_plurals(family, locale)
      groups = plural_groups(family, locale)

      flattened_translations(family, locale).keys.map { |key|
        parent = key.split(".")[0..-2].join(".")
        groups.key?(parent) ? parent : key
      }.to_set
    end

    # group path => the plural forms it actually declares on disk, for the
    # groups that really are pluralisations (see COUNT_SPECIFIC_FORMS).
    def plural_groups(family, locale)
      by_parent = flattened_translations(family, locale).keys.group_by { |key| key.split(".")[0..-2].join(".") }

      by_parent.each_with_object({}) do |(parent, keys), groups|
        leaves = keys.map { |key| key.split(".").last }
        next unless leaves.all? { |leaf| PLURAL_FORMS.include?(leaf) }
        next unless leaves.any? { |leaf| COUNT_SPECIFIC_FORMS.include?(leaf) }

        groups[parent] = leaves
      end
    end

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
