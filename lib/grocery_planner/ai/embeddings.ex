defmodule GroceryPlanner.AI.Embeddings do
  @moduledoc """
  Client for generating and managing text embeddings.
  Provides semantic search and similarity features for recipes.
  """

  require Logger
  alias GroceryPlanner.AiClient
  alias GroceryPlanner.Repo

  @doc """
  Checks if semantic search is enabled via feature flag.
  """
  def enabled? do
    Application.get_env(:grocery_planner, :features, [])
    |> Keyword.get(:semantic_search, false)
  end

  @doc """
  Generates an embedding vector for the given text.
  Returns {:ok, [float()]} or {:error, term()}.
  """
  def generate(text, opts \\ []) do
    context = %{
      tenant_id: opts[:tenant_id] || "system",
      user_id: opts[:user_id] || "system"
    }

    client_opts = if opts[:plug], do: [plug: opts[:plug]], else: []

    case AiClient.generate_embeddings(
           [%{id: "1", text: text}],
           context,
           client_opts
         ) do
      {:ok, %{"embeddings" => [%{"vector" => vector} | _]}} ->
        {:ok, vector}

      {:ok, %{embeddings: [%{vector: vector} | _]}} ->
        {:ok, vector}

      {:ok, %{"embeddings" => []}} ->
        Logger.warning("Embedding generation returned no embeddings")
        {:error, :no_embedding}

      {:ok, %{embeddings: []}} ->
        Logger.warning("Embedding generation returned no embeddings")
        {:error, :no_embedding}

      {:ok, _other} ->
        Logger.warning("Embedding generation returned an unexpected response shape")
        {:error, :unexpected_embedding_response}

      {:error, reason} ->
        Logger.warning("Embedding generation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Generates embeddings for multiple texts in batch.
  Each text should be a map with :id and :text keys.
  Returns {:ok, [%{id: id, vector: [float()]}]} or {:error, term()}.
  """
  def generate_batch(texts, opts \\ []) do
    context = %{
      tenant_id: opts[:tenant_id] || "system",
      user_id: opts[:user_id] || "system"
    }

    client_opts = if opts[:plug], do: [plug: opts[:plug]], else: []

    case AiClient.generate_embeddings(texts, context, client_opts) do
      {:ok, %{"embeddings" => embeddings}} ->
        {:ok, Enum.map(embeddings, fn e -> %{id: e["id"], vector: e["vector"]} end)}

      {:ok, %{embeddings: embeddings}} ->
        {:ok, Enum.map(embeddings, fn e -> %{id: e.id, vector: e.vector} end)}

      {:ok, _other} ->
        Logger.warning("Batch embedding generation returned an unexpected response shape")
        {:error, :unexpected_embedding_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds searchable text from a recipe for embedding generation.
  Combines name, description, ingredients, cuisine, difficulty, and time.
  """
  def build_recipe_text(recipe) do
    ingredients =
      case recipe do
        %{recipe_ingredients: ingredients} when is_list(ingredients) ->
          ingredients
          |> Enum.map(fn ri ->
            case ri do
              %{grocery_item: %{name: name}} -> name
              %{name: name} when is_binary(name) -> name
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join(", ")

        _ ->
          ""
      end

    dietary =
      case recipe.dietary_needs do
        needs when is_list(needs) -> Enum.map_join(needs, ", ", &to_string/1)
        _ -> ""
      end

    [
      recipe.name,
      recipe.description,
      if(ingredients != "", do: "Ingredients: #{ingredients}"),
      if(recipe.cuisine, do: "Cuisine: #{recipe.cuisine}"),
      if(dietary != "", do: "Dietary: #{dietary}"),
      if(recipe.difficulty, do: "Difficulty: #{recipe.difficulty}"),
      if(recipe.prep_time_minutes || recipe.cook_time_minutes,
        do: "Time: #{(recipe.prep_time_minutes || 0) + (recipe.cook_time_minutes || 0)} minutes"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(". ")
  end

  @doc """
  Updates a recipe's embedding in the database using raw SQL.
  Uses Pgvector for native vector type support.
  """
  def update_recipe_embedding(recipe_id, embedding, model \\ "all-MiniLM-L6-v2") do
    vector = Pgvector.new(embedding)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    recipe_uuid = dump_uuid!(recipe_id)

    Repo.query!(
      "UPDATE recipes SET embedding = $1, embedding_model = $2, embedding_updated_at = $3 WHERE id = $4",
      [vector, model, now, recipe_uuid]
    )

    :ok
  end

  @doc """
  Searches recipes by semantic similarity to the query.
  Uses raw SQL with pgvector cosine distance.
  Returns {:ok, [%{recipe_id: uuid, name: string, similarity: float}]} or {:error, term()}.
  """
  def search_recipes(query, opts \\ []) do
    if not enabled?() do
      {:error, :disabled}
    else
      account_id = Keyword.fetch!(opts, :account_id)
      limit = Keyword.get(opts, :limit, 20)
      min_similarity = Keyword.get(opts, :min_similarity, 0.3)

      with {:ok, query_embedding} <- generate(query, opts) do
        vector = Pgvector.new(query_embedding)
        account_uuid = dump_uuid!(account_id)

        results =
          Repo.query!(
            """
            SELECT id, name, 1 - (embedding <=> $1::vector) AS similarity
            FROM recipes
            WHERE account_id = $2
              AND embedding IS NOT NULL
              AND 1 - (embedding <=> $1::vector) >= $3
            ORDER BY embedding <=> $1::vector
            LIMIT $4
            """,
            [vector, account_uuid, min_similarity, limit]
          )

        recipes =
          Enum.map(results.rows, fn [id, name, similarity] ->
            %{recipe_id: load_uuid!(id), name: name, similarity: similarity}
          end)

        {:ok, recipes}
      end
    end
  end

  @doc """
  Hybrid search combining keyword matching with semantic search.
  Exact name matches are ranked highest, then semantic matches.
  """
  def hybrid_search(query, opts \\ []) do
    account_id = Keyword.fetch!(opts, :account_id)
    keyword_weight = Keyword.get(opts, :keyword_weight, 0.3)
    semantic_weight = Keyword.get(opts, :semantic_weight, 0.7)
    limit = Keyword.get(opts, :limit, 20)

    keyword_results = keyword_search(query, account_id, limit)

    semantic_results =
      if enabled?() do
        case search_recipes(query, opts) do
          {:ok, results} -> results
          {:error, _} -> []
        end
      else
        []
      end

    combine_results(keyword_results, semantic_results, keyword_weight, semantic_weight, limit)
  end

  @doc """
  Finds recipes similar to the given recipe by comparing embeddings.
  """
  def find_similar_recipes(recipe_id, opts \\ []) do
    account_id = Keyword.fetch!(opts, :account_id)
    limit = Keyword.get(opts, :limit, 5)
    recipe_uuid = dump_uuid!(recipe_id)
    account_uuid = dump_uuid!(account_id)

    results =
      Repo.query!(
        """
        SELECT r2.id, r2.name, 1 - (r1.embedding <=> r2.embedding) AS similarity
        FROM recipes r1
        CROSS JOIN recipes r2
        WHERE r1.id = $1
          AND r2.id != $1
          AND r2.account_id = $2
          AND r1.embedding IS NOT NULL
          AND r2.embedding IS NOT NULL
        ORDER BY r1.embedding <=> r2.embedding
        LIMIT $3
        """,
        [recipe_uuid, account_uuid, limit]
      )

    Enum.map(results.rows, fn [id, name, similarity] ->
      %{recipe_id: load_uuid!(id), name: name, similarity: similarity}
    end)
  end

  # Private helpers

  defp keyword_search(query, account_id, limit) do
    search_term = "%#{query}%"
    account_uuid = dump_uuid!(account_id)

    results =
      Repo.query!(
        """
        SELECT id, name,
          CASE
            WHEN LOWER(name) = LOWER($1) THEN 1.0
            WHEN LOWER(name) LIKE LOWER($2) THEN 0.8
            WHEN LOWER(description) LIKE LOWER($2) THEN 0.5
            ELSE 0.3
          END AS relevance
        FROM recipes
        WHERE account_id = $3
          AND (LOWER(name) LIKE LOWER($2) OR LOWER(description) LIKE LOWER($2))
        ORDER BY relevance DESC
        LIMIT $4
        """,
        [query, search_term, account_uuid, limit]
      )

    Enum.map(results.rows, fn [id, name, relevance] ->
      # Convert Decimal to float for arithmetic operations
      similarity =
        if is_struct(relevance, Decimal), do: Decimal.to_float(relevance), else: relevance

      %{recipe_id: load_uuid!(id), name: name, similarity: similarity}
    end)
  end

  defp combine_results(keyword_results, semantic_results, kw_weight, sem_weight, limit) do
    scores =
      keyword_results
      |> Enum.reduce(%{}, fn result, acc ->
        Map.update(acc, result.recipe_id, {result.similarity, 0.0}, fn {_kw, sem} ->
          {result.similarity, sem}
        end)
      end)

    scores =
      Enum.reduce(semantic_results, scores, fn result, acc ->
        Map.update(acc, result.recipe_id, {0.0, result.similarity}, fn {kw, _sem} ->
          {kw, result.similarity}
        end)
      end)

    # Build name lookup from both result sets
    name_lookup =
      (keyword_results ++ semantic_results)
      |> Map.new(fn r -> {r.recipe_id, r.name} end)

    scores
    |> Enum.map(fn {recipe_id, {kw_score, sem_score}} ->
      combined = kw_score * kw_weight + sem_score * sem_weight

      %{
        recipe_id: recipe_id,
        name: Map.get(name_lookup, recipe_id),
        similarity: combined
      }
    end)
    |> Enum.sort_by(& &1.similarity, :desc)
    |> Enum.take(limit)
  end

  # UUID conversion helpers for raw Postgrex queries.
  # Postgrex expects UUIDs as 16-byte binaries, not strings.

  defp dump_uuid!(uuid) when is_binary(uuid) do
    Ecto.UUID.dump!(uuid)
  end

  defp load_uuid!(binary) when is_binary(binary) do
    Ecto.UUID.load!(binary)
  end
end
