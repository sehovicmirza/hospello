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

  def url
    "https://#{@host}/h/#{@hotel.slug}"
  end

  # `size:` is the target overall pixel dimension (a square). rqrcode's SVG
  # renderer only accepts a per-module pixel size, not a total, so this
  # divides it out the same way `#as_png`'s built-in "Google" sizing does
  # (module_count + 2 * border modules), which is what keeps the SVG and PNG
  # visually matched at the same requested size.
  def svg(size: 320)
    module_size = pixels_per_module(size)

    qr_code.as_svg(
      module_size: module_size,
      offset: module_size * BORDER_MODULES,
      color: "000",
      fill: "fff",
      standalone: true,
      use_path: true
    )
  end

  def png(size: 320)
    qr_code.as_png(size: size, border_modules: BORDER_MODULES).to_s
  end

  private
    def qr_code
      @qr_code ||= RQRCode::QRCode.new(url)
    end

    def pixels_per_module(size)
      [ (size.to_f / (qr_code.modules.length + 2 * BORDER_MODULES)).floor, 1 ].max
    end
end
