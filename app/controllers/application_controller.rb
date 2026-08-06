class ApplicationController < ActionController::Base
  include Authentication
  include Pundit::Authorization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  rescue_from Pundit::NotAuthorizedError, with: :not_authorized
  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  private
    # Pundit looks for `current_user` by default; authentication keeps the signed-in
    # user on Current.
    def pundit_user
      Current.user
    end

    def not_authorized
      render plain: "Not authorized", status: :forbidden
    end

    def not_found
      render plain: "Not found", status: :not_found
    end
end
