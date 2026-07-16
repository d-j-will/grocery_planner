defmodule GroceryPlanner.RuntimeOtelConfigTest do
  @moduledoc """
  Guards the prod OpenTelemetry gate (grocery_planner-t7j).

  This is boot configuration, so it can't be reached through any HTTP boundary —
  and its failure mode is silence. With no `:opentelemetry` config in prod the
  exporter defaults to `http://localhost:4317`, so every span is batched, shipped
  nowhere and dropped: full instrumentation cost, zero visibility, and nothing
  fails. That went unnoticed for months. These assertions are the only thing that
  can notice it.
  """
  # Manipulates the OS environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @required %{
    "DATABASE_URL" => "ecto://user:pass@localhost/db",
    "SECRET_KEY_BASE" => String.duplicate("x", 64),
    "PHX_HOST" => "example.com"
  }

  setup do
    previous =
      Map.new(
        ["OTEL_ENABLED", "OTEL_EXPORTER_OTLP_ENDPOINT" | Map.keys(@required)],
        &{&1, System.get_env(&1)}
      )

    System.put_env(@required)
    System.delete_env("OTEL_ENABLED")
    System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  defp prod_config, do: Config.Reader.read!("config/runtime.exs", env: :prod)

  test "no collector configured: tracing is off and nothing is exported" do
    config = prod_config()

    assert config[:grocery_planner][:otel_enabled] == false
    assert config[:opentelemetry][:traces_exporter] == :none
  end

  test "enabled without an endpoint: warns and disables, rather than exporting into the void" do
    System.put_env("OTEL_ENABLED", "true")

    stderr = capture_io(:stderr, fn -> send(self(), {:config, prod_config()}) end)
    assert_received {:config, config}

    assert stderr =~ "OTEL_EXPORTER_OTLP_ENDPOINT is unset"
    assert config[:grocery_planner][:otel_enabled] == false
    assert config[:opentelemetry][:traces_exporter] == :none
  end

  test "enabled with an endpoint: exports to that endpoint" do
    System.put_env("OTEL_ENABLED", "true")
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4317")

    config = prod_config()

    assert config[:grocery_planner][:otel_enabled]
    assert config[:opentelemetry][:traces_exporter] == :otlp
    assert config[:opentelemetry_exporter][:otlp_endpoint] == "http://collector:4317"
  end
end
