Rails.application.routes.draw do
  resource :session, only: %i[ new create destroy ]

  # Staff-facing hotel workspace. Every controller here inherits
  # Staff::BaseController, which sets the tenant from Current.user.hotel —
  # nothing in this namespace takes a hotel id from the URL.
  namespace :staff do
    root "dashboard#show"
    resource :hotel_settings, only: %i[edit update]

    resources :rooms, only: %i[index create edit update destroy] do
      collection { post :bulk_create }
    end

    resources :departments, only: %i[index create edit update destroy]
    resources :request_categories, only: %i[index create edit update destroy]

    # No destroy: staff accounts are deactivated (update), never deleted —
    # see Staff::UsersController.
    resources :users, only: %i[index new create edit update]

    # One QR code per hotel, never one per room — see HotelQrCode. #show is
    # the on-screen page and also answers .svg/.png for downloads; #print is
    # the separate printable A5 sheet, linked to open in its own tab so
    # printing it doesn't navigate away from the on-screen page.
    resource :qr_code, only: %i[show] do
      get :print
    end
  end

  # Platform-admin back office. Filled in by later tasks; every controller here
  # inherits Platform::BaseController, which sets no ambient tenant.
  namespace :platform do
    resources :hotels, only: %i[index new create show edit update] do
      member do
        patch :suspend
        patch :activate
      end

      resources :hotel_admins, only: %i[new create]
    end
  end

  # Solid Queue's dashboard. Gated by Platform::BaseController, not the
  # gem's own HTTP Basic Auth — see config/initializers/mission_control_jobs.rb.
  mount MissionControl::Jobs::Engine, at: "/platform/jobs"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "sessions#new"
end
