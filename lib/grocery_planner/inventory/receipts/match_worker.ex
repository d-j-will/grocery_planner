defmodule GroceryPlanner.Inventory.Receipts.MatchWorker do
  @moduledoc """
  Stage 3 of the receipt pipeline: match extracted items to the grocery catalog
  and advance to `:ready_for_review` (AI-006 §1). This is `eeg` — the ~full-catalog
  scan per item that used to run synchronously in the LiveView's `handle_info`.
  It gets its own queue so its CPU cost is bounded independently of the sidecar
  queue. Item updates + milestone commit in one transaction (§3); re-matching is
  idempotent, so a retry is harmless.
  """
  use Oban.Worker, queue: :matching, max_attempts: 5

  alias GroceryPlanner.Inventory
  alias GroceryPlanner.Inventory.{ItemMatcher, Receipt}
  alias GroceryPlanner.Inventory.Receipts.Pipeline
  alias GroceryPlanner.Repo

  @impl Oban.Worker
  def backoff(job), do: Pipeline.backoff(job)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"receipt_id" => id}}) do
    case Pipeline.load_receipt(id) do
      {:ok, receipt} ->
        cond do
          Pipeline.stage_reached?(receipt, :ready_for_review) ->
            :ok

          not Pipeline.stage_reached?(receipt, :items_created) ->
            {:cancel, "items not yet created"}

          true ->
            do_match(receipt)
        end

      {:error, :not_found} ->
        {:cancel, "receipt #{id} not found"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_match(receipt) do
    case Inventory.list_receipt_items_for_receipt(receipt.id,
           authorize?: false,
           tenant: receipt.account_id
         ) do
      {:ok, items} ->
        matched = ItemMatcher.match_receipt_items(items, receipt.account_id)

        case match_transaction(receipt, matched) do
          {:ok, updated} ->
            Pipeline.enqueue_categorise(updated.id)
            Pipeline.broadcast(updated)
            :ok

          {:error, reason} ->
            {:error, "match failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "could not load items: #{inspect(reason)}"}
    end
  end

  defp match_transaction(receipt, matched) do
    Repo.transaction(fn ->
      Enum.each(matched, fn
        {item, {:ok, match}} ->
          Inventory.update_receipt_item!(
            item,
            %{grocery_item_id: match.item.id, match_confidence: match.confidence},
            authorize?: false,
            tenant: receipt.account_id
          )

        {_item, _no_match} ->
          :ok
      end)

      Receipt.mark_ready_for_review!(receipt, authorize?: false, tenant: receipt.account_id)
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end
end
