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
        format.svg { send_data @qr_code.svg(size: DOWNLOAD_SIZE), type: "image/svg+xml", filename: download_filename("svg"), disposition: "attachment" }
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
      # Production reads the deployment's real public host from ENV;
      # anywhere else falls back to the request's own host, so a QR
      # generated against a local server or a review app still points
      # somewhere reachable instead of at a placeholder.
      def app_host
        Rails.env.production? ? ENV.fetch("APP_HOST") : request.host_with_port
      end

      def download_filename(extension)
        "hospello-qr-#{Current.hotel.slug}.#{extension}"
      end
  end
end
