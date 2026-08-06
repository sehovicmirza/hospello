Rails.application.routes.draw do
  resource :session, only: %i[ new create destroy ]

  # Staff-facing hotel workspace. Filled in by later tasks; every controller
  # here inherits Staff::BaseController, which sets the tenant.
  namespace :staff do
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

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "sessions#new"
end
