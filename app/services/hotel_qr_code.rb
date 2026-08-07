# The hotel's single, reusable QR code. Exactly one per hotel — never one per
# room — because a hotel prints the same card for every room and common
# area (per-room codes are explicitly out of scope; see the Task 6 brief).
# #url is built from the hotel's slug alone, so the same hotel always
# produces the same URL, and it must match exactly the route Slice 2's guest
# landing page answers on: https://<host>/h/<slug>.
#
# `host:` is always supplied by the caller, never derived here — see
# Staff::QrCodesController#app_host for the production-vs-development split
# (ENV["APP_HOST"] vs the request host). Keeping that decision out of this
# class is what makes the "same hotel -> same URL" guarantee below testable
# without a request in play at all.
class HotelQrCode
  # Quiet zone width, in QR "modules", around the code — the white margin a
  # scanner needs to lock onto. Applied identically to both renderers so a
  # PNG and an SVG requested at the same `size:` look the same.
  BORDER_MODULES = 4

  def initialize(hotel, host:)
    @hotel = hotel
    @host = host
  end

  # The route path alone (no scheme/host) — the one place "/h/<slug>" is
  # written; #url below reuses it rather than duplicating the shape.
  def path
    "/h/#{@hotel.slug}"
  end

  def url
    "https://#{@host}#{path}"
  end

  # `size:` is the exact overall pixel dimension the returned SVG renders
  # at (a square) — module_size is fixed at 1 "user unit" per module and a
  # `viewBox` maps that unit grid onto explicit `width`/`height` attributes
  # set to `size`, so unlike a module_size-times-module_count approximation
  # (which floors and drifts off the requested size as module_count grows)
  # this is exact for every requested size, and the emitted `viewBox` means
  # the image also scales cleanly if a caller resizes it with CSS.
  #
  # `standalone:` controls whether the leading `<?xml version="1.0" ...?>`
  # prolog is included ahead of the `<svg>` element. The `.svg` download
  # needs it (`true`, the default) — it has to be a valid, freestanding SVG
  # file. A view embedding this inline in an HTML page needs it stripped
  # (`standalone: false`): an XML prolog partway through an HTML document is
  # invalid markup, even though browsers tolerate it silently. Either way
  # the `<svg>...</svg>` element itself is always present — rqrcode's own
  # `standalone` option controls both the prolog *and* the `<svg>` wrapper
  # together (`false` drops both, leaving bare `<rect>`/`<path>` elements
  # with no enclosing `<svg>` at all, which is for embedding inside a
  # caller-supplied `<svg>` and would render as nothing here) — so this
  # always asks rqrcode for the full document and strips only the prolog
  # itself when the embeddable form is requested.
  def svg(size: 320, standalone: true)
    full_document = qr_code.as_svg(
      module_size: 1,
      offset: BORDER_MODULES,
      color: "000",
      fill: "fff",
      standalone: true,
      use_path: true,
      viewbox: true,
      svg_attributes: { width: size, height: size }
    )

    standalone ? full_document : full_document.sub(/\A<\?xml[^>]*\?>/, "")
  end

  def png(size: 320)
    qr_code.as_png(size: size, border_modules: BORDER_MODULES).to_s
  end

  private
    def qr_code
      @qr_code ||= RQRCode::QRCode.new(url)
    end
end
