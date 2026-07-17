defmodule GroceryPlanner.Recipes.RecipeEmbeddingTriggerTest do
  @moduledoc """
  Boundary test for z7h: creating a recipe must drive the ash_ai `:ash_oban`
  vectorize trigger all the way through — enqueue AND a *successful* worker run.

  The load-bearing assertion is `drain -> %{success: 1}`, not "embedding is not
  nil". ash_ai writes a placeholder vector inside the create transaction, so a
  nil-check would pass even if the async job did nothing. The job only reports
  `success` when its tenant-scoped worker read finds the record (tenancy intact)
  AND the embedding update writes to the real `:embedding` column. Every broken
  state we fixed shows up here as a different drain tally: a missing AshOban auth
  bypass -> `cancelled: 1`; the wrong vector column -> `failure: 1`.
  """
  use GroceryPlanner.DataCase, async: false
  use Oban.Testing, repo: GroceryPlanner.Repo

  import GroceryPlanner.RecipesTestHelpers, only: [create_recipe: 3]

  @worker GroceryPlanner.Recipes.Recipe.AshOban.Worker.AshAiUpdateEmbeddings

  setup do
    stub_embeddings()
    {account, user} = create_account_and_user()
    %{account: account, user: user}
  end

  test "creating a recipe enqueues an embedding job that runs to success",
       %{account: account, user: user} do
    recipe =
      create_recipe(account, user, %{name: "Carbonara", description: "Eggs, cheese, pancetta"})

    # Acceptance: the create enqueues the embedding worker (not run inline).
    assert_enqueued(worker: @worker)

    # End-to-end proof: draining runs the job with the tenant `run_trigger`
    # captured. `success: 1` means the worker read found the tenant-scoped record
    # and the embedding update wrote the real `:embedding` column. A tenancy or
    # column regression would surface here as cancelled/failure instead.
    assert %{success: 1, cancelled: 0, failure: 0} = Oban.drain_queue(queue: :ai_jobs)

    _ = recipe
  end

  # The real /api/v1/embed response (python_service EmbedResponse) is FLAT —
  # `embeddings` at the top level, no `payload` wrapper — which is what
  # EmbeddingModel.generate/2 parses. Mirror that exact shape.
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
