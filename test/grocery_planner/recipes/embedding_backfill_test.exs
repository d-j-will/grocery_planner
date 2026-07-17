defmodule GroceryPlanner.Recipes.EmbeddingBackfillTest do
  @moduledoc """
  z7h backfill path: the deleted raw-SQL EmbeddingBackfillWorker is replaced by
  EmbeddingBackfill.run/0, which re-enqueues the ash_ai trigger for every recipe.
  Asserts the backfill enqueues a *successful* embedding job per recipe, across
  accounts — draining to `success` is the proof the tenant carried through
  `run_trigger` for records read cross-tenant.
  """
  use GroceryPlanner.DataCase, async: false
  use Oban.Testing, repo: GroceryPlanner.Repo

  import GroceryPlanner.RecipesTestHelpers, only: [create_recipe: 3]

  alias GroceryPlanner.Recipes.EmbeddingBackfill

  setup do
    stub_embeddings()
    :ok
  end

  test "backfill re-embeds recipes across accounts and the jobs run to success" do
    {account_a, user_a} = create_account_and_user()
    {account_b, user_b} = create_account_and_user()
    create_recipe(account_a, user_a, %{name: "A1"})
    create_recipe(account_a, user_a, %{name: "A2"})
    create_recipe(account_b, user_b, %{name: "B1"})

    # Clear the create-time trigger jobs so the drain tally reflects the backfill
    # alone, not the enqueue-on-create.
    Oban.drain_queue(queue: :ai_jobs)

    assert EmbeddingBackfill.run() == 3

    # Every backfilled recipe's job runs successfully — cross-tenant read +
    # per-record tenant on the trigger both work.
    assert %{success: 3, cancelled: 0, failure: 0} = Oban.drain_queue(queue: :ai_jobs)
  end

  defp stub_embeddings do
    Req.Test.stub(GroceryPlanner.AiClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      Req.Test.json(conn, %{
        "version" => "1.0",
        "request_id" => decoded["request_id"],
        "model" => "all-MiniLM-L6-v2",
        "dimension" => 384,
        "embeddings" =>
          Enum.map(decoded["texts"], fn t ->
            %{"id" => t["id"], "vector" => List.duplicate(0.1, 384)}
          end)
      })
    end)
  end
end
