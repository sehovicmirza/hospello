require "test_helper"

class HotelQrCodeTest < ActiveSupport::TestCase
  test "encodes the hotel's public landing URL" do
    qr = HotelQrCode.new(hotels(:stari_grad), host: "hospello.example")
    assert_equal "https://hospello.example/h/stari-grad", qr.url
  end

  test "the same hotel always produces the same URL — one reusable code per hotel" do
    a = HotelQrCode.new(hotels(:stari_grad), host: "hospello.example").url
    b = HotelQrCode.new(hotels(:stari_grad), host: "hospello.example").url
    assert_equal a, b
  end

  test "different hotels produce different URLs" do
    refute_equal HotelQrCode.new(hotels(:stari_grad), host: "h.example").url,
                 HotelQrCode.new(hotels(:vrelo), host: "h.example").url
  end

  test "renders an SVG containing the QR modules" do
    svg = HotelQrCode.new(hotels(:stari_grad), host: "h.example").svg(size: 300)
    assert_includes svg, "<svg"
  end

  # Interface note in the task brief: "#png(size:) → PNG binary string" — a
  # symmetric assertion to the SVG test above, checked against the real PNG
  # file signature (not just "some bytes came back") so a future change that
  # accidentally returned the SVG string, an empty string, or a ChunkyPNG
  # object instead of its binary encoding would fail here.
  test "renders a PNG with a valid PNG file signature" do
    png = HotelQrCode.new(hotels(:stari_grad), host: "h.example").png(size: 300)
    assert_equal "\x89PNG\r\n\x1a\n".b, png.byteslice(0, 8)
  end
end
