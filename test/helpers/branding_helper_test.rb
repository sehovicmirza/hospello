require "test_helper"

class BrandingHelperTest < ActionView::TestCase
  include BrandingHelper

  test "emits CSS custom properties for the hotel's colors" do
    style = hotel_brand_style(hotels(:stari_grad))
    assert_includes style, "--brand-primary:#1F3A5F"
    assert_includes style, "--brand-secondary:#C9A227"
  end

  test "picks a readable on-primary color for a light brand color" do
    hotel = hotels(:stari_grad)
    hotel.primary_color = "#FFFFFF"
    assert_includes hotel_brand_style(hotel), "--brand-on-primary:#111827"
  end

  test "picks a readable on-primary color for a dark brand color" do
    hotel = hotels(:stari_grad)
    hotel.primary_color = "#000000"
    assert_includes hotel_brand_style(hotel), "--brand-on-primary:#FFFFFF"
  end

  # Guest views in Slice 2 interpolate this directly into a style=""
  # attribute; the produced-interface contract calls for an HTML-safe
  # string specifically so that works with no further wrapping.
  test "returns an HTML-safe string" do
    assert_predicate hotel_brand_style(hotels(:stari_grad)), :html_safe?
  end

  # Review round 1, Important 2: this helper renders on Staff::HotelSettingsController's
  # :edit template, which re-renders with whatever the admin just typed on a
  # failed save — including a blank or malformed color, before Hotel's own
  # format validation has a chance to show its error. A public guest page in
  # Slice 2 puts this on <body>; raising is the wrong shape for either caller.
  test "does not raise for a blank primary color" do
    hotel = hotels(:stari_grad)
    hotel.primary_color = ""

    style = hotel_brand_style(hotel)

    assert_includes style, "--brand-primary:#1F3A5F" # falls back to Hotel's own column default
  end

  test "does not raise for a primary color that isn't hex at all" do
    hotel = hotels(:stari_grad)
    hotel.primary_color = "blue"

    style = hotel_brand_style(hotel)

    assert_includes style, "--brand-primary:#1F3A5F"
  end

  test "does not raise for a nil primary color" do
    hotel = hotels(:stari_grad)
    hotel.primary_color = nil

    style = hotel_brand_style(hotel)

    assert_includes style, "--brand-primary:#1F3A5F"
  end

  test "falls back to the default secondary color too when it is invalid" do
    hotel = hotels(:stari_grad)
    hotel.secondary_color = "not-a-color"

    assert_includes hotel_brand_style(hotel), "--brand-secondary:#C9A227"
  end

  # Review round 1, Important 3: html_safe was asserted, not established — a
  # value that survives the six-hex-digit shape (three hex pairs) but carries
  # a trailing attribute breaks out of style="" once marked safe. This must
  # never reach the output at all, not merely "come out escaped".
  test "an attribute-breakout payload is replaced by the default, never rendered" do
    hotel = hotels(:stari_grad)
    hotel.primary_color = %(#abcdef" onmouseover="alert(1)")

    style = hotel_brand_style(hotel)

    assert_not_includes style, "onmouseover"
    assert_includes style, "--brand-primary:#1F3A5F"
  end

  # Review round 1, Important 4: a fixed luminance threshold (0.179) was
  # derived from literal black (luminance 0) vs white, but the actual dark
  # candidate is #111827 (luminance ≈0.00919), whose true equal-contrast
  # crossover against white is ≈0.1993. #767676's luminance (≈0.1811) sits
  # inside that gap: the old threshold picked #111827 for 3.906:1 (fails
  # WCAG AA, needs 4.5:1), when white gives 4.542:1 (passes). Computing both
  # candidates' actual contrast ratios and taking the higher one is correct
  # for any pair of on-primary candidates, not just this one — no threshold
  # constant to keep in sync with them.
  test "picks the genuinely higher-contrast option in the gap a fixed threshold gets wrong" do
    hotel = hotels(:stari_grad)
    hotel.primary_color = "#767676"

    assert_includes hotel_brand_style(hotel), "--brand-on-primary:#FFFFFF"
  end
end
