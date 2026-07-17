defmodule GroceryPlanner.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    setup_opentelemetry()

    children = [
      GroceryPlanner.PromEx,
      GroceryPlannerWeb.Telemetry,
      GroceryPlanner.Repo,
      {Oban,
       AshOban.config(
         [GroceryPlanner.Inventory, GroceryPlanner.Recipes],
         Application.fetch_env!(:grocery_planner, Oban)
       )},
      {DNSCluster, query: Application.get_env(:grocery_planner, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: GroceryPlanner.PubSub},
      # Start a worker by calling: GroceryPlanner.Worker.start_link(arg)
      # {GroceryPlanner.Worker, arg},
      # Start to serve requests, typically the last entry
      GroceryPlannerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GroceryPlanner.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Validate AI service connectivity after supervision tree starts (non-blocking)
    if Application.get_env(:grocery_planner, :validate_ai_service, false) do
      Task.start(fn ->
        Process.sleep(2_000)
        validate_ai_service()
      end)
    end

    result
  end

  @doc false
  def reinit_opentelemetry, do: setup_opentelemetry()

  # Defaults to true so dev/test keep attaching handlers (both set
  # `traces_exporter: :none`, so nothing leaves the box). runtime.exs sets it
  # explicitly in prod: without a collector configured there is nothing to export
  # to, and attaching handlers would pay the full instrumentation cost to produce
  # spans that are dropped.
  defp setup_opentelemetry do
    if Application.get_env(:grocery_planner, :otel_enabled, true) do
      OpentelemetryPhoenix.setup()
      OpentelemetryEcto.setup([:grocery_planner, :repo])

      if Code.ensure_loaded?(OpentelemetryOban) do
        OpentelemetryOban.setup()
      end
    end
  rescue
    error ->
      Logger.warning("Failed to initialize OpenTelemetry: #{inspect(error)}")
  end

  defp validate_ai_service do
    require_ai_service? = Application.get_env(:grocery_planner, :require_ai_service, false)

    case GroceryPlanner.AiClient.health_check() do
      {:ok, %{"status" => "ok"} = body} ->
        Logger.info("AI service connected: #{inspect(body)}")

      {:ok, %{"status" => "degraded"} = body} ->
        Logger.warning("AI service degraded: #{inspect(body)}")

      {:error, reason} ->
        if require_ai_service? do
          Logger.error("AI service unavailable (required): #{inspect(reason)}")
          System.stop(1)
        else
          Logger.warning("AI service unavailable: #{inspect(reason)}. AI features disabled.")
        end
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GroceryPlannerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
