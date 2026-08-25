module Staff
  class BaseController < ApplicationController
    include StaffLocalization
    include PlanGated

    layout "staff"

    before_action :require_staff_user
    around_action :scope_to_current_hotel
    # Declared after scope_to_current_hotel: locale is a property of the
    # signed-in user, not of the tenant, so it does not need the hotel
    # scoped first — but ordering it here keeps both around_actions reading
    # top-to-bottom as "who, then what language they read it in".
    around_action :scope_to_staff_locale

    private
      def require_staff_user
        return head :forbidden if Current.user.nil? || Current.user.platform_admin?
        head :forbidden unless Current.user.active? && Current.user.hotel&.active?
      end

      def scope_to_current_hotel(&block)
        Current.hotel = Current.user.hotel
        ActsAsTenant.with_tenant(Current.user.hotel, &block)
      end

      def scope_to_staff_locale(&block)
        I18n.with_locale(staff_locale_for(Current.user.locale), &block)
      end
  end
end
