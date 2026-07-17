defmodule GroceryPlanner.Inventory.ReceiptProcessor do
  @moduledoc """
  Handles receipt upload, processing, and item extraction.
  Coordinates file storage, OCR service calls, and result persistence.
  """

  require Logger

  alias GroceryPlanner.Inventory
  alias GroceryPlanner.Inventory.Receipts.Pipeline

  defp upload_dir do
    Application.get_env(
      :grocery_planner,
      :receipt_upload_dir,
      Path.join([
        :code.priv_dir(:grocery_planner) |> to_string(),
        "static",
        "uploads",
        "receipts"
      ])
    )
  end

  @doc """
  Uploads a receipt file, stores it locally, and queues background processing.
  Returns {:ok, receipt} or {:error, reason}.
  """
  def upload(file_params, _user, account, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    with {:ok, file_path, file_hash, file_size, mime_type} <- store_file(file_params),
         :ok <- maybe_check_duplicate(file_hash, account.id, force),
         {:ok, receipt} <- create_receipt(file_path, file_hash, file_size, mime_type, account) do
      # Kick off the staged pipeline directly (extract -> persist -> match ->
      # categorise). No cron latency; the reconciler is only a safety net.
      Pipeline.enqueue_extract(receipt.id)
      {:ok, receipt}
    end
  end

  @doc """
  Stores an uploaded file to the local filesystem.
  file_params should have :path (temp path) and :client_name (original filename).
  Returns {:ok, dest_path, sha256_hash, file_size, mime_type}.
  """
  def store_file(%{path: temp_path, client_name: filename}) do
    # Ensure upload directory exists
    File.mkdir_p!(upload_dir())

    # Generate unique filename
    ext = Path.extname(filename)
    unique_name = "#{Ecto.UUID.generate()}#{ext}"
    dest_path = Path.join(upload_dir(), unique_name)

    # Compute hash before moving
    file_hash = compute_file_hash(temp_path)
    %{size: file_size} = File.stat!(temp_path)
    mime_type = detect_mime_type(filename)

    # Copy file to uploads directory
    File.cp!(temp_path, dest_path)

    {:ok, dest_path, file_hash, file_size, mime_type}
  rescue
    e ->
      Logger.error("Failed to store receipt file: #{inspect(e)}")
      {:error, :file_storage_failed}
  end

  @doc """
  Computes SHA256 hash of a file for duplicate detection.
  """
  def compute_file_hash(file_path) do
    File.stream!(file_path, 2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp maybe_check_duplicate(_file_hash, _account_id, true = _force), do: :ok

  defp maybe_check_duplicate(file_hash, account_id, _force),
    do: check_duplicate(file_hash, account_id)

  def check_duplicate(file_hash, account_id) do
    # `find_by_hash` is a `get?: true` interface, so a *miss* would otherwise come
    # back as `{:error, NotFound}` — indistinguishable from a real query failure.
    # `not_found_error?: false` splits the two: absent => {:ok, nil}, genuine
    # failure => {:error, _}, which is what lets us fail closed on the latter.
    case Inventory.find_receipt_by_hash(file_hash,
           authorize?: false,
           tenant: account_id,
           not_found_error?: false
         ) do
      {:ok, nil} -> :ok
      {:ok, existing} -> {:error, {:duplicate_receipt, existing}}
      # Fail closed (cxk): if we cannot determine whether this is a duplicate we
      # must NOT silently admit it — a receipt feeds inventory and spend counts,
      # so a missed duplicate double-counts. Block the upload; the caller can
      # retry, or override via `force: true`.
      {:error, reason} -> {:error, {:duplicate_check_failed, reason}}
    end
  rescue
    # Some query failures (e.g. a malformed tenant) raise rather than return an
    # error tuple. Same posture: fail closed, never fall through to allow.
    e -> {:error, {:duplicate_check_failed, e}}
  end

  @doc """
  Parses the flat extraction payload (`schemas.py ExtractionResponsePayload`,
  the only shape production emits) into Receipt attributes for the `mark_extracted`
  milestone. Pure — no DB, never raises. Consumed by the extract stage worker.
  """
  def parse_receipt_attrs(payload) when is_map(payload) do
    currency = payload["currency"]

    %{
      merchant_name: parse_merchant(payload),
      purchase_date: parse_purchase_date(payload),
      total_amount: to_money(payload["total"], currency),
      raw_ocr_text: payload["raw_ocr_text"],
      extraction_confidence: payload["overall_confidence"],
      model_version: payload["model_version"],
      processing_time_ms: parse_ms(payload["processing_time_ms"]),
      processed_at: DateTime.utc_now()
    }
  end

  @doc """
  Parses the flat payload's line items into ReceiptItem create attributes, one per
  item, keyed by `line_no` (0-based position). Pure — no DB. Consumed by the
  persist stage worker, which bulk-creates them in a single transaction; `line_no`
  is what makes that persist idempotent (AI-006 §3).
  """
  def parse_item_attrs_list(payload) when is_map(payload) do
    currency = payload["currency"]

    (payload["items"] || [])
    |> Enum.with_index()
    |> Enum.map(fn {item, line_no} -> parse_item_attrs(item, currency, line_no) end)
  end

  @doc """
  Creates inventory entries from confirmed receipt items.
  """
  def create_inventory_entries(receipt, opts \\ []) do
    default_storage_location_id = opts[:storage_location_id]
    item_options = opts[:item_options] || %{}

    case Inventory.list_receipt_items_for_receipt(receipt.id,
           authorize?: false,
           tenant: receipt.account_id
         ) do
      {:ok, receipt_items} ->
        results =
          receipt_items
          |> Enum.filter(fn item -> item.status == :confirmed end)
          |> Enum.map(fn item ->
            item_opts = Map.get(item_options, item.id, %{})
            slid = item_opts[:storage_location_id] || default_storage_location_id
            ubd = item_opts[:use_by_date]
            create_entry_from_item(item, slid, ubd, receipt)
          end)

        {:ok, results}

      error ->
        error
    end
  end

  @doc """
  Ensures a GroceryItem exists for the given receipt item.
  If grocery_item_id is set, returns it. Otherwise creates a new GroceryItem
  or finds an existing one by name.
  Returns {:ok, grocery_item_id} or {:error, reason}.
  """
  def ensure_grocery_item(item, account_id, opts \\ []) do
    # If grocery_item_id already exists, use it
    if item.grocery_item_id do
      {:ok, item.grocery_item_id}
    else
      # Extract name and unit from item
      name = item.final_name || item.raw_name
      default_unit = item.final_unit || item.unit

      # Try to create new GroceryItem
      case Inventory.create_grocery_item(
             account_id,
             %{name: name, default_unit: default_unit},
             Keyword.merge([authorize?: false, tenant: account_id], opts)
           ) do
        {:ok, grocery_item} ->
          # Update the ReceiptItem to link it
          Inventory.update_receipt_item(
            item,
            %{grocery_item_id: grocery_item.id},
            authorize?: false,
            tenant: account_id
          )

          {:ok, grocery_item.id}

        {:error, error} ->
          # If creation failed, try to look up existing item by name
          # (handles duplicate name errors and other validation failures)
          case Inventory.get_item_by_name(name, authorize?: false, tenant: account_id) do
            {:ok, existing_item} ->
              # Update the ReceiptItem to link it
              Inventory.update_receipt_item(
                item,
                %{grocery_item_id: existing_item.id},
                authorize?: false,
                tenant: account_id
              )

              {:ok, existing_item.id}

            {:error, _} ->
              # If lookup also fails, return the original creation error
              {:error, error}
          end
      end
    end
  end

  @doc """
  Batch-categorizes extracted receipt items using AI.
  Returns {:ok, predictions} or {:error, reason}.
  Non-critical - failures are logged but don't affect receipt processing.
  """
  def categorize_extracted_items(receipt, account_id) do
    alias GroceryPlanner.AI.Categorizer

    with {:ok, items} <-
           Inventory.list_receipt_items_for_receipt(receipt.id,
             authorize?: false,
             tenant: account_id
           ) do
      item_names = Enum.map(items, & &1.raw_name)

      if item_names == [] do
        {:ok, []}
      else
        opts = [
          tenant_id: account_id,
          user_id: "system"
        ]

        case Categorizer.predict_batch(item_names, opts) do
          {:ok, predictions} ->
            Logger.info(
              "Batch categorized #{length(predictions)} receipt items for receipt #{receipt.id}"
            )

            {:ok, predictions}

          {:error, reason} ->
            Logger.warning(
              "Batch categorization failed for receipt #{receipt.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
      end
    end
  rescue
    e ->
      Logger.warning("Batch categorization error for receipt #{receipt.id}: #{inspect(e)}")
      {:error, :categorization_failed}
  end

  # --- Private Helpers ---

  # Flat wire shape: merchant is a plain string (ExtractionResponsePayload.merchant).
  defp parse_merchant(%{"merchant" => name}) when is_binary(name), do: name
  defp parse_merchant(_), do: nil

  # Flat wire shape: date is an ISO-8601 string (ExtractionResponsePayload.date).
  defp parse_purchase_date(%{"date" => date_string}) when is_binary(date_string) do
    parse_date(date_string)
  end

  defp parse_purchase_date(_), do: nil

  # Flat wire shape: each item is an ExtractedItem (name, quantity, unit, price,
  # confidence). Currency comes from the receipt-level payload, not per item.
  # Returns a plain attribute map (with line_no) for bulk create — no DB.
  defp parse_item_attrs(item, currency, line_no) do
    %{
      raw_name: item["name"] || "Unknown",
      final_name: item["name"],
      quantity: parse_decimal(item["quantity"]),
      unit: item["unit"],
      unit_price: to_money(item["price"], currency),
      total_price: to_money(item["price"], currency, item["quantity"]),
      confidence: item["confidence"],
      line_no: line_no
    }
  end

  defp create_receipt(file_path, file_hash, file_size, mime_type, account) do
    Inventory.create_receipt(
      account.id,
      %{
        file_path: file_path,
        file_hash: file_hash,
        file_size: file_size,
        mime_type: mime_type
      },
      authorize?: false,
      tenant: account.id
    )
  end

  defp create_entry_from_item(item, storage_location_id, use_by_date, receipt) do
    # Ensure GroceryItem exists (create if needed)
    with {:ok, grocery_item_id} <- ensure_grocery_item(item, receipt.account_id) do
      attrs = %{
        quantity: item.final_quantity || item.quantity || Decimal.new(1),
        unit: item.final_unit || item.unit,
        purchase_date: receipt.purchase_date || Date.utc_today(),
        purchase_price: item.total_price
      }

      attrs =
        if storage_location_id,
          do: Map.put(attrs, :storage_location_id, storage_location_id),
          else: attrs

      attrs =
        if use_by_date,
          do: Map.put(attrs, :use_by_date, use_by_date),
          else: attrs

      Inventory.create_inventory_entry(
        receipt.account_id,
        grocery_item_id,
        attrs,
        authorize?: false,
        tenant: receipt.account_id
      )
    end
  end

  defp parse_date(nil), do: nil

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  # Coerce a wire amount + the payload's currency into a Money, or nil. Never
  # raises and never invents a currency (grocery_planner-83o): a missing/blank
  # currency yields nil rather than a hardcoded default. Wire amounts arrive as
  # JSON numbers — floats MUST go through Money.from_float/2, because Money.new/2
  # refuses floats and *returns an error tuple* (it does not raise), so a bare
  # rescue would let that tuple leak into the Money attribute.
  defp to_money(amount, currency)
       when is_number(amount) and is_binary(currency) and currency != "" do
    result =
      if is_float(amount),
        do: Money.from_float(amount, currency),
        else: Money.new(amount, currency)

    case result do
      %Money{} = money -> money
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp to_money(_amount, _currency), do: nil

  # Line total from a per-item price and quantity.
  defp to_money(amount, currency, quantity) when is_number(amount) and is_number(quantity) do
    to_money(amount * quantity, currency)
  end

  defp to_money(amount, currency, _quantity), do: to_money(amount, currency)

  # processing_time_ms crosses the wire as a float (milliseconds); the Receipt
  # column is an integer.
  defp parse_ms(n) when is_number(n), do: round(n)
  defp parse_ms(_), do: nil

  defp parse_decimal(nil), do: nil
  defp parse_decimal(val) when is_number(val), do: Decimal.new("#{val}")

  defp parse_decimal(val) when is_binary(val) do
    case Decimal.parse(val) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp detect_mime_type(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".heic" -> "image/heic"
      ".pdf" -> "application/pdf"
      _ -> "application/octet-stream"
    end
  end
end
