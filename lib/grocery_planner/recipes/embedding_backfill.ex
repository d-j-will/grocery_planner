defmodule GroceryPlanner.Recipes.EmbeddingBackfill do
  @moduledoc """
  Re-embeds existing recipes by enqueuing the ash_ai embedding trigger for each
  one (grocery_planner-z7h).

  The embedding trigger is event-driven — it only fires on recipe create/update —
  so recipes that predate the working trigger (or any created while the sidecar
  was down) never get embedded. This is the backfill path that replaces the
  deleted raw-SQL `EmbeddingBackfillWorker`: it reuses the exact production path
  (`AshOban.run_trigger/3`), so tenancy and the field contract are handled the
  same way as a normal create, rather than hand-written SQL that bypassed both.

  Re-enqueuing is idempotent: the trigger recomputes the embedding, so running
  the backfill more than once is safe.

  Run in prod via a release eval:

      bin/grocery_planner eval 'GroceryPlanner.Recipes.EmbeddingBackfill.run()'
  """
  alias GroceryPlanner.Recipes.Recipe

  require Ash.Query

  @doc """
  Enqueues the embedding trigger for every non-deleted recipe across all accounts.
  Returns the number of recipes enqueued.
  """
  @spec run() :: non_neg_integer()
  def run do
    Recipe
    |> Ash.Query.for_read(:stream_for_backfill)
    # :full_read — a one-off maintenance scan of every recipe; the action has no
    # pagination and we want the whole table, so don't require a keyset strategy.
    |> Ash.stream!(authorize?: false, stream_with: :full_read)
    |> Enum.reduce(0, fn recipe, count ->
      AshOban.run_trigger(recipe, :ash_ai_update_embeddings, tenant: recipe.account_id)
      count + 1
    end)
  end
end
