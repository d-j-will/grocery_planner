defmodule GroceryPlanner.Inventory.Receipts.CategoriseWorker do
  @moduledoc """
  Stage 4 of the receipt pipeline: AI category suggestions for the extracted items
  (AI-006 §2b). This is a **side-branch**: it has no milestone and its failure sets
  no `condition` on the receipt. A receipt with no AI-suggested categories is still
  perfectly reviewable — exactly what happens today when the sidecar is off. So
  this stage is degradable by design: it is gated on `Categorizer.enabled?()` and
  swallows its own errors (replacing the old unsupervised `Task.start`).
  """
  use Oban.Worker, queue: :ai_jobs, max_attempts: 3

  require Logger

  alias GroceryPlanner.AI.Categorizer
  alias GroceryPlanner.Inventory.ReceiptProcessor
  alias GroceryPlanner.Inventory.Receipts.Pipeline

  @impl Oban.Worker
  def backoff(job), do: Pipeline.backoff(job)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"receipt_id" => id}}) do
    with true <- Categorizer.enabled?(),
         {:ok, receipt} <- Pipeline.load_receipt(id) do
      _ = ReceiptProcessor.categorize_extracted_items(receipt, receipt.account_id)
      # Degradable: broadcast so the LiveView can refresh suggestions, but never
      # fail the receipt on a categorisation problem.
      Pipeline.broadcast(receipt)
      :ok
    else
      # Feature disabled or receipt gone — nothing to do, and nothing is wrong.
      false -> :ok
      {:error, :not_found} -> {:cancel, "receipt #{id} not found"}
      {:error, reason} -> {:error, reason}
    end
  end
end
