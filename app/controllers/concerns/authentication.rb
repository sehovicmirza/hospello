module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      Session.find_by(token: cookies.signed[:session_token]) if cookies.signed[:session_token]
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      # Not the bare `new_session_path` helper: called as an instance method
      # it merges in whatever the *current* controller's own
      # default_url_options happens to return, and Mission Control – Jobs'
      # ApplicationController (mounted at /platform/jobs, gated by this same
      # concern via Platform::BaseController) unconditionally returns
      # { server_id: ... } from that method for its own routes. Since
      # default_url_options merging isn't scoped by which route it's being
      # applied to, an unauthenticated hit on the jobs dashboard picked up a
      # stray server_id param that /session/new doesn't accept and 500'd
      # instead of redirecting to sign-in. Calling the routes module's own
      # helper bypasses any controller instance's default_url_options
      # entirely — identical output for every other controller, immune to
      # this one's.
      redirect_to Rails.application.routes.url_helpers.new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || home_url_for(Current.user)
    end

    # Where a signed-in user's work actually starts. Without this everyone
    # landed on the application root, which renders the sign-in page's shell —
    # a header saying "Signed in as …" above an empty page with no links at
    # all. Signing in appeared to do nothing.
    #
    # Platform admins and hotel staff have no screens in common, so there is no
    # single home page to send them to; each namespace has its own root.
    def home_url_for(user)
      if user&.platform_admin?
        platform_hotels_url
      elsif user
        staff_root_url
      else
        new_session_url
      end
    end

    # DELIBERATELY DEFERRED, not fixed here: this cookie is permanent
    # (~20 years) and `sessions` has no expiry column, so a session lives
    # until someone signs out or a hotel_admin/platform_admin deactivates
    # the account (Staff::UsersController#update already destroys every
    # live session on deactivation — the sharpest edge, an admin actively
    # revoking access, is covered). The residual risk this leaves open is
    # narrower: a leaked cookie for an account nobody has deactivated stays
    # valid indefinitely. Every user of this cookie today is internal
    # (hotel staff, hotel admins, platform admins, all created by another
    # admin, never self-service) — Slice 2's guest chat has no persistent
    # session at all. Doing this properly is more than a one-line fix: a
    # migration for `sessions.expires_at` (or a sliding `last_active_at`),
    # a check in #find_session_by_cookie, and a recurring sweep job in the
    # Ops:: pattern this task already established to purge expired rows —
    # real scope for a dedicated task, not a rider on an already-large
    # security-hardening pass. Recommended next slice, not later than the
    # first pilot renewal.
    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed.permanent[:session_token] = { value: session.token, httponly: true, same_site: :lax }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_token)
    end
end
