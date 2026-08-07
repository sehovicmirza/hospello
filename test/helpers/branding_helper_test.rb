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
end
