defmodule GroceryPlanner.AiClient do
  @moduledoc """
  Client for the GroceryPlanner AI Python Service.

  Handles communication with the sidecar service for:
  - Categorization
  - Receipt Extraction
  - Embeddings
  - Async Job Management
  """

  require Logger

  @default_url "http://localhost:8000"

  @doc """
  Check if the AI service is healthy and responding.

  Calls `/health/ready` on the Python sidecar and returns the readiness payload.
  Returns `{:ok, body}` on 200, `{:error, reason}` otherwise.
  """
  def health_check(opts \\ []) do
    Req.get(client(opts), url: "/health/ready", receive_timeout: 5_000, retry: false)
    |> handle_response()
  end

  @doc """
  Predicts the category for a grocery item.
  """
  def categorize_item(item_name, candidate_labels, context, opts \\ []) do
    payload = %{
      item_name: item_name,
      candidate_labels: candidate_labels
    }

    post("/api/v1/categorize", payload, "categorization", context, opts)
  end

  @doc """
  Predicts categories for a batch of grocery items.
  """
  def categorize_batch(items, candidate_labels, context, opts \\ []) do
    payload = %{
      items: items,
      candidate_labels: candidate_labels
    }

    post("/api/v1/categorize-batch", payload, "categorization_batch", context, opts)
  end

  @doc """
  Extracts items from a receipt image (Base64).
  """
  def extract_receipt(image_base64, context, opts \\ []) do
    payload = %{
      image_base64: image_base64
    }

    post("/api/v1/extract-receipt", payload, "extraction", context, opts)
  end

  @doc """
  Generates an embedding for the given text.
  Wraps the text in the batch format expected by the Python service.
  """
  def generate_embedding(text, context, opts \\ []) do
    generate_embeddings([%{id: "1", text: text}], context, opts)
  end

  @doc """
  Generates embeddings for the given texts.
  Each text should be a map with :id and :text keys.

  Note: The embed endpoints use a flat request schema (EmbedRequest)
  with `texts` at the top level, NOT the BaseRequest envelope used by
  categorization and extraction endpoints.
  """
  def generate_embeddings(texts, _context, opts \\ []) do
    request_body = %{
      version: "1.0",
      request_id: "req_#{Ecto.UUID.generate()}",
      texts: texts
    }

    Req.post(client(opts), url: "/api/v1/embed", json: request_body)
    |> handle_response()
  end

  @doc """
  Generates embeddings for a batch of texts with configurable batch size.
  Each text should be a map with :id and :text keys.

  Note: The embed batch endpoint uses a flat request schema (EmbedBatchRequest)
  with `texts` and `batch_size` at the top level.
  """
  def generate_embeddings_batch(texts, _context, opts \\ []) do
    {batch_size, req_opts} = Keyword.pop(opts, :batch_size, 32)

    request_body = %{
      version: "1.0",
      request_id: "req_#{Ecto.UUID.generate()}",
      texts: texts,
      batch_size: batch_size
    }

    Req.post(client(req_opts), url: "/api/v1/embed/batch", json: request_body)
    |> handle_response()
  end

  # --- Internal Helpers ---

  defp post(url, payload, feature, context, opts) do
    request_body = %{
      request_id: "req_#{Ecto.UUID.generate()}",
      tenant_id: context.tenant_id,
      user_id: context.user_id,
      feature: feature,
      payload: payload
    }

    Req.post(client(opts), url: url, json: request_body)
    |> handle_response()
  end

  defp client(opts) do
    base_url = Application.get_env(:grocery_planner, :ai_service_url) || @default_url

    # In test env, merge global test plug config so LiveView internal calls
    # (which don't pass plug: explicitly) still hit Req.Test stubs.
    # Per-call opts override global config via Keyword.merge order.
    global_opts =
      case Application.get_env(:grocery_planner, :ai_client_opts) do
        nil -> []
        config when is_list(config) -> config
        _ -> []
      end

    merged_opts = Keyword.merge(global_opts, opts)

    Req.new(base_url: base_url)
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_option(:receive_timeout, 60_000)
    |> attach_otel_propagation()
    |> Req.merge(merged_opts)
  end

  defp attach_otel_propagation(req) do
    if Code.ensure_loaded?(OpentelemetryReq) do
      req
      |> Req.Request.register_options([:path_params])
      |> Req.Request.put_option(:path_params, %{})
      |> OpentelemetryReq.attach(propagate_trace_ctx: true)
    else
      req
    end
  end

  # Classify responses so callers can choose snooze/cancel/retry rather than
  # treating every failure identically (AI-006 §4a). The mapping is the
  # prerequisite for Arc 2's failure taxonomy (§4b):
  #
  #   transport error / 502 / 503 -> {:error, :unavailable}      (sidecar down)
  #   4xx                         -> {:error, {:bad_input, d}}   (this image/request is bad)
  #   other 5xx                   -> {:error, {:transient, d}}   (retry may help)
  #
  # `detail` is the decoded response body so the caller can log/inspect it.
  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) when status in [502, 503] do
    Logger.error("AI Service unavailable (#{status})")
    {:error, :unavailable}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status >= 400 and status < 500 do
    Logger.error("AI Service rejected request (#{status})")
    {:error, {:bad_input, body}}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("AI Service transient error (#{status})")
    {:error, {:transient, body}}
  end

  defp handle_response({:error, reason}) do
    Logger.error("AI Service connection error: #{inspect(reason)}")
    {:error, :unavailable}
  end
end
