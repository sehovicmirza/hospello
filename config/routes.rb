Rails.application.routes.draw do
  resource :session, only: %i[ new create destroy ]

  # The one public entry point per hotel — the printed QR code
  # (HotelQrCode#path) encodes exactly this path, so its shape can never
  # drift from what's already printed on a room card without every existing
  # code becoming dead paper (see test/services/hotel_qr_code_test.rb and
  # test/controllers/guest/entries_controller_test.rb, which pin the
  # coupling by routing HotelQrCode's own #path rather than a re-typed
  # literal). Guest::EntriesController is the only guest controller that
  # ever takes a hotel from the URL — see that controller and
  # Guest::BaseController for why every other guest route resolves the
  # hotel from the guest's cookie instead.
  get "/h/:hotel_slug", to: "guest/entries#show", as: :hotel_landing
  post "/h/:hotel_slug", to: "guest/entries#create"

  namespace :guest do
    # Guest::BaseController (every controller in this namespace) resolves
    # Current.hotel from the guest's cookie, never a URL parameter.
    resource :chat, only: %i[show], controller: "chats"

    # POST creates a message — the guest_messages/ip Rack::Attack throttle
    # (config/initializers/rack_attack.rb, matching any POST under
    # "/guest/") is really guarding this route. GET (index) is the
    # resilience layer's resync endpoint ("?after=<id>",
    # app/javascript/controllers/chat_resilience_controller.js): the
    # database is the source of truth and the live broadcast is only an
    # enhancement, so this same action has to be able to answer "what did
    # I miss" entirely on its own.
    resources :messages, only: %i[create index]
  end

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
