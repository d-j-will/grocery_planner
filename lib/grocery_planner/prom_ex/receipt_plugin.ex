defmodule GroceryPlanner.PromEx.ReceiptPlugin do
  @moduledoc """
  Domain metrics for the receipt pipeline (AI-006 §7).

  Exposes `count(receipts by condition)` as a polled gauge. The load-bearing
  series is `condition="awaiting_ai"`: a rising, non-draining count is a sidecar
  outage, and it is the signal that stops §4c's snooze from hiding one. The
  `condition="failed"` series is the terminal-failure counterpart.

  ## Why polled, not evented

  Job counts (discarded, completed, errors) come from Oban's telemetry events —
  they fire when something *happens*. But a receipt *staying* stuck in
  `:awaiting_ai` emits nothing; the stuck state is what we must observe. So this
  is sampled on a timer against the `receipts` table, like any state gauge.

  ## Why a raw Repo aggregate

  `receipts` is multi-tenant (`account_id` attribute strategy), but this is an
  ops-wide gauge — "how many receipts, across all households, are stuck" — so it
  is legitimately cross-tenant. A raw Ecto aggregate reads every row without an
  Ash tenant/actor, which is both correct here and avoids the `actor: nil`
  silent-empty-result trap that a policy-scoped Ash read would hit.
  """

  use PromEx.Plugin

  import Ecto.Query, only: [from: 2]

  alias GroceryPlanner.Repo

  # Mirrors Receipt's `condition` enum. Every value is emitted on each poll
  # (defaulting to 0) so a gauge that drains back to empty reports 0 rather than
  # holding its last non-zero value.
  @conditions [:ok, :awaiting_ai, :failed]

  @event [:prom_ex, :plugin, :receipt, :condition, :count]

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate, 10_000)
    metric_prefix = Keyword.get(opts, :metric_prefix, [:grocery_planner, :prom_ex, :receipt])

    [
      Polling.build(
        :receipt_pipeline_polling_metrics,
        poll_rate,
        {__MODULE__, :execute_receipt_metrics, []},
        [
          last_value(
            metric_prefix ++ [:condition, :count],
            event_name: @event,
            description:
              "Number of receipts in each pipeline condition. condition=awaiting_ai is the sidecar-outage signal; condition=failed is terminal failures.",
            measurement: :count,
            tags: [:condition]
          )
        ]
      )
    ]
  end

  @doc false
  def execute_receipt_metrics do
    counts = receipt_condition_counts()

    for condition <- @conditions do
      :telemetry.execute(@event, %{count: Map.get(counts, condition, 0)}, %{condition: condition})
    end

    :ok
  end

  @doc """
  Count of receipts grouped by `condition`, as a map of `atom => count`.

  Unknown / legacy condition strings are ignored rather than crashing the poll.
  """
  @spec receipt_condition_counts() :: %{atom() => non_neg_integer()}
  def receipt_condition_counts do
    from(r in "receipts", group_by: r.condition, select: {r.condition, count(r.id)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {condition, n}, acc ->
      case to_known_condition(condition) do
        nil -> acc
        atom -> Map.put(acc, atom, n)
      end
    end)
  end

  # condition is stored as a string by Ash's :atom type; map it back onto the
  # known enum only (no String.to_atom on stored data).
  defp to_known_condition(condition) when is_binary(condition) do
    Enum.find(@conditions, fn c -> Atom.to_string(c) == condition end)
  end

  defp to_known_condition(condition) when is_atom(condition), do: condition
  defp to_known_condition(_), do: nil
end
