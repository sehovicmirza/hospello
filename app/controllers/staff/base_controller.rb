module Staff
  class BaseController < ApplicationController
    before_action :require_staff_user
    around_action :scope_to_current_hotel

    private
      def require_staff_user
        return head :forbidden if Current.user.nil? || Current.user.platform_admin?
        head :forbidden unless Current.user.active? && Current.user.hotel&.active?
      end

      def scope_to_current_hotel(&block)
        Current.hotel = Current.user.hotel
        ActsAsTenant.with_tenant(Current.user.hotel, &block)
      end
  end
end
