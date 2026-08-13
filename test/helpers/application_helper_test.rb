require "test_helper"

# The `tel:` link under "the chat is not an emergency channel — call reception"
# is the one a guest taps when something has actually gone wrong, and until this
# existed nothing tested it at all. Three views each did their own whitespace
# strip, so the href carried whatever punctuation the hotel admin had typed.
class ApplicationHelperTest < ActionView::TestCase
  test "a number is reduced to something a phone can dial" do
    assert_equal "+38733483900", dialable_phone("+387 33 483-900")
    assert_equal "+38733947947", dialable_phone("+387 33 947 947")
    assert_equal "+38733483900", dialable_phone("+387 (33) 483 900")
    assert_equal "+38733483900", dialable_phone("+387.33.483.900")
  end

  # The leading + is what makes a number dialable from another country, which
  # is most of this product's guests. Dropping it would turn an international
  # number into a local one that fails silently from abroad.
  test "a leading plus survives, because most guests are dialling from abroad" do
    assert_equal "+38733483900", dialable_phone("+387 33 483-900")
    assert_equal "033483900", dialable_phone("033 483 900"), "a local number stays local"
  end

  test "nothing dialable in, empty string out" do
    assert_equal "", dialable_phone(nil)
    assert_equal "", dialable_phone("")
    assert_equal "", dialable_phone("call reception")
  end

  # The seeded hotels are the real formats this has to survive: ibis Styles
  # publishes its number with a hyphen, the others with spaces.
  test "every demo hotel's published format produces a clean href" do
    [
      "+387 33 947 947",  # Hotel Hills
      "+387 33 773 100",  # Hotel Hollywood
      "+387 32 731 000",  # Hotel Vema
      "+387 33 483-900"   # ibis Styles — the one with a hyphen
    ].each do |published|
      href = dialable_phone(published)

      assert_match(/\A\+[0-9]+\z/, href, "#{published.inspect} produced #{href.inspect}")
    end
  end
end
