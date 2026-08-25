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
      # escalation_email and overdue_after_minutes are only permitted for a
      # hotel whose plan actually has requests. They are also hidden from the
      # form in that case, but hiding a field is a UI decision and this is the
      # gate — a hand-rolled POST must not be able to set them either.
      def hotel_params
        permitted = [
          :name, :timezone, :staff_locale,
          :primary_color, :secondary_color,
          :concierge_name, :welcome_message,
          :contact_phone, :contact_notes, :checkout_time,
          :logo, :welcome_image
        ]
        permitted += [ :escalation_email, :overdue_after_minutes ] if Current.hotel.plan_allows?(:requests)

        params.require(:hotel).permit(*permitted)
      end
  end
end
