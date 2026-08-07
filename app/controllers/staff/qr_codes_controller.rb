module Staff
  # The hotel's single, reusable QR code. Like Staff::HotelSettingsController,
  # there is no id anywhere in this namespace's routes — every action always
  # means Current.hotel, so there is no request shape that could target a
  # different hotel. Unlike most other staff screens, a plain `staff` user
  # (not just hotel_admin) may reach every action here — see QrCodePolicy.
  class QrCodesController < BaseController
    # The pixel size requested for a downloaded SVG/PNG — large enough to
    # print clearly on a room card and stay scannable from arm's length.
    # The on-screen preview renders smaller (see show.html.erb).
    DOWNLOAD_SIZE = 480

    def show
      authorize Current.hotel, policy_class: QrCodePolicy
      @hotel = Current.hotel
      @qr_code = qr_code

      respond_to do |format|
        format.html
        # standalone: true (the default, spelled out here for contrast with
        # the inline `standalone: false` renders in the .html.erb views) —
        # a downloaded .svg has to be a valid, freestanding file.
        format.svg { send_data @qr_code.svg(size: DOWNLOAD_SIZE, standalone: true), type: "image/svg+xml", filename: download_filename("svg"), disposition: "attachment" }
        format.png { send_data @qr_code.png(size: DOWNLOAD_SIZE), type: "image/png", filename: download_filename("png"), disposition: "attachment" }
      end
    end

    def print
      authorize Current.hotel, policy_class: QrCodePolicy
      @hotel = Current.hotel
      @qr_code = qr_code
    end

    private
      # Called exactly once per action (there's no reason to memoize) — see
      # #show and #print above.
      def qr_code
        HotelQrCode.new(Current.hotel, host: app_host)
      end

      # No hardcoded hostname (see render.yaml's APP_HOST comment: "Printed
      # QR codes encode this host, so changing it later means reprinting").
      # Production reads the resolved, normalized host set once at boot
      # (config.x.app_host — see AppHost and config/environments/
      # production.rb); anywhere else falls back to the request's own host,
      # so the HOST a QR generated locally encodes is real rather than a
      # placeholder. This does not make the full printed URL clickable in
      # development, though — HotelQrCode#url always uses "https://"
      # (matching what gets encoded and printed), which a plain-HTTP local
      # server can't answer. show.html.erb's "Test it yourself" link
      # handles that separately, on purpose, rather than this method
      # changing scheme by environment.
      def app_host
        Rails.env.production? ? Rails.application.config.x.app_host : request.host_with_port
      end

      def download_filename(extension)
        "hospello-qr-#{Current.hotel.slug}.#{extension}"
      end
  end
end
