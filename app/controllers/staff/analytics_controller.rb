module Staff
  # What this hotel can see about its own use of the product.
  #
  # A singular, id-less resource like hotel_settings and whatsapp_channel:
  # always Current.hotel's, never one a URL could name. The date range is the
  # only thing a request may say, and Analytics::HotelReport clamps whatever
  # it is handed — a range ending in the future, a start after its end, or one
  # wider than a year all resolve to something sensible rather than raising.
  class AnalyticsController < BaseController
    def show
      authorize Current.hotel, :analytics?, policy_class: HotelAnalyticsPolicy

      @report = Analytics::HotelReport.new(hotel: Current.hotel, from: date_param(:from), to: date_param(:to))
    end

    private
      # A malformed date is treated as "not given" rather than as an error:
      # this is a page someone lands on from a bookmark or a hand-edited URL,
      # and the useful response to `?from=banana` is the default month, not a
      # 500. The report itself decides what the default is.
      def date_param(name)
        Date.parse(params[name].to_s)
      rescue ArgumentError, TypeError
        nil
      end
  end
end
