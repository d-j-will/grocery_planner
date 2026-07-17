defmodule GroceryPlanner.MixProject do
  use Mix.Project

  def project do
    [
      app: :grocery_planner,
      version: "0.2.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {GroceryPlanner.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "test.integration": :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:usage_rules, "~> 0.1", only: [:dev]},
      {:ex_money_sql, "~> 2.0"},
      {:ex_cldr, "~> 2.0"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ash_money, "~> 0.2"},
      {:tidewave, "~> 0.5", only: [:dev]},
      {:live_debugger, "~> 0.4", only: [:dev]},
      {:ash_postgres, "~> 2.0"},
      {:ash, "~> 3.29"},
      {:ash_json_api, "~> 1.0"},
      {:open_api_spex, "~> 3.0"},
      {:picosat_elixir, "~> 0.2"},
      {:bcrypt_elixir, "~> 3.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      # Metrics egress (Prometheus /metrics) + bundled Grafana dashboards
      {:prom_ex, "~> 1.11.0"},
      # Oban dashboard — free/Apache-2.0 since 2025-01-16 (discarded-job visibility)
      {:oban_web, "~> 2.11"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:castore, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:pgvector, "~> 0.3.0"},
      {:ash_oban, "~> 0.7"},
      {:ash_ai, "~> 0.5.0"},
      {:stream_data, "~> 1.1"},
      # OpenTelemetry - Distributed Tracing
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_phoenix, "~> 1.2"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_oban, "~> 1.1"},
      {:opentelemetry_req, "~> 0.2"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: [
        "deps.get",
        "ash.setup",
        "assets.setup",
        "assets.build",
        "python.setup",
        "run priv/repo/seeds.exs"
      ],
      "python.setup": [
        "cmd python3 -m venv python_service/.venv",
        "cmd python_service/.venv/bin/pip install -q -r python_service/requirements.txt"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "test.integration": ["ash.setup --quiet", "test --only integration"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind grocery_planner", "esbuild grocery_planner"],
      "assets.deploy": [
        "tailwind grocery_planner --minify",
        "esbuild grocery_planner --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warning-as-errors",
        "deps.unlock --unused",
        "format",
        "cmd bash -c 'cd python_service && uv run ruff check .'",
        "test"
      ]
    ]
  end
end
