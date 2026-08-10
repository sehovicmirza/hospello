require "test_helper"

class GuestLocaleHelperTest < ActiveSupport::TestCase
  test "picks the exact match when only one supported locale is offered" do
    assert_equal "bs", GuestLocaleHelper.detect("bs")
  end

  test "matches a region-qualified tag to its base language" do
    assert_equal "bs", GuestLocaleHelper.detect("bs-BA")
  end

  test "honors quality values rather than just taking the first tag" do
    # en is listed first but scores lower than de — de must win.
    assert_equal "de", GuestLocaleHelper.detect("en;q=0.5,de;q=0.9")
  end

  test "picks the highest-quality supported locale even when unsupported locales rank higher" do
    # fr (unsupported) is preferred over en, but only en is one of our four.
    assert_equal "en", GuestLocaleHelper.detect("fr;q=0.9,en;q=0.8")
  end

  test "a realistic multi-language header picks the best supported match" do
    assert_equal "de", GuestLocaleHelper.detect("de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7")
  end

  test "falls back to en when nothing in the header is supported" do
    assert_equal "en", GuestLocaleHelper.detect("fr-FR,fr;q=0.9,es;q=0.8")
  end

  test "falls back to en for a blank header" do
    assert_equal "en", GuestLocaleHelper.detect("")
    assert_equal "en", GuestLocaleHelper.detect(nil)
  end

  test "falls back to en for a malformed header instead of raising" do
    assert_equal "en", GuestLocaleHelper.detect(";;garbage;;q=not-a-number,,,")
  end

  test "a malformed quality value on an otherwise-supported tag does not raise and does not crash the match" do
    assert_equal "ar", GuestLocaleHelper.detect("ar;q=bogus")
  end

  test "matches are case-insensitive" do
    assert_equal "de", GuestLocaleHelper.detect("DE-de")
  end

  test "wildcard entries are ignored, not treated as a supported match" do
    assert_equal "en", GuestLocaleHelper.detect("*;q=0.9,en;q=0.5")
  end
end
