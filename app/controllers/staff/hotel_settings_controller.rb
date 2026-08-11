module Staff
  class HotelSettingsController < BaseController
    before_action :set_hotel

    def edit
    end

    def update
      if @hotel.update(hotel_params)
        redirect_to edit_staff_hotel_settings_path, notice: t(".updated")
      else
        render :edit, status: :unprocessable_content
      end
    end

    private
      # Always Current.hotel — never a hotel id from params. There is no id
      # in this namespace's routes at all, so there is no request shape that
      # could target a different hotel.
      def set_hotel
        @hotel = Current.hotel
        authorize @hotel
      end

      # slug, status, powered_by_visible, ai_enabled and ai_daily_token_budget
      # are platform-admin-only (see Platform::HotelsController#hotel_params)
      # and must never be settable from the hotel's own settings form — a
      # test asserts posting them here leaves them unchanged.
      def hotel_params
        params.require(:hotel).permit(
          :name, :timezone, :staff_locale,
          :primary_color, :secondary_color,
          :concierge_name, :welcome_message,
          :contact_phone, :contact_notes, :checkout_time,
          :escalation_email, :overdue_after_minutes,
          :logo, :welcome_image
        )
      end
  end
end
