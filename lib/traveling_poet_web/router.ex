defmodule TravelingPoetWeb.Router do
  use TravelingPoetWeb, :router

  import TravelingPoetWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TravelingPoetWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  # Agent-facing API: sprite -> app, bearer-token auth, no session/CSRF.
  pipeline :agent_api do
    plug :accepts, ["json"]
    plug TravelingPoetWeb.Plugs.AgentAuth
  end

  # Payment-provider webhooks: signature-verified over the raw body, no session/CSRF.
  pipeline :webhooks do
    plug :accepts, ["json"]
  end

  # Page-event beacon: no session, no CSRF (sendBeacon cannot carry the
  # token, and the endpoint only appends capped rows). The body is read raw.
  pipeline :beacon do
  end

  scope "/", TravelingPoetWeb do
    pipe_through :beacon

    post "/e", Api.BeaconController, :create
  end

  scope "/webhooks", TravelingPoetWeb do
    pipe_through :webhooks

    post "/stripe", StripeWebhookController, :handle
  end

  scope "/", TravelingPoetWeb do
    pipe_through :browser

    get "/", PageController, :home
    # The hero's destination box: remembers the place across Google sign-in
    get "/start", PageController, :start
    get "/privacy", PageController, :privacy
    get "/terms", PageController, :terms
    get "/media/:id", MediaController, :show
    # The book page, opened by the poet's sprite to print a PDF. No session:
    # a signed token for one rendering PDF, which also lets that page's
    # drawings load (see MediaController).
    get "/book/render/:token", BookController, :render_pdf
    # Files the agent produced in its sprite workspace (chat attachments etc.)
    get "/api/artifacts", Api.ArtifactController, :show

    live_session :public,
      on_mount: [{TravelingPoetWeb.UserAuth, :mount_current_user}] do
      live "/p/:slug", PublicJournalLive
      # Must precede /p/:slug/:date so "guide" isn't swallowed as a date.
      live "/p/:slug/guide", PublicGuideLive
      live "/p/:slug/:date", PublicJournalLive
    end
  end

  scope "/api/agent", TravelingPoetWeb.Api do
    pipe_through :agent_api

    get "/memory", AgentController, :memory
    get "/context", AgentController, :context
    get "/feedback", AgentController, :feedback
    post "/preferences", PreferenceController, :create
    post "/topics", TopicController, :propose
    post "/excursions", TopicController, :request
    post "/location", LocationController, :update
    post "/hold", RouteController, :hold
    post "/itinerary_stops", RouteController, :insert_stop
    post "/journal_entries", JournalApiController, :upsert_entry
    get "/journal_entries/:date", JournalApiController, :show
    put "/journal_entries/:date/sections", JournalApiController, :put_sections
    put "/journal_entries/:date/places", JournalApiController, :put_places
    put "/journal_entries/:date/finds", JournalApiController, :put_finds
    post "/journal_entries/:date/publish", JournalApiController, :publish
    post "/media", MediaApiController, :create
    post "/illustrations", MediaApiController, :generate
    # A composed book edition: readable and writable only while one is open
    get "/book_context", BookApiController, :context
    put "/book/matter", BookApiController, :put_matter
  end

  scope "/auth", TravelingPoetWeb do
    pipe_through :browser

    # /logout must precede /:provider so it isn't shadowed by the catch-all
    get "/logout", AuthController, :logout
    delete "/logout", AuthController, :logout
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  scope "/", TravelingPoetWeb do
    pipe_through [:browser, :require_authenticated_user]

    post "/credits/checkout", CreditsController, :checkout
    get "/credits/mock-checkout", CreditsController, :mock_checkout
    post "/credits/mock-checkout/confirm", CreditsController, :mock_confirm

    # The whole journal laid out for paper. A plain page, not a LiveView:
    # paged.js rewrites the DOM into pages and LiveView would patch it back.
    # Declared ahead of /journal/:date so "book" is never read as a date.
    get "/journal/book", BookController, :show
    get "/journal/book/pdf/:id", BookController, :download_pdf
    get "/journal/book/drive/connect", BookController, :connect_drive
    get "/settings/calendar/connect", CalendarController, :connect

    live_session :authenticated,
      on_mount: [{TravelingPoetWeb.UserAuth, :ensure_authenticated}] do
      live "/onboarding", OnboardingLive
      live "/journal", JournalLive
      live "/journal/:date", JournalLive
      live "/guide", GuideLive
      live "/settings", SettingsLive
    end

    live_session :admin,
      on_mount: [{TravelingPoetWeb.UserAuth, :ensure_admin}] do
      live "/admin", AdminLive
      live "/admin/change-stream", ChangeStreamAdminLive
      live "/admin/funnel", FunnelAdminLive
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:traveling_poet, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev", TravelingPoetWeb do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TravelingPoetWeb.Telemetry
      get "/login/:user_id", DevSessionController, :login
    end
  end
end
