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
          notice: t(".added", name: @user.name, role: I18n.t("staff.common.roles.#{@user.role}"))
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
    end

    # Editing here only ever flips `active` or `locale` — no name, email,
    # password or role field exists on this form (see the edit view), and
    # each of those two is its own separate form rather than one shared
    # submit: a receptionist's language and their access are two different
    # decisions, and conflating them into one form risks a stray "active"
    # value riding along with a language change or the reverse (the same
    # "two forms, not one with a toggle" reasoning
    # staff/conversations/_composer.html.erb documents). A hotel_admin may
    # not deactivate their own account: that would be an admin locking
    # themselves out with no one else to undo it. Deactivating someone else
    # also destroys their live sessions — sessions are 20-year permanent
    # cookies with no expiry column, and User#can_sign_in? only gates *new*
    # logins, so deactivation alone would otherwise leave an already-open tab
    # signed in indefinitely.
    def update
      if self_deactivation?
        return redirect_to staff_users_path, alert: t(".self_deactivation_blocked")
      end

      was_active = @user.active?

      if @user.update(user_update_params)
        if was_active && !@user.active?
          @user.sessions.destroy_all
          AuditLog.record!(actor: Current.user, action: "user.deactivate", hotel: Current.hotel, target: @user)
        end
        redirect_to staff_users_path, notice: t(".updated", name: @user.name)
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
      # different hotel_id is simply ignored. `locale` is a hotel_admin
      # setting a colleague's initial workspace language on their behalf —
      # the same column, and the same Hotel::STAFF_LOCALES validation, that
      # Staff::PreferencesController lets a user set for themselves.
      def user_params
        params.require(:user).permit(:name, :email_address, :password, :password_confirmation, :locale)
      end

      def user_update_params
        params.require(:user).permit(:active, :locale)
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
