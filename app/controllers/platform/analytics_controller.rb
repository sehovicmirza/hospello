module Platform
  # Every hotel, one row each — the page for whoever runs Hospello.
  #
  # It reads the **same** Analytics::HotelReport a hotel reads about itself, so
  # the two can never show different numbers for the same thing. That is the
  # entire reason the report is an object rather than queries in a controller.
  #
  # Unlike the staff page, this one shows **tokens**: here they really are the
  # cost driver. A hotel pays Hospello a subscription and cannot act on a token
  # count; Hospello pays Anthropic per token and can act on very little else.
  #
  # Each report is built inside `ActsAsTenant.with_tenant(hotel)` rather than
  # relying on this namespace's deliberate lack of an ambient tenant: every
  # query inside the report is tenant-scoped, and a report built with no tenant
  # at all would raise under `require_tenant = true` — which is the fail-closed
  # behaviour working, not something to route around.
  class AnalyticsController < BaseController
    def show
      @from = date_param(:from)
      @to = date_param(:to)

      @reports = Hotel.order(:name).map do |hotel|
        ActsAsTenant.with_tenant(hotel) { Analytics::HotelReport.new(hotel: hotel, from: @from, to: @to) }
      end
    end

    private
      # Same reasoning as the staff page: this is a URL people hand-edit and
      # bookmark, so `?from=banana` gets the default month rather than a 500.
      def date_param(name)
        Date.parse(params[name].to_s)
      rescue ArgumentError, TypeError
        nil
      end
  end
end
