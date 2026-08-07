module Staff
  # A hotel_admin's whole job here: create an account, deactivate someone who
  # left, and nothing more. Onboarding is assisted — the admin types a
  # password on this screen and hands it over on the call; there is no
  # invitation email, no password reset, and no self-service signup anywhere
  # in this product. Everything is scoped through Current.hotel — never a
  # hotel id from params, per this namespace's convention.
  #
  # This is the only screen in the product that creates users, and the only
  # roles it may create are staff and hotel_admin: a platform_admin minted
  # here would be a cross-hotel account created by a hotel employee. The role
  # param is therefore never mass-assigned — #allowed_role whitelists it
  # explicitly, the same shape Platform::HotelAdminsController uses to force
  # its own role.
  class UsersController < BaseController
    ALLOWED_ROLES = %w[staff hotel_admin].freeze

    before_action :set_user, only: %i[edit update]

    def index
      authorize User
      @users = Current.hotel.users.order(:name)
    end

    def new
      authorize User
      @user = Current.hotel.users.new
    end

    def create
      @user = Current.hotel.users.new(user_params)
      @user.role = allowed_role
      authorize @user

      if @user.save
        AuditLog.record!(actor: Current.user, action: "user.create", hotel: Current.hotel, target: @user)
        redirect_to staff_users_path,
          notice: "#{@user.name} added as #{@user.role.humanize}. Hospello sends no email — " \
                   "share these credentials with them directly."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
    end

    # Editing here only ever flips `active` — no name, email, password or
    # role field exists on this form (see the edit view). A hotel_admin may
    # not deactivate their own account: that would be an admin locking
    # themselves out with no one else to undo it. Deactivating someone else
    # also destroys their live sessions — sessions are 20-year permanent
    # cookies with no expiry column, and User#can_sign_in? only gates *new*
    # logins, so deactivation alone would otherwise leave an already-open tab
    # signed in indefinitely.
    def update
      if self_deactivation?
        return redirect_to staff_users_path, alert: "You cannot deactivate your own account."
      end

      was_active = @user.active?

      if @user.update(user_update_params)
        if was_active && !@user.active?
          @user.sessions.destroy_all
          AuditLog.record!(actor: Current.user, action: "user.deactivate", hotel: Current.hotel, target: @user)
        end
        redirect_to staff_users_path, notice: "#{@user.name} updated."
      else
        render :edit, status: :unprocessable_content
      end
    end

    private
      def set_user
        @user = Current.hotel.users.find(params[:id])
        authorize @user
      end

      # role and hotel_id are deliberately absent here: role is whitelisted
      # explicitly below (#allowed_role), and hotel_id always comes from
      # Current.hotel.users.new, never from the form — a form posting a
      # different hotel_id is simply ignored.
      def user_params
        params.require(:user).permit(:name, :email_address, :password, :password_confirmation)
      end

      def user_update_params
        params.require(:user).permit(:active)
      end

      def allowed_role
        role = params.dig(:user, :role)
        ALLOWED_ROLES.include?(role) ? role : "staff"
      end

      def self_deactivation?
        @user == Current.user && ActiveModel::Type::Boolean.new.cast(params.dig(:user, :active)) == false
      end
  end
end
