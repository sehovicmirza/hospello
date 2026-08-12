require "test_helper"

# **The test this whole task exists to end with.** A retention policy and a
# privacy notice are two statements of the same promise, made to different
# audiences, in five places (a Ruby file and four locale files). Nothing
# stops them drifting apart except this — and drift here is the one kind
# that cannot be fixed afterwards, because the promise was already made to
# real guests who have already left.
#
# It works in **both directions**, which is what makes it more than a
# decoration:
#
#   1. every number Retention::Policy says a guest is entitled to know
#      appears in every language's notice, and
#   2. every number that appears in a notice is one of the policy's — so
#      "we keep it for 180 days" cannot be added to the German copy alone
#      and sit there for a year.
#
# **Why the copy carries literal numbers rather than interpolating them from
# the policy.** Interpolation would make one source of truth and no possible
# drift, which sounds strictly better — and would make this test unable to
# fail, which is this codebase's dominant defect (see
# docs/plan/engineering-rules.md, rule 1). A promise changing from 90 days
# to 60 has to be a change somebody makes to the sentence a guest reads, in
# every language, deliberately. This test is what forces that, and it goes
# red the moment either side moves without the other.
#
# The locale files are read **off disk** rather than through I18n.t, for the
# reason test/i18n/locale_files_test.rb documents: fallbacks are on, so a
# missing Arabic key renders the English string and nothing notices.
class PrivacyNoticeRetentionTest < ActionDispatch::IntegrationTest
  LOCALES = GuestLocaleHelper::SUPPORTED_LOCALES

  # What the notice has to state, and where each number comes from. Read from
  # the policy at runtime, never typed here — typing them would make this two
  # tests that agree with each other rather than one that binds the policy to
  # the copy.
  def retention_numbers
    [
      Retention::Policy.rule_for(:messages).delete_after_days,
      Retention::Policy.rule_for(:service_requests).delete_after_days,
      Retention::Policy.rule_for(:service_requests).redact_after_days
    ].uniq
  end

  test "every guest language's privacy notice states the real retention periods" do
    retention_numbers.each do |days|
      LOCALES.each do |locale|
        assert_includes numbers_in(privacy_body(locale)), days,
          "guest.#{locale}.yml's privacy notice does not state #{days} days, which is what " \
          "Retention::Policy actually does — one of the two is wrong, and only one of them " \
          "is a promise made to a guest"
      end
    end
  end

  test "no privacy notice states a retention period the code does not keep" do
    LOCALES.each do |locale|
      invented = numbers_in(privacy_body(locale)) - retention_numbers

      assert_empty invented,
        "guest.#{locale}.yml's privacy notice promises #{invented.join(', ')}, which appears " \
        "nowhere in Retention::Policy"
    end
  end

  # The file on disk being right is not the same as a guest seeing it. This
  # is the complement: a real request to the real landing page, in each
  # language, asserting the numbers reach the page — and that the sentence
  # around them is genuinely that language rather than an English fallback
  # that happens to carry the same digits.
  IN_ITS_OWN_WORDS = {
    "bs" => "90 dana",
    "en" => "for 90 days",
    "de" => "90 Tage",
    "ar" => "90 يوما"
  }.freeze

  test "a guest is shown the real retention periods, in their own language" do
    IN_ITS_OWN_WORDS.each do |locale, phrase|
      get hotel_landing_path(hotels(:stari_grad).slug), headers: { "Accept-Language" => locale }

      assert_response :success
      assert_select "#privacy-notice", text: /#{Regexp.escape(phrase)}/,
        message: "the #{locale} privacy notice does not say “#{phrase}” — either it is falling " \
                 "back to another language, or the notice no longer states how long a chat is kept"
      assert_select "#privacy-notice", text: /365/
    end
  end

  # The notice is what a guest reads *before* consenting, so it has to be on
  # the page they consent from, not only in a file.
  test "the retention periods are on the page the guest consents from" do
    get hotel_landing_path(hotels(:stari_grad).slug)

    assert_response :success
    assert_select "#privacy-notice", text: /90 days/
    assert_select "form input[name=?]", "guest_session[consent]"
  end

  private
    # Straight off disk — never I18n.t, which would apply the fallback this
    # is checking for.
    def privacy_body(locale)
      YAML.load_file(Rails.root.join("config/locales/guest.#{locale}.yml"))
        .dig(locale.to_s, "guest", "entries", "privacy_notice", "body")
        .to_s
    end

    # Ai::DigitGuard's own folding, reused rather than reimplemented: a
    # language may legitimately write ٩٠, and a test that read that as "the
    # number is missing" would push the Arabic copy into a shape chosen to
    # satisfy a test rather than to be read.
    def numbers_in(text) = Ai::DigitGuard.numbers_in(text)
end
