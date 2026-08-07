module Staff
  class DashboardController < BaseController
    def show
      @hotel = Current.hotel
    end
  end
end
