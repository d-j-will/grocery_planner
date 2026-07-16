import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/grocery_planner start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :grocery_planner, GroceryPlannerWeb.Endpoint, server: true
end

# AI Feature Flags
config :grocery_planner, :features,
  ai_categorization: System.get_env("AI_CATEGORIZATION_ENABLED", "false") == "true",
  semantic_search: System.get_env("SEMANTIC_SEARCH_ENABLED", "false") == "true",
  receipt_processing: System.get_env("RECEIPT_PROCESSING_ENABLED", "false") == "true"

# Receipt processing
config :grocery_planner,
       :receipt_upload_dir,
       System.get_env("RECEIPT_STORAGE_PATH", "priv/static/uploads/receipts")

# Operator allowlist for the /admin/oban dashboard. Comma-separated emails.
# Only applied when ADMIN_EMAILS is set, so it doesn't clobber the compile-time
# allowlist (config.exs default [] / dev.exs / test.exs) in envs that don't use
# the env var. Unset in prod → deny everyone (fails closed, cross-tenant surface).
if admin_emails = System.get_env("ADMIN_EMAILS") do
  config :grocery_planner,
         :admin_emails,
         admin_emails |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# AI Service Configuration — set in all environments so the AiClient base URL
# is resolved consistently (dev/test/prod) rather than only under :prod.
config :grocery_planner,
       :ai_service_url,
       System.get_env("AI_SERVICE_URL") || "http://localhost:8000"

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :grocery_planner, GroceryPlanner.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :grocery_planner, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :grocery_planner, GroceryPlannerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # LiveView/Channels WebSocket Origin check. Behind Cloudflare the browser
    # sends Origin: https://<PHX_HOST>; bind the allow-list to it explicitly so
    # the socket upgrade isn't rejected. (tdu.2 deferred check_origin to tdu.6.)
    check_origin: ["https://#{host}"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :grocery_planner, GroceryPlannerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :grocery_planner, GroceryPlannerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # OpenTelemetry: instrument only when a collector is actually configured.
  #
  # With no config at all the exporter defaults to http://localhost:4317, so every
  # span is batched, shipped nowhere and dropped — full instrumentation cost for
  # zero visibility, plus background export errors. An enabled-but-unconfigured
  # exporter therefore says so and disables itself, rather than silently pretending
  # to work. Telemetry must never take the app down, so this warns instead of
  # raising.
  otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

  otel_enabled? =
    case {System.get_env("OTEL_ENABLED"), otel_endpoint} do
      {"true", endpoint} when endpoint not in [nil, ""] ->
        true

      {"true", _} ->
        IO.warn("""
        OTEL_ENABLED=true but OTEL_EXPORTER_OTLP_ENDPOINT is unset — tracing DISABLED.
        Set it to your collector (e.g. http://collector:4317) to enable tracing.
        """)

        false

      _ ->
        false
    end

  # Read by setup_opentelemetry/0 in application.ex: when false, the telemetry
  # handlers are never attached, so no spans are created in the first place.
  config :grocery_planner, :otel_enabled, otel_enabled?

  if otel_enabled? do
    config :opentelemetry,
      span_processor: :batch,
      traces_exporter: :otlp

    config :opentelemetry_exporter,
      otlp_protocol: :grpc,
      otlp_endpoint: otel_endpoint
  else
    config :opentelemetry, traces_exporter: :none
  end

  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :grocery_planner, GroceryPlanner.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
