module Platform
  # The platform admin's onboarding cockpit: create a hotel, see at a glance
  # whether it is live and whether it has a first admin yet, and suspend or
  # reactivate it. Branding (colors, logo, welcome message) is the hotel
  # admin's own job from the staff side (Task 3) — this controller only sets
  # identity and the platform-level switches listed in `hotel_params`.
  class HotelsController < BaseController
    before_action :set_hotel, only: %i[show edit update suspend activate]

    def index
      authorize Hotel
      @hotels = Hotel.order(created_at: :desc)

      # One grouped query for every hotel's staff count and one for which
      # hotels already have a first admin, instead of N+1 queries per row.
      @staff_counts = User.where(hotel_id: @hotels.map(&:id)).group(:hotel_id).count
      @hotel_ids_with_admin = User.hotel_admin.where(hotel_id: @hotels.map(&:id)).distinct.pluck(:hotel_id).to_set
    end

    def new
      @hotel = Hotel.new
      authorize @hotel
    end

    def create
      @hotel = Hotel.new(hotel_params)
      authorize @hotel

      if @hotel.save
        audit!("hotel.create", target: @hotel, hotel: @hotel)
        redirect_to platform_hotel_path(@hotel), notice: "#{@hotel.name} created."
      else
        render :new, status: :unprocessable_content
      end
    end

    def show
      @admins = @hotel.users.hotel_admin.order(:name)
      @staff_count = @hotel.users.count
    end

    def edit
    end

    def update
      if @hotel.update(hotel_params)
        audit!("hotel.update", target: @hotel, hotel: @hotel)
        redirect_to platform_hotel_path(@hotel), notice: "#{@hotel.name} updated."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def suspend
      @hotel.suspended!
      audit!("hotel.suspend", target: @hotel, hotel: @hotel)
      redirect_to platform_hotel_path(@hotel), notice: "#{@hotel.name} suspended."
    end

    def activate
      @hotel.active!
      audit!("hotel.activate", target: @hotel, hotel: @hotel)
      redirect_to platform_hotel_path(@hotel), notice: "#{@hotel.name} reactivated."
    end

    private
      def set_hotel
        @hotel = Hotel.find(params[:id])
        authorize @hotel
      end

      # status is deliberately absent: it changes only through #suspend and
      # #activate, each writing its own named audit action, so "what changed
      # the hotel's live/suspended state" is never ambiguous in the log.
      def hotel_params
        params.require(:hotel).permit(
          :name, :slug, :timezone, :staff_locale,
          :powered_by_visible, :ai_enabled, :ai_daily_token_budget,
          :escalation_email
        )
      end
  end
end
