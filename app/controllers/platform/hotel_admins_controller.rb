module Platform
  # Creates a hotel's administrator during assisted onboarding: the platform
  # admin types the credentials here and hands them over on the call, since
  # this slice sends no email. Only #new/#create exist — there is no listing
  # or editing of admins from the platform side; once a hotel has an admin,
  # that admin manages its staff roster itself (Task 5).
  class HotelAdminsController < BaseController
    before_action :set_hotel

    def new
      @user = @hotel.users.new
    end

    def create
      @user = @hotel.users.new(user_params)
      @user.role = :hotel_admin

      if @user.save
        audit!("hotel_admin.create", target: @user, hotel: @hotel)
        redirect_to platform_hotel_path(@hotel),
          notice: "#{@user.name} created as the admin for #{@hotel.name}. Hospello sends no email — " \
                   "share these credentials with them directly."
      else
        render :new, status: :unprocessable_content
      end
    end

    private
      def set_hotel
        @hotel = Hotel.find(params[:hotel_id])
      end

      # role is deliberately absent here: it is always hotel_admin, set
      # explicitly above rather than trusted from the form.
      def user_params
        params.require(:user).permit(:name, :email_address, :password, :password_confirmation)
      end
  end
end
