defmodule GroceryPlanner.AI.Categorizer do
  @moduledoc """
  Client for the AI categorization service.

  Provides functions for predicting grocery item categories using
  zero-shot classification. Includes confidence level mapping and
  feedback logging for corrections.
  """

  require Logger

  alias GroceryPlanner.AiClient

  # Fixed category labels as per spec
  @default_candidate_labels [
    "Dairy",
    "Produce",
    "Meat & Seafood",
    "Bakery",
    "Frozen",
    "Pantry",
    "Beverages",
    "Snacks",
    "Household",
    "Other"
  ]

  @type confidence_level :: :high | :medium | :low
  @type prediction :: %{
          category: String.t(),
          confidence: float(),
          confidence_level: confidence_level()
        }
  @type batch_result :: %{
          id: String.t(),
          name: String.t(),
          category: String.t(),
          confidence: float(),
          confidence_level: confidence_level()
        }

  @doc """
  Checks if AI categorization is enabled via feature flag.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:grocery_planner, :features, [])
    |> Keyword.get(:ai_categorization, false)
  end

  @doc """
  Predicts the category for a single item name.

  Returns `{:ok, prediction}` or `{:error, reason}`.
  If categorization is disabled, returns `{:error, :disabled}`.

  ## Options

    * `:candidate_labels` - List of category labels to consider (default: fixed list)
    * `:timeout` - Request timeout in milliseconds (default: 3000)

  ## Examples

      iex> Categorizer.predict("whole milk")
      {:ok, %{category: "Dairy", confidence: 0.94, confidence_level: :high}}

      iex> Categorizer.predict("unknown item", candidate_labels: ["A", "B"])
      {:ok, %{category: "A", confidence: 0.45, confidence_level: :low}}
  """
  @spec predict(String.t(), Keyword.t()) :: {:ok, prediction()} | {:error, term()}
  def predict(item_name, opts \\ []) do
    if enabled?() do
      do_predict(item_name, opts)
    else
      {:error, :disabled}
    end
  end

  defp do_predict(item_name, opts) do
    candidate_labels = Keyword.get(opts, :candidate_labels, @default_candidate_labels)
    timeout = Keyword.get(opts, :timeout, 3000)

    context = %{
      tenant_id: opts[:tenant_id] || "system",
      user_id: opts[:user_id] || "system"
    }

    # Forward plug option to AiClient
    client_opts = [receive_timeout: timeout]

    client_opts =
      if opts[:plug], do: Keyword.put(client_opts, :plug, opts[:plug]), else: client_opts

    case AiClient.categorize_item(item_name, candidate_labels, context, client_opts) do
      {:ok, response} ->
        normalize_prediction(response)

      {:error, reason} ->
        Logger.warning("Categorization failed for '#{item_name}': #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Predicts categories for multiple items in batch.

  Returns `{:ok, [batch_result]}` or `{:error, reason}`.
  Processing time should be under 2 seconds for up to 50 items.

  ## Options

    * `:candidate_labels` - List of category labels to consider
    * `:timeout` - Request timeout in milliseconds (default: 5000)

  ## Examples

      iex> Categorizer.predict_batch(["milk", "bananas", "chicken"])
      {:ok, [
        %{id: "1", name: "milk", category: "Dairy", confidence: 0.94, confidence_level: :high},
        %{id: "2", name: "bananas", category: "Produce", confidence: 0.91, confidence_level: :high},
        %{id: "3", name: "chicken", category: "Meat & Seafood", confidence: 0.88, confidence_level: :high}
      ]}
  """
  @spec predict_batch([String.t()], Keyword.t()) :: {:ok, [batch_result()]} | {:error, term()}
  def predict_batch(item_names, opts \\ []) when is_list(item_names) do
    cond do
      not enabled?() ->
        {:error, :disabled}

      length(item_names) > 50 ->
        {:error, :batch_too_large}

      true ->
        do_predict_batch(item_names, opts)
    end
  end

  defp do_predict_batch(item_names, opts) do
    candidate_labels = Keyword.get(opts, :candidate_labels, @default_candidate_labels)
    timeout = Keyword.get(opts, :timeout, 5000)

    context = %{
      tenant_id: opts[:tenant_id] || "system",
      user_id: opts[:user_id] || "system"
    }

    items =
      Enum.with_index(item_names, 1)
      |> Enum.map(fn {name, idx} -> %{id: to_string(idx), name: name} end)

    # Forward plug option to AiClient
    client_opts = [receive_timeout: timeout]

    client_opts =
      if opts[:plug], do: Keyword.put(client_opts, :plug, opts[:plug]), else: client_opts

    case AiClient.categorize_batch(items, candidate_labels, context, client_opts) do
      {:ok, response} ->
        normalize_batch(response)

      {:error, reason} ->
        Logger.warning("Batch categorization failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Maps a confidence score to a confidence level.

  ## Levels

    * `:high` - confidence >= 0.80
    * `:medium` - confidence >= 0.50 and < 0.80
    * `:low` - confidence < 0.50

  ## Examples

      iex> Categorizer.confidence_level(0.94)
      :high

      iex> Categorizer.confidence_level(0.65)
      :medium

      iex> Categorizer.confidence_level(0.30)
      :low
  """
  @spec confidence_level(float()) :: confidence_level()
  def confidence_level(confidence) when is_float(confidence) do
    cond do
      confidence >= 0.80 -> :high
      confidence >= 0.50 -> :medium
      true -> :low
    end
  end

  @doc """
  Returns the default candidate labels for categorization.
  """
  @spec default_candidate_labels() :: [String.t()]
  def default_candidate_labels, do: @default_candidate_labels

  # Private functions
  #
  # Anti-corruption layer for the AI sidecar's JSON-decoded (string-keyed)
  # responses. These normalizers never raise: they coerce values into the
  # public prediction/batch_result shapes and default anything malformed.
  # confidence_level is ALWAYS derived from the normalized confidence float
  # via the public confidence_level/1, never read from the server payload.

  defp normalize_prediction(response) do
    payload = as_map(Map.get(response, "payload", %{}))
    category = Map.get(payload, "category")
    confidence = normalize_confidence(Map.get(payload, "confidence"))

    if is_binary(category) and category != "" do
      {:ok,
       %{
         category: category,
         confidence: confidence,
         confidence_level: confidence_level(confidence)
       }}
    else
      {:error, :invalid_prediction}
    end
  end

  defp normalize_batch(response) do
    payload = as_map(Map.get(response, "payload", %{}))
    predictions = Map.get(payload, "predictions")

    if is_list(predictions) do
      {:ok, Enum.map(predictions, &normalize_batch_prediction/1)}
    else
      {:error, :invalid_batch_response}
    end
  end

  defp normalize_batch_prediction(pred) when is_map(pred) do
    confidence = normalize_confidence(Map.get(pred, "confidence"))

    %{
      id: Map.get(pred, "id"),
      name: Map.get(pred, "name"),
      category: Map.get(pred, "predicted_category"),
      confidence: confidence,
      confidence_level: confidence_level(confidence)
    }
  end

  defp normalize_batch_prediction(_pred) do
    %{id: nil, name: nil, category: nil, confidence: 0.0, confidence_level: :low}
  end

  defp normalize_confidence(confidence) when is_float(confidence), do: confidence
  defp normalize_confidence(confidence) when is_integer(confidence), do: confidence * 1.0
  defp normalize_confidence(_confidence), do: 0.0

  defp as_map(map) when is_map(map), do: map
  defp as_map(_other), do: %{}
end
