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

  # Review round 1, minor: the previous module_size-times-module_count
  # approximation floored and drifted off the requested size (480 requested
  # rendered at 451px) with no viewBox to compensate. Pinning the exact
  # width/height attributes — not just "some svg came back" — is what would
  # have caught that.
  test "the SVG renders at exactly the requested pixel size and carries a viewBox" do
    svg = HotelQrCode.new(hotels(:stari_grad), host: "h.example").svg(size: 480)
    assert_includes svg, %(width="480")
    assert_includes svg, %(height="480")
    assert_includes svg, "viewBox="
  end

  # standalone: false is what the embedded (inline, on-screen/print) render
  # needs — an XML prolog is invalid partway through an HTML document, even
  # though browsers silently tolerate it. The default (true) is for the
  # freestanding .svg download. Either way the actual <svg>...</svg>
  # element must survive — rqrcode's own `standalone` option drops the
  # wrapper element entirely, not just the prolog, so this is pinned
  # explicitly rather than assumed.
  test "standalone: false omits only the XML prolog, keeping the <svg> element itself" do
    embedded = HotelQrCode.new(hotels(:stari_grad), host: "h.example").svg(size: 300, standalone: false)
    downloadable = HotelQrCode.new(hotels(:stari_grad), host: "h.example").svg(size: 300, standalone: true)

    assert_includes downloadable, "<?xml"
    refute_includes embedded, "<?xml"
    assert_match %r{\A<svg[ >]}, embedded
    assert_includes embedded, "</svg>"
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

  # Review round 1, CRITICAL 1: every test above the rendered image only
  # checked its wrapper ("looks like an SVG", "looks like a PNG") — none of
  # them tied the actual pixels/paths back to #url. A reviewer swapped
  # #qr_code's payload for a fixed, wrong URL and every test in this file
  # still passed. This is the artefact that gets printed and mounted in a
  # room, so what the image *encodes* has to be pinned, not just its
  # container format. rqrcode has no decoder, so this can't assert against
  # a literally-decoded payload without a new gem — instead it asserts the
  # one thing that must be true if (and only if) the image is a function of
  # #url: two different hotels' images differ, and the same hotel's image is
  # reproduced byte-for-byte (the "one reusable code" guarantee, extended
  # from the URL string to the image itself).
  test "the rendered SVG differs between hotels and is identical for the same hotel" do
    stari = HotelQrCode.new(hotels(:stari_grad), host: "h.example").svg(size: 300)
    vrelo = HotelQrCode.new(hotels(:vrelo), host: "h.example").svg(size: 300)
    stari_again = HotelQrCode.new(hotels(:stari_grad), host: "h.example").svg(size: 300)

    refute_equal stari, vrelo
    assert_equal stari, stari_again
  end

  test "the rendered PNG differs between hotels and is identical for the same hotel" do
    stari = HotelQrCode.new(hotels(:stari_grad), host: "h.example").png(size: 300)
    vrelo = HotelQrCode.new(hotels(:vrelo), host: "h.example").png(size: 300)
    stari_again = HotelQrCode.new(hotels(:stari_grad), host: "h.example").png(size: 300)

    refute_equal stari, vrelo
    assert_equal stari, stari_again
  end

  # Slice 2 pins the other half of the "/h/<slug>" coupling this file's
  # header describes: #path is the literal string physically printed on
  # every hotel's QR card, and until this test existed nothing proved the
  # router actually has a route behind it. Derived from #path itself, not a
  # re-typed "/h/..." literal — if this route is ever renamed, every
  # already-printed QR code in every hotel room becomes dead paper (a
  # reprint is the only fix), so a drift here must fail loudly, not
  # silently 404 in production.
  test "the router recognizes HotelQrCode's own #path and routes it to the guest entry point" do
    hotel = hotels(:stari_grad)
    path = HotelQrCode.new(hotel, host: "h.example").path

    route = Rails.application.routes.recognize_path(path, method: :get)

    assert_equal "guest/entries", route[:controller]
    assert_equal "show", route[:action]
    assert_equal hotel.slug, route[:hotel_slug]
  end
end
