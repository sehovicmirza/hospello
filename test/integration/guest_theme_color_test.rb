require "test_helper"

# The browser paints its own chrome from <meta name="theme-color">, and on a
# QR-scanned page that bar is the one part of the screen the hotel cannot
# remove. Colouring it in the hotel's own primary is the difference between the
# chat looking like a web page inside a browser and looking like the top of the
# hotel's app.
class GuestThemeColorTest < ActionDispatch::IntegrationTest
  setup do
    @hotel = hotels(:stari_grad)
  end

  test "the guest surface tints the browser chrome with the hotel's own colour" do
    @hotel.update!(primary_color: "#0B6E4F")

    get "/h/#{@hotel.slug}"

    assert_response :success
    assert_select "meta[name=theme-color][content=?]", "#0B6E4F"
  end

  # Two hotels, two bars. This is the same tenant promise the rest of the guest
  # surface makes, applied to the one pixel row the hotel does not control.
  test "a different hotel gets a different colour" do
    hotels(:vrelo).update!(primary_color: "#7A1F3D")

    get "/h/#{hotels(:vrelo).slug}"

    assert_select "meta[name=theme-color][content=?]", "#7A1F3D"
  end

  # A hotel that never set one, or set something unusable, still gets a
  # sensible bar rather than an empty attribute the browser ignores.
  test "a hotel with no usable colour falls back to the default" do
    @hotel.update_columns(primary_color: "")

    get "/h/#{@hotel.slug}"

    assert_select "meta[name=theme-color][content=?]", BrandingHelper::DEFAULT_PRIMARY_COLOR
  end
end
