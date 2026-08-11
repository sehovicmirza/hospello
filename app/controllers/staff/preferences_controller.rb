module Staff
  # A staff member's own language for this workspace (User#locale) — never
  # anyone else's. No Pundit policy: unlike Staff::UsersController (which
  # decides who may change *another* account, hotel_admin only), there is no
  # "which record" question here to authorize — every active staff member
  # Staff::BaseController already let through may set their own language,
  # full stop, the same way Staff::DashboardController needs no policy for
  # "may I see my own dashboard". The route itself carries no id (see
  # config/routes.rb), so there is no request shape that could even name a
  # colleague's account, not even a crafted one — the guarantee is
  # structural, not just a check that could be forgotten on a future action.
  class PreferencesController < BaseController
    def edit
    end

    def update
      if Current.user.update(preferences_params)
        # Built under the *new* locale, not the one this request started
        # under: a user who just switched from Bosnian to English must not
        # see one leftover Bosnian sentence on the otherwise-English page
        # the redirect lands them on.
        notice = I18n.with_locale(Current.user.locale) { t(".updated") }
        redirect_to edit_staff_preferences_path, notice: notice
      else
        render :edit, status: :unprocessable_content
      end
    end

    private
      def preferences_params
        params.require(:user).permit(:locale)
      end
  end
end
