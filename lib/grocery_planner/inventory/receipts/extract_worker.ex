defmodule GroceryPlanner.Inventory.Receipts.ExtractWorker do
  @moduledoc """
  Stage 1 of the receipt pipeline: call the OCR sidecar and record the raw
  extraction (AI-006 §1). This is the only stage that talks to the sidecar, so it
  owns the §4b failure taxonomy:

    * `:ok` from `AiClient` → write metadata + `raw_extraction`, advance to
      `:extracted`, enqueue persist.
    * `{:error, :unavailable}` (sidecar down / 502 / 503) → set `condition:
      :awaiting_ai` and **snooze** (does not burn the retry budget); after ~2h of
      snoozing, give up with `{:cancel, _}` so it dead-letters and alerts (§4c).
    * `{:error, {:bad_input, _}}` (4xx — a bad image) → `mark_failed` and
      `{:cancel, _}`; it can never succeed on retry.
    * `{:error, {:transient, _}}` (other 5xx) → `{:error, _}` → retry with the
      capped backoff.

  Idempotent: if `stage` has already reached `:extracted`, the sidecar is never
  called again (§3) — a commit-then-crash retry no-ops.
  """
  use Oban.Worker, queue: :ai_jobs, max_attempts: 5

  require Logger

  alias GroceryPlanner.AiClient
  alias GroceryPlanner.Inventory.Receipt
  alias GroceryPlanner.Inventory.ReceiptProcessor
  alias GroceryPlanner.Inventory.Receipts.Pipeline

  @snooze_seconds 60
  # ~2h of snoozing (@snooze_seconds * @max_snoozes) before giving up, so a
  # week-long outage doesn't hide silently (§4c belt-and-braces).
  @max_snoozes 120

  @impl Oban.Worker
  def backoff(job), do: Pipeline.backoff(job)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"receipt_id" => id}} = job) do
    case Pipeline.load_receipt(id) do
      {:ok, receipt} ->
        if Pipeline.stage_reached?(receipt, :extracted) do
          # Postcondition already met — retry never re-extracts (§3).
          :ok
        else
          do_extract(receipt, job)
        end

      {:error, :not_found} ->
        {:cancel, "receipt #{id} not found"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_extract(receipt, job) do
    case read_image(receipt) do
      {:ok, image_base64} ->
        context = %{tenant_id: receipt.account_id, user_id: "system"}

        case AiClient.extract_receipt(image_base64, context) do
          {:ok, body} ->
            handle_success(receipt, body)

          {:error, :unavailable} ->
            handle_unavailable(receipt, job)

          {:error, {:bad_input, detail}} ->
            handle_bad_input(receipt, detail)

          {:error, {:transient, detail}} ->
            {:error, "sidecar transient error: #{inspect(detail)}"}
        end

      {:error, reason} ->
        # A missing/unreadable file never recovers on retry.
        mark_failed(receipt, "could not read receipt file: #{inspect(reason)}")
        {:cancel, "file read failed"}
    end
  end

  defp handle_success(receipt, body) do
    payload = body["payload"] || %{}

    attrs =
      payload
      |> ReceiptProcessor.parse_receipt_attrs()
      |> Map.put(:raw_extraction, payload)

    {:ok, updated} =
      Receipt.mark_extracted(receipt, attrs, authorize?: false, tenant: receipt.account_id)

    Pipeline.enqueue_persist(updated.id)
    Pipeline.broadcast(updated)
    :ok
  end

  defp handle_unavailable(receipt, %Oban.Job{attempt: attempt}) do
    if attempt <= @max_snoozes do
      # Visible outage signal in the product, not just the queue (§4c). Snooze
      # keeps the retry budget intact (it bumps max_attempts in lockstep).
      case Receipt.mark_awaiting_ai(receipt, authorize?: false, tenant: receipt.account_id) do
        {:ok, updated} -> Pipeline.broadcast(updated)
        _ -> :ok
      end

      {:snooze, @snooze_seconds}
    else
      mark_failed(receipt, "AI sidecar unavailable after ~2h of retries")
      {:cancel, "sidecar unavailable > 2h"}
    end
  end

  defp handle_bad_input(receipt, detail) do
    mark_failed(receipt, "sidecar rejected the receipt image: #{inspect(detail)}")
    {:cancel, "bad input"}
  end

  defp mark_failed(receipt, reason) do
    case Receipt.mark_failed(receipt, %{failure_reason: reason},
           authorize?: false,
           tenant: receipt.account_id
         ) do
      {:ok, updated} ->
        Pipeline.broadcast(updated)

      {:error, error} ->
        Logger.error("Failed to mark receipt #{receipt.id} failed: #{inspect(error)}")
    end
  end

  # Reads the stored receipt image and returns it base64-encoded.
  defp read_image(receipt) do
    path = resolve_file_path(receipt.file_path)

    case File.read(path) do
      {:ok, data} -> {:ok, Base.encode64(data)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_file_path(path) when is_binary(path) do
    if File.exists?(path) do
      path
    else
      priv_dir = :code.priv_dir(:grocery_planner) |> to_string()

      candidates = [
        Path.join([priv_dir, "static", String.trim_leading(path, "/")]),
        Path.join([priv_dir, "static", "uploads", "receipts", Path.basename(path)]),
        Path.join([priv_dir, "uploads", "receipts", Path.basename(path)]),
        Path.join([priv_dir, "static", "uploads", Path.basename(path)])
      ]

      Enum.find(candidates, path, &File.exists?/1)
    end
  end
end
