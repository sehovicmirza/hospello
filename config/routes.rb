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

  # Slice 6's front door for every hotel's WhatsApp channel at once — the
  # only unauthenticated, publicly reachable endpoint in this app that
  # accepts a body (see app/controllers/webhooks/whatsapp_controller.rb for
  # the full reasoning, including why it deliberately does not inherit
  # ApplicationController). Top-level, not nested under guest/staff/platform,
  # because it belongs to none of them: there is no guest cookie, no staff
  # session, and no hotel in the URL — the payload's own
  # metadata.phone_number_id is what eventually decides which hotel a
  # delivery belongs to (Slice 6 Task 3). GET is Meta's one-time webhook
  # subscription handshake; POST is a real delivery.
  namespace :webhooks do
    get "whatsapp", to: "whatsapp#verify"
    post "whatsapp", to: "whatsapp#receive"
  end

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

    # The summary card's two buttons. A singular resource with no id in the
    # path, like everything else in this namespace: the draft is always "the
    # live one belonging to this cookie's conversation", never one a form
    # could name. Both buttons converge on the same
    # ServiceRequestDraft#confirm! a typed "yes" reaches through the model,
    # which is what makes it impossible for the two paths to produce two
    # requests.
    resource :service_request_draft, only: [] do
      post :confirm
      post :discard
    end
  end

  # Staff-facing hotel workspace. Every controller here inherits
  # Staff::BaseController, which sets the tenant from Current.user.hotel —
  # nothing in this namespace takes a hotel id from the URL.
  namespace :staff do
    root "dashboard#show"
    resource :hotel_settings, only: %i[edit update]

    # A staff member's own workspace language (User#locale) — a singular
    # resource with no id, the same shape hotel_settings above and
    # guest/service_request_draft use for "always the current X, never one
    # a form could name": #edit/#update always act on Current.user, so
    # there is no request shape that could target a colleague's account.
    resource :preferences, only: %i[edit update]

    # The reception inbox. Like everything else in this namespace it takes
    # no hotel from the URL — Staff::BaseController sets the tenant from
    # Current.user.hotel, and #show/#update look the conversation up
    # through Current.hotel.conversations, so another hotel's id 404s
    # (test/tenancy/cross_tenant_access_test.rb).
    #
    # Nested messages (Staff::MessagesController — a nested `resources`
    # adds no module, so this is NOT Staff::Conversations::MessagesController)
    # rather than a top-level collection: unlike the guest side, where the
    # conversation is always "the one this cookie owns", a receptionist
    # works many conversations at once and has to say which one they are
    # replying to.
    resources :conversations, only: %i[index show] do
      resources :messages, only: %i[create]

      member do
        patch :ai_mode
        patch :resolve
      end
    end

    resources :rooms, only: %i[index create edit update destroy] do
      collection { post :bulk_create }
    end

    # The hotel's own knowledge base — what the Slice 3 concierge answers
    # from, and nothing else. #publish is its own member route rather than
    # a field on #update because it is the action that puts text in front
    # of guests, and it carries its own policy question and audit entry.
    resources :kb_entries, only: %i[index new create edit update destroy] do
      member { patch :publish }
    end

    # The reception board. No create — the only path that makes a request is
    # a guest confirming a draft — and no destroy: a request is cancelled,
    # which keeps its history, never deleted. One transition route rather
    # than accept/start/complete/decline actions, because the legal moves
    # already live in ServiceRequest::TRANSITIONS and four near-identical
    # actions would be four places to forget an authorize call.
    resources :service_requests, only: %i[index show] do
      member { patch :transition }
      # Staff commentary on a request, never guest-visible — see
      # Staff::RequestEventsController.
      resources :request_events, only: %i[create]
    end

    # What guests asked that this hotel never wrote down. No create — rows
    # are written by the concierge's own log_unanswered_question tool, never
    # by hand — and no destroy: dismissing is a decision worth keeping, and
    # the row goes on counting repeats so a dismissal that turns out to be
    # wrong is visible rather than silently re-created.
    resources :unanswered_questions, only: %i[index] do
      member { patch :dismiss }
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
