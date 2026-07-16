defmodule GroceryPlanner.Inventory.Changes.ReconcileReceipt do
  @moduledoc """
  Change for the `:reconcile` action (the AshOban reconciler trigger). Re-enqueues
  the pipeline worker for the receipt's current stage and bumps `updated_at` so the
  record leaves the "stranded" window until the next scan (AI-006 §3).

  It never touches `stage` or `condition` — the reconciler is a safety net for
  records whose Oban job was lost (e.g. a container restart Lifeline didn't catch),
  not a state machine.
  """
  use Ash.Resource.Change

  alias GroceryPlanner.Inventory.Receipts.Pipeline

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:updated_at, DateTime.utc_now())
    |> Ash.Changeset.after_action(fn _changeset, receipt ->
      Pipeline.enqueue_for_stage(receipt)
      {:ok, receipt}
    end)
  end
end
