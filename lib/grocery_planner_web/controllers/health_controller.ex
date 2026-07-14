defmodule GroceryPlannerWeb.HealthController do
  use GroceryPlannerWeb, :controller

  def check(conn, _params) do
    checks = %{
      database: check_database(),
      ai_service: check_ai_service(),
      oban: check_oban()
    }

    status = determine_status(checks)

    conn
    |> put_status(if status == "ok", do: 200, else: 503)
    |> json(%{
      status: status,
      checks: checks,
      version: to_string(Application.spec(:grocery_planner, :vsn))
    })
  end

  @doc """
  Readiness probe — the container healthcheck + caddy routing gate.

  Returns 200 iff the database answers within a short timeout. It deliberately
  does NOT check the optional AI sidecar or Oban: a degraded sidecar must not
  pull a serving, DB-backed app out of rotation. The richer `check/2`
  (`/health_check`) stays for monitoring, where degraded → 503 is correct.

  See org-brain: single-instance-ship-ready-defer-liveness.
  """
  def ready(conn, _params) do
    case check_database(2_000) do
      %{status: "ok"} ->
        conn |> put_status(:ok) |> json(%{status: "ready"})

      database ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "not_ready", database: database})
    end
  end

  # Short timeout so a *wedged* DB fails fast (503) rather than hanging the probe.
  defp check_database(timeout \\ 5_000) do
    case Ecto.Adapters.SQL.query(GroceryPlanner.Repo, "SELECT 1", [], timeout: timeout) do
      {:ok, _} -> %{status: "ok"}
      {:error, reason} -> %{status: "error", error: inspect(reason)}
    end
  end

  defp check_ai_service do
    case GroceryPlanner.AiClient.health_check() do
      {:ok, body} -> %{status: body["status"], details: body["checks"]}
      {:error, _reason} -> %{status: "unavailable"}
    end
  end

  defp check_oban do
    case Oban.check_queue(conf: Oban, queue: :default) do
      %{paused: paused} ->
        %{status: if(paused, do: "paused", else: "ok")}

      _ ->
        %{status: "ok"}
    end
  rescue
    _ -> %{status: "unknown"}
  end

  defp determine_status(checks) do
    cond do
      checks.database.status != "ok" -> "error"
      checks.ai_service.status in ["error", "unavailable"] -> "degraded"
      true -> "ok"
    end
  end
end
