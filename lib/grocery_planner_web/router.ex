defmodule GroceryPlannerWeb.Router do
  use GroceryPlannerWeb, :router

  import Oban.Web.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {GroceryPlannerWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(GroceryPlannerWeb.Auth, :fetch_current_user)
  end

  pipeline :require_authenticated_user do
    plug(GroceryPlannerWeb.Auth, :require_authenticated_user)
  end

  # Operator-only: the Oban dashboard shows job args across all tenants, so it is
  # gated to an admin-email allowlist on top of authentication (see RequireAdmin).
  pipeline :require_admin do
    plug(GroceryPlannerWeb.Plugs.RequireAdmin)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", GroceryPlannerWeb do
    pipe_through(:api)

    # /ready is the DB-aware routing/healthcheck gate (200 iff DB reachable);
    # /health_check is the richer monitoring endpoint (503 when the optional
    # AI sidecar is degraded). Keep both unauthenticated and before any auth
    # scope so probes need no bearer token.
    get("/ready", HealthController, :ready)
    get("/health_check", HealthController, :check)
  end

  scope "/", GroceryPlannerWeb do
    pipe_through(:browser)

    get("/", PageController, :home)

    live("/sign-up", Auth.SignUpLive)
    live("/sign-in", Auth.SignInLive)
    live("/forgot-password", Auth.ForgotPasswordLive)
    live("/reset-password/:token", Auth.ResetPasswordLive)
    post("/auth/sign-in", AuthController, :sign_in)
    delete("/auth/sign-out", AuthController, :sign_out)
  end

  scope "/", GroceryPlannerWeb do
    pipe_through([:browser, :require_authenticated_user])

    live("/dashboard", DashboardLive)
    live("/settings", SettingsLive)
    live("/inventory", InventoryLive)
    live("/recipes", RecipesLive)
    live("/recipes/search", RecipeSearchLive)
    live("/recipes/new", RecipeFormLive, :new)
    live("/recipes/:id/edit", RecipeFormLive, :edit)
    live("/recipes/:id", RecipeShowLive)
    live("/meal-planner", MealPlannerLive)
    live("/shopping", ShoppingLive)
    live("/voting", VotingLive)
    live("/analytics", AnalyticsLive)
    live("/family", FamilyLive)
    live("/receipts", ReceiptsLive)
    live("/receipts/scan", ReceiptLive, :index)
    live("/receipts/:id", ReceiptsLive)
  end

  # Oban Web dashboard — discarded/cancelled job visibility (AI-006 §7).
  # Behind auth + admin allowlist; cross-tenant, so never plain-authenticated.
  scope "/admin" do
    pipe_through([:browser, :require_authenticated_user, :require_admin])

    oban_dashboard("/oban")
  end

  # Other scopes may use custom stacks.
  pipeline :api_auth do
    plug(GroceryPlannerWeb.Plugs.ApiAuth)
  end

  # Swagger UI for interactive API documentation (outside module scope)
  scope "/api" do
    pipe_through(:api)

    get("/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/json/open_api",
      default_model_expand_depth: 3,
      display_operation_id: true
    )
  end

  scope "/api", GroceryPlannerWeb do
    pipe_through(:api)

    post("/sign-in", Api.AuthController, :sign_in)

    scope "/" do
      pipe_through(:api_auth)

      post("/sync/batch", Api.SyncController, :batch)
      get("/sync/pull", Api.SyncController, :pull)
      get("/sync/status", Api.SyncController, :status)

      forward("/json", JsonApiRouter)
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:grocery_planner, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: GroceryPlannerWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
