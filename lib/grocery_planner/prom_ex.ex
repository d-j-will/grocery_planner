defmodule GroceryPlanner.PromEx do
  @moduledoc """
  PromEx metrics collector.

  Metrics are exposed for Prometheus scraping at `GET /metrics` via
  `PromEx.Plug` (mounted in `GroceryPlannerWeb.Endpoint`) rather than PromEx's
  standalone HTTP server. The plugins below cover the infrastructure axes
  (BEAM, Phoenix, Ecto) and — the point of AI-006 Arc 3 — the Oban pipeline
  and the receipt-domain outage signal:

    * `PromEx.Plugins.Oban` — via `Oban.Met`, exposes `oban_queue_length_count`
      as a **level gauge** labelled by `state` and `queue`. That single family
      covers two §7 bullets: per-`queue`/`state` series are queue depth, and the
      `state="discarded"` / `state="cancelled"` series are the **dead-letter
      signal** (alert on non-zero:
      `sum(...oban_queue_length_count{state=~"discarded|cancelled"}) > 0`).
      NOTE: `Oban.Met` only auto-starts when Oban is *not* in testing mode, so
      these series are absent under `testing: :manual` (and the Oban Web
      dashboard cannot mount there) — they are live in dev/prod.
    * `GroceryPlanner.PromEx.ReceiptPlugin` — `count(receipts by condition)`,
      whose `condition="awaiting_ai"` series is **the outage signal** that stops
      §4c's snooze from hiding a sidecar outage.

  Not yet covered: error rate split by our domain error class
  (`:unavailable` / `{:bad_input, _}` / `{:transient, _}`) — the Oban plugin
  counts errors by worker/queue, not by class. Tracked as a follow-up.

  Homelab egress (a Prometheus scrape target + Grafana dashboards against the
  existing observability stack) is deployment wiring tracked in
  `grocery_planner-k9c`; nothing here uploads dashboards or opens a port.
  """
  use PromEx, otp_app: :grocery_planner

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      {Plugins.Application, otp_app: :grocery_planner},
      Plugins.Beam,
      {Plugins.Phoenix, router: GroceryPlannerWeb.Router, endpoint: GroceryPlannerWeb.Endpoint},
      {Plugins.Ecto, otp_app: :grocery_planner},
      {Plugins.Oban, oban_supervisors: [Oban]},
      {GroceryPlanner.PromEx.ReceiptPlugin,
       poll_rate: Application.get_env(:grocery_planner, :receipt_metrics_poll_rate, 10_000)}
    ]
  end

  @impl true
  def dashboard_assigns do
    [datasource_id: "prometheus", default_selected_interval: "30s"]
  end

  @impl true
  def dashboards do
    # PromEx can generate Grafana dashboards for these plugins; they are imported
    # into the homelab Grafana out-of-band (grocery_planner-k9c). No in-app
    # Grafana uploader is configured, so this stays empty deliberately.
    []
  end
end
