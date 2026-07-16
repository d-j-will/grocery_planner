defmodule GroceryPlanner.Inventory.Receipts.Pipeline do
  @moduledoc """
  Shared machinery for the staged receipt pipeline (AI-006 Arc 2).

  The pipeline is four hand-written Oban workers —
  `extract -> persist -> match -> categorise` — each enqueued by the previous one.
  They are plain `Oban.Worker`s rather than AshOban triggers because only a
  hand-written worker can express the §4b failure taxonomy (action-driven
  snooze/cancel), which AshOban's generated worker cannot.

  Tenancy is set explicitly from `receipt.account_id` with `authorize?: false` on
  every write — the CLAUDE.md silent-failure trap. This module centralises the
  global (cross-tenant) load so the workers never hand-roll it, and the
  worker-boundary tests assert tenant scoping.
  """

  require Logger
  require Ash.Query

  alias GroceryPlanner.Inventory.Receipt

  # Monotonic milestone order. A stage is "reached" if the receipt is at or past
  # it — this is how each stage's postcondition no-ops on a commit-then-crash
  # retry (AI-006 §3).
  @stages [:pending, :extracted, :items_created, :ready_for_review, :confirmed]

  @doc "The ordered milestone stages."
  def stages, do: @stages

  @doc "Index of a stage in the monotonic order, or nil."
  def stage_index(stage), do: Enum.find_index(@stages, &(&1 == stage))

  @doc "True if the receipt has reached (is at or past) `target` stage."
  def stage_reached?(%Receipt{stage: stage}, target) do
    stage_index(stage) >= stage_index(target)
  end

  @doc """
  Loads a receipt across tenants (the worker only has the id). Returns
  `{:ok, receipt}` or `{:error, :not_found}`. The caller then sets the tenant
  from `receipt.account_id` for any writes.
  """
  def load_receipt(receipt_id) do
    Receipt
    |> Ash.Query.for_read(:worker_read, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^receipt_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, receipt} -> {:ok, receipt}
      {:error, error} -> {:error, error}
    end
  end

  # --- Enqueue next stage -----------------------------------------------------

  def enqueue_extract(receipt_id),
    do: insert(GroceryPlanner.Inventory.Receipts.ExtractWorker, receipt_id)

  def enqueue_persist(receipt_id),
    do: insert(GroceryPlanner.Inventory.Receipts.PersistWorker, receipt_id)

  def enqueue_match(receipt_id),
    do: insert(GroceryPlanner.Inventory.Receipts.MatchWorker, receipt_id)

  def enqueue_categorise(receipt_id),
    do: insert(GroceryPlanner.Inventory.Receipts.CategoriseWorker, receipt_id)

  @doc """
  Re-enqueues the worker for the receipt's current stage. Used by the reconciler
  for stranded records. Reads `stage` only — never `condition`.
  """
  def enqueue_for_stage(%Receipt{id: id, stage: :pending}), do: enqueue_extract(id)
  def enqueue_for_stage(%Receipt{id: id, stage: :extracted}), do: enqueue_persist(id)
  def enqueue_for_stage(%Receipt{id: id, stage: :items_created}), do: enqueue_match(id)
  # :ready_for_review / :confirmed are terminal for the automatic pipeline.
  def enqueue_for_stage(%Receipt{}), do: :ok

  defp insert(worker, receipt_id) do
    %{receipt_id: receipt_id}
    |> worker.new()
    |> Oban.insert()
  end

  # --- PubSub (UI hint only; durable state is written first) ------------------

  @doc """
  Broadcasts the current receipt state to its LiveView topic. This is a UI hint
  only — the durable `stage`/`condition` is already written, so a lost message
  just means the LiveView catches up on reconnect (AI-006 §1).
  """
  def broadcast(%Receipt{} = receipt) do
    Phoenix.PubSub.broadcast(
      GroceryPlanner.PubSub,
      "receipt:#{receipt.id}",
      {:receipt_updated, receipt}
    )
  end

  # --- Backoff ----------------------------------------------------------------

  @backoff_cap_seconds 300

  @doc """
  Capped exponential backoff (AI-006 §4d). Snoozing increments `attempt` in
  lockstep with `max_attempts`, so the default exponential backoff would explode
  after a run of snoozes (the Oban docs cite ~6 days between attempts 19 and 20).
  Capping the backoff outright is the spec-sanctioned discount: a later real
  error never waits more than #{@backoff_cap_seconds}s regardless of how many
  snoozes inflated `attempt`.
  """
  def backoff(%Oban.Job{attempt: attempt}) do
    base = :math.pow(2, min(attempt, 8)) |> trunc()
    min(base, @backoff_cap_seconds)
  end
end
