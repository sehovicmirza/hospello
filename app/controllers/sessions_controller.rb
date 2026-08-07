class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_url, alert: "Try again later." }

  def new
    # Visiting the sign-in page (or the application root, which renders it)
    # while already signed in used to show the page's empty shell. Send them
    # to their own namespace instead.
    redirect_to home_url_for(Current.user) if authenticated?
  end

  def create
    user = User.authenticate_by(params.permit(:email_address, :password))

    if user.nil?
      redirect_to new_session_path, alert: "Try another email address or password."
    elsif !user.can_sign_in?
      redirect_to new_session_path, alert: "This account is not active. Contact your hotel administrator."
    else
      start_new_session_for user
      redirect_to after_authentication_url
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path
  end
end
