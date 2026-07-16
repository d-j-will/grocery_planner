defmodule GroceryPlanner.Inventory.Receipts.PersistWorker do
  @moduledoc """
  Stage 2 of the receipt pipeline: turn the `raw_extraction` the extract stage
  wrote into ReceiptItems (AI-006 §1). Creating the items and advancing the
  milestone to `:items_created` happen in **one transaction** (§3), so a
  commit-then-crash retry can never leave items without the milestone or vice
  versa. The postcondition check makes the retry a no-op; the `(receipt_id,
  line_no)` unique index is the belt-and-braces guarantee against duplicates.
  """
  use Oban.Worker, queue: :default, max_attempts: 5

  alias GroceryPlanner.Inventory.{Receipt, ReceiptItem}
  alias GroceryPlanner.Inventory.ReceiptProcessor
  alias GroceryPlanner.Inventory.Receipts.Pipeline
  alias GroceryPlanner.Repo

  @impl Oban.Worker
  def backoff(job), do: Pipeline.backoff(job)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"receipt_id" => id}}) do
    case Pipeline.load_receipt(id) do
      {:ok, receipt} ->
        cond do
          # Postcondition already met — no-op (§3).
          Pipeline.stage_reached?(receipt, :items_created) ->
            :ok

          # Precondition not met — extraction hasn't landed; nothing to persist.
          not Pipeline.stage_reached?(receipt, :extracted) ->
            {:cancel, "receipt not yet extracted"}

          true ->
            do_persist(receipt)
        end

      {:error, :not_found} ->
        {:cancel, "receipt #{id} not found"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_persist(receipt) do
    item_attrs = ReceiptProcessor.parse_item_attrs_list(receipt.raw_extraction || %{})

    case persist_transaction(receipt, item_attrs) do
      {:ok, updated} ->
        Pipeline.enqueue_match(updated.id)
        Pipeline.broadcast(updated)
        :ok

      {:error, reason} ->
        {:error, "persist failed: #{inspect(reason)}"}
    end
  end

  # Items + milestone in a single transaction. A raise inside rolls the whole
  # thing back and is reraised by Repo.transaction, which the rescue turns into
  # an {:error, _} so Oban retries.
  defp persist_transaction(receipt, item_attrs) do
    Repo.transaction(fn ->
      inputs =
        Enum.map(item_attrs, fn attrs ->
          Map.merge(attrs, %{receipt_id: receipt.id, account_id: receipt.account_id})
        end)

      Ash.bulk_create!(inputs, ReceiptItem, :create,
        authorize?: false,
        tenant: receipt.account_id,
        return_records?: false,
        stop_on_error?: true
      )

      Receipt.mark_items_created!(receipt, authorize?: false, tenant: receipt.account_id)
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end
end
