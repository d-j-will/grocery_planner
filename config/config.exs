# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ex_cldr, default_backend: GroceryPlanner.Cldr

config :mime, :types, %{
  "application/vnd.api+json" => ["json"]
}

config :mime, :extensions, %{
  "json" => "application/json"
}

config :ash_json_api, :show_public_calculations_when_loaded?, true

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  known_types: [AshMoney.Types.Money],
  custom_types: [money: AshMoney.Types.Money]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :grocery_planner,
  ecto_repos: [GroceryPlanner.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    GroceryPlanner.Accounts,
    GroceryPlanner.Inventory,
    GroceryPlanner.Recipes,
    GroceryPlanner.External,
    GroceryPlanner.MealPlanning,
    GroceryPlanner.Shopping,
    GroceryPlanner.Notifications,
    GroceryPlanner.Analytics,
    GroceryPlanner.AI,
    GroceryPlanner.Family
  ]

config :grocery_planner, :receipt_upload_dir, "priv/static/uploads/receipts"

# Oban queues (AI-006 §1). Single node, so a per-queue `limit` IS a global cap
# (local_limit/global_limit are Pro-only). `ai_jobs` is capped at 2 to match the
# sidecar's `cpus: 2` — a higher limit just queues behind a CPU-bound sidecar.
# `matching` is our-side CPU-bound (full-catalog scans), so it gets its own limit.
# Lifeline rescues jobs stuck `executing` after a container restart — safe only
# because the pipeline stages are idempotent (§3), which neutralises its
# documented duplicate-execution risk.
config :grocery_planner, Oban,
  repo: GroceryPlanner.Repo,
  plugins: [
    {Oban.Plugins.Cron, []},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ],
  queues: [default: 10, ai_jobs: 2, matching: 3]

config :ash_oban, :domains, [GroceryPlanner.Inventory, GroceryPlanner.Recipes]

# The receipt pipeline workers (AI-006 Arc 2) do Ash writes inside a repo
# transaction they manage, so Ash can't send action notifications from within it.
# No resource in this app uses an Ash notifier — the pipeline broadcasts via
# Phoenix.PubSub directly — so there is nothing to miss. Silence the noise.
config :ash, :missed_notifications, :ignore

# Configures the endpoint
config :grocery_planner, GroceryPlannerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GroceryPlannerWeb.ErrorHTML, json: GroceryPlannerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GroceryPlanner.PubSub,
  live_view: [signing_salt: "vaoQIKqZ"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :grocery_planner, GroceryPlanner.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  grocery_planner: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__) <> ":" <> Mix.Project.build_path()}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  grocery_planner: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# OpenTelemetry base config
config :opentelemetry, :resource, service: [name: "grocery-planner-web", version: "0.1.0"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
