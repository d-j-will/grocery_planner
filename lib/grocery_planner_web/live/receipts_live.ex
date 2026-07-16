defmodule GroceryPlannerWeb.ReceiptsLive do
  @moduledoc """
  LiveView for receipt scanning and OCR processing.

  Allows users to:
  - Upload receipt images
  - Track OCR processing status
  - Review and edit extracted items
  - Create inventory entries from confirmed items
  """
  use GroceryPlannerWeb, :live_view

  on_mount({GroceryPlannerWeb.Auth, :require_authenticated_user})

  alias GroceryPlanner.Inventory
  alias GroceryPlanner.Inventory.ReceiptProcessor

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Receipts")
      |> assign(:receipts, [])
      |> assign(:selected_receipt, nil)
      |> assign(:show_upload, false)
      |> assign(:uploading, false)
      |> allow_upload(:receipt_image,
        accept: ~w(.jpg .jpeg .png .webp),
        max_entries: 1,
        max_file_size: 10_000_000,
        auto_upload: true
      )

    socket = if connected?(socket), do: load_receipts(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params do
        %{"id" => id} ->
          load_receipt_detail(socket, id)

        _ ->
          assign(socket, :selected_receipt, nil)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_account={@current_account}
    >
      <div class="px-4 py-10 sm:px-6 lg:px-8">
        <div class="mb-8 flex items-center justify-between">
          <div>
            <h1 class="text-4xl font-bold text-base-content">Receipt Scanner</h1>
            <p class="mt-2 text-lg text-base-content/70">
              Upload receipts to automatically extract items
            </p>
          </div>
          <button
            phx-click="toggle_upload"
            class="btn btn-primary"
          >
            <.icon name="hero-camera" class="w-5 h-5 mr-2" /> Scan Receipt
          </button>
        </div>

        <%= if @show_upload do %>
          <.upload_panel uploads={@uploads} uploading={@uploading} />
        <% end %>

        <%= if @selected_receipt do %>
          <.receipt_detail
            receipt={@selected_receipt}
            current_account={@current_account}
            current_user={@current_user}
          />
        <% else %>
          <.receipts_list receipts={@receipts} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # Upload panel component
  attr :uploads, :map, required: true
  attr :uploading, :boolean, default: false

  defp upload_panel(assigns) do
    ~H"""
    <div class="mb-8 bg-base-100 rounded-box shadow-sm border border-base-200 p-6">
      <h2 class="text-lg font-semibold mb-4">Upload Receipt</h2>

      <form id="upload-form" phx-submit="save_upload" phx-change="validate_upload">
        <div class="border-2 border-dashed border-base-300 rounded-lg p-8 text-center hover:border-primary transition-colors">
          <.live_file_input upload={@uploads.receipt_image} class="hidden" />

          <%= if Enum.empty?(@uploads.receipt_image.entries) do %>
            <label for={@uploads.receipt_image.ref} class="cursor-pointer">
              <.icon name="hero-cloud-arrow-up" class="w-12 h-12 mx-auto text-base-content/40" />
              <p class="mt-2 text-sm text-base-content/70">
                Click to upload or drag and drop
              </p>
              <p class="text-xs text-base-content/50">
                JPG, PNG or WebP up to 10MB
              </p>
            </label>
          <% else %>
            <%= for entry <- @uploads.receipt_image.entries do %>
              <div class="flex items-center justify-center gap-4">
                <.live_img_preview entry={entry} class="h-32 rounded-lg" />
                <div class="text-left">
                  <p class="font-medium">{entry.client_name}</p>
                  <p class="text-sm text-base-content/70">
                    {format_bytes(entry.client_size)}
                  </p>
                  <progress class="progress progress-primary w-48" value={entry.progress} max="100" />
                </div>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="btn btn-ghost btn-sm"
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>

              <%= for err <- upload_errors(@uploads.receipt_image, entry) do %>
                <p class="text-error text-sm mt-2">{error_to_string(err)}</p>
              <% end %>
            <% end %>
          <% end %>
        </div>

        <%= for err <- upload_errors(@uploads.receipt_image) do %>
          <p class="text-error text-sm mt-2">{error_to_string(err)}</p>
        <% end %>

        <div class="mt-4 flex justify-end gap-2">
          <button type="button" phx-click="toggle_upload" class="btn btn-ghost">
            Cancel
          </button>
          <button
            type="submit"
            disabled={
              Enum.empty?(@uploads.receipt_image.entries) || @uploading ||
                not Enum.all?(@uploads.receipt_image.entries, &(&1.progress == 100))
            }
            class="btn btn-primary"
          >
            <%= if @uploading do %>
              <span class="loading loading-spinner loading-sm"></span> Processing...
            <% else %>
              <.icon name="hero-sparkles" class="w-4 h-4 mr-2" /> Extract Items
            <% end %>
          </button>
        </div>
      </form>
    </div>
    """
  end

  # Receipts list component
  attr :receipts, :list, required: true

  defp receipts_list(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-box shadow-sm border border-base-200">
      <%= if Enum.empty?(@receipts) do %>
        <div class="p-12 text-center">
          <.icon name="hero-document-text" class="w-16 h-16 mx-auto text-base-content/20" />
          <h3 class="mt-4 text-lg font-medium text-base-content">No receipts yet</h3>
          <p class="mt-2 text-base-content/70">
            Upload a receipt to get started
          </p>
        </div>
      <% else %>
        <div class="divide-y divide-base-200">
          <%= for receipt <- @receipts do %>
            <div class="flex items-center gap-4 p-4 hover:bg-base-200/50 transition-colors">
              <.link
                patch={~p"/receipts/#{receipt.id}"}
                class="flex items-center gap-4 flex-1 min-w-0"
              >
                <div class="w-16 h-16 bg-base-200 rounded-lg flex items-center justify-center overflow-hidden">
                  <%= if receipt.file_path do %>
                    <img src={file_path_to_url(receipt.file_path)} class="w-full h-full object-cover" />
                  <% else %>
                    <.icon name="hero-document-text" class="w-8 h-8 text-base-content/40" />
                  <% end %>
                </div>

                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2">
                    <p class="font-medium truncate">
                      {receipt.merchant_name || "Unknown Merchant"}
                    </p>
                    <.status_badge receipt={receipt} />
                  </div>
                  <p class="text-sm text-base-content/70">
                    <%= if receipt.purchase_date do %>
                      {Calendar.strftime(receipt.purchase_date, "%B %d, %Y")}
                    <% else %>
                      {Calendar.strftime(receipt.created_at, "%B %d, %Y at %I:%M %p")}
                    <% end %>
                  </p>
                  <%= if is_list(receipt.receipt_items) and length(receipt.receipt_items) > 0 do %>
                    <p class="text-sm text-base-content/50">
                      {length(receipt.receipt_items)} items
                    </p>
                  <% end %>
                </div>

                <div class="text-right">
                  <%= if receipt.total_amount do %>
                    <p class="font-semibold">
                      {Money.to_string(receipt.total_amount)}
                    </p>
                  <% end %>
                </div>

                <.icon name="hero-chevron-right" class="w-5 h-5 text-base-content/40" />
              </.link>

              <button
                phx-click="delete_receipt"
                phx-value-id={receipt.id}
                data-confirm="Are you sure you want to delete this receipt?"
                class="btn btn-ghost btn-sm text-error"
                title="Delete receipt"
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Receipt detail component
  attr :receipt, :map, required: true
  attr :current_account, :map, required: true
  attr :current_user, :map, required: true

  defp receipt_detail(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-4">
        <.link patch={~p"/receipts"} class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4" /> Back
        </.link>
        <h2 class="text-2xl font-bold">
          {@receipt.merchant_name || "Receipt Details"}
        </h2>
        <.status_badge receipt={@receipt} />
        <button
          phx-click="delete_receipt"
          phx-value-id={@receipt.id}
          data-confirm="Are you sure you want to delete this receipt?"
          class="btn btn-ghost btn-sm text-error ml-auto"
        >
          <.icon name="hero-trash" class="w-4 h-4" /> Delete
        </button>
      </div>

      <%= cond do %>
        <% @receipt.condition == :failed -> %>
          <.error_state message={
            @receipt.failure_reason || "Failed to process receipt. Please try again."
          } />
        <% @receipt.condition == :awaiting_ai -> %>
          <.processing_state message="Waiting for the AI service..." />
        <% @receipt.stage in [:ready_for_review, :confirmed] -> %>
          <.review_panel receipt={@receipt} />
        <% true -> %>
          <.processing_state message="Extracting items from receipt..." />
      <% end %>
    </div>
    """
  end

  defp processing_state(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-box shadow-sm border border-base-200 p-12 text-center">
      <span class="loading loading-spinner loading-lg text-primary"></span>
      <p class="mt-4 text-lg font-medium">{@message}</p>
      <p class="text-base-content/70">This may take a few moments</p>
    </div>
    """
  end

  defp error_state(assigns) do
    ~H"""
    <div class="bg-error/10 rounded-box border border-error/20 p-8 text-center">
      <.icon name="hero-exclamation-triangle" class="w-12 h-12 mx-auto text-error" />
      <p class="mt-4 text-lg font-medium text-error">{@message}</p>
      <button phx-click="retry_processing" class="btn btn-error btn-outline mt-4">
        <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> Retry
      </button>
    </div>
    """
  end

  attr :receipt, :map, required: true

  defp review_panel(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
      <div class="bg-base-100 rounded-box shadow-sm border border-base-200 p-6">
        <h3 class="font-semibold mb-4">Receipt Image</h3>
        <%= if @receipt.file_path do %>
          <img src={file_path_to_url(@receipt.file_path)} class="w-full rounded-lg" />
        <% else %>
          <div class="bg-base-200 rounded-lg h-64 flex items-center justify-center">
            <.icon name="hero-photo" class="w-16 h-16 text-base-content/20" />
          </div>
        <% end %>

        <div class="mt-4 space-y-2">
          <%= if @receipt.purchase_date do %>
            <p class="text-sm">
              <span class="text-base-content/70">Date:</span>
              {Calendar.strftime(@receipt.purchase_date, "%B %d, %Y")}
            </p>
          <% end %>
          <%= if @receipt.total_amount do %>
            <p class="text-sm">
              <span class="text-base-content/70">Total:</span>
              <span class="font-semibold">{Money.to_string(@receipt.total_amount)}</span>
            </p>
          <% end %>
        </div>
      </div>

      <div class="bg-base-100 rounded-box shadow-sm border border-base-200 p-6">
        <div class="flex items-center justify-between mb-4">
          <h3 class="font-semibold">Extracted Items</h3>
          <span class="badge badge-ghost">
            {length(@receipt.receipt_items || [])} items
          </span>
        </div>

        <%= if Enum.empty?(@receipt.receipt_items || []) do %>
          <p class="text-base-content/70 text-center py-8">
            No items extracted
          </p>
        <% else %>
          <div class="space-y-3">
            <%= for {item, index} <- Enum.with_index(@receipt.receipt_items || []) do %>
              <div class="flex items-center gap-3 p-3 bg-base-200/50 rounded-lg">
                <div class="flex-1">
                  <p class="font-medium">{item.final_name || item.raw_name}</p>
                  <p class="text-sm text-base-content/70">
                    {item.final_quantity || item.quantity} {item.final_unit || item.unit}
                    <%= if item.unit_price do %>
                      · {Money.to_string(item.unit_price)}
                    <% end %>
                  </p>
                </div>
                <%= if item.confidence do %>
                  <.confidence_indicator value={item.confidence} />
                <% end %>
                <button
                  phx-click="remove_item"
                  phx-value-index={index}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if @receipt.stage in [:ready_for_review, :confirmed] do %>
          <div class="mt-6 flex gap-2">
            <button phx-click="add_to_inventory" class="btn btn-primary flex-1">
              <.icon name="hero-plus" class="w-4 h-4 mr-2" /> Add to Inventory
            </button>
            <button phx-click="discard_receipt" class="btn btn-ghost">
              Discard
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :receipt, :map, required: true

  defp status_badge(assigns) do
    # condition (how it's faring) wins over stage (where it got) for the badge —
    # a failed/awaiting receipt is what the user needs to see (AI-006 §2).
    {class, text} =
      case {assigns.receipt.condition, assigns.receipt.stage} do
        {:failed, _} -> {"badge-error", "Failed"}
        {:awaiting_ai, _} -> {"badge-warning", "Waiting for AI"}
        {_, :pending} -> {"badge-ghost", "Pending"}
        {_, :extracted} -> {"badge-info", "Processing"}
        {_, :items_created} -> {"badge-info", "Processing"}
        {_, :ready_for_review} -> {"badge-success", "Ready for review"}
        {_, :confirmed} -> {"badge-success", "Confirmed"}
        _ -> {"badge-ghost", "Unknown"}
      end

    assigns = assign(assigns, :class, class)
    assigns = assign(assigns, :text, text)

    ~H"""
    <span class={"badge #{@class}"}>{@text}</span>
    """
  end

  attr :value, :float, required: true

  defp confidence_indicator(assigns) do
    color =
      cond do
        assigns.value >= 0.9 -> "text-success"
        assigns.value >= 0.7 -> "text-warning"
        true -> "text-error"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"text-xs #{@color}"}>
      {round(@value * 100)}%
    </span>
    """
  end

  # Event handlers

  @impl true
  def handle_event("toggle_upload", _, socket) do
    {:noreply, assign(socket, :show_upload, !socket.assigns.show_upload)}
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :receipt_image, ref)}
  end

  @impl true
  def handle_event("save_upload", _params, socket) do
    socket = assign(socket, :uploading, true)
    account = socket.assigns.current_account
    user = socket.assigns.current_user

    consumed_entries =
      consume_uploaded_entries(socket, :receipt_image, fn %{path: path}, entry ->
        tmp_path =
          Path.join(
            System.tmp_dir!(),
            "receipt_#{Ecto.UUID.generate()}#{Path.extname(entry.client_name)}"
          )

        File.cp!(path, tmp_path)
        {:ok, %{path: tmp_path, client_name: entry.client_name}}
      end)

    case consumed_entries do
      [file_params | _] ->
        case ReceiptProcessor.upload(file_params, user, account) do
          {:ok, receipt} ->
            # Subscribe to PubSub for real-time updates. The pipeline was already
            # enqueued by ReceiptProcessor.upload/4.
            if connected?(socket) do
              Phoenix.PubSub.subscribe(GroceryPlanner.PubSub, "receipt:#{receipt.id}")
            end

            # Clean up temp file
            File.rm(file_params.path)

            socket =
              socket
              |> assign(:uploading, false)
              |> assign(:show_upload, false)
              |> put_flash(:info, "Receipt uploaded! Processing...")
              |> push_patch(to: ~p"/receipts/#{receipt.id}")

            {:noreply, socket}

          {:error, {:duplicate_receipt, existing}} ->
            File.rm(file_params.path)

            socket =
              socket
              |> assign(:uploading, false)
              |> put_flash(:warning, "This receipt was already uploaded. View it below.")
              |> push_patch(to: ~p"/receipts/#{existing.id}")

            {:noreply, socket}

          {:error, reason} ->
            File.rm(file_params.path)

            socket =
              socket
              |> assign(:uploading, false)
              |> put_flash(:error, "Failed to upload receipt: #{inspect(reason)}")

            {:noreply, socket}
        end

      _ ->
        {:noreply, assign(socket, :uploading, false)}
    end
  end

  @impl true
  def handle_event("remove_item", %{"index" => index}, socket) do
    index = String.to_integer(index)
    receipt = socket.assigns.selected_receipt
    receipt_items = receipt.receipt_items || []

    if index >= 0 and index < length(receipt_items) do
      item_to_remove = Enum.at(receipt_items, index)

      case Inventory.destroy_receipt_item(item_to_remove, actor: socket.assigns.current_user) do
        :ok ->
          # Reload the receipt with updated items
          socket = load_receipt_detail(socket, receipt.id)
          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to remove item")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("add_to_inventory", _, socket) do
    receipt = socket.assigns.selected_receipt
    account_id = socket.assigns.current_account.id
    actor = socket.assigns.current_user

    # Create inventory entries from receipt items
    results =
      (receipt.receipt_items || [])
      |> Enum.map(fn item ->
        create_inventory_entry_from_item(item, account_id, receipt.purchase_date, actor)
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    error_count = Enum.count(results, &match?({:error, _}, &1))

    message =
      cond do
        error_count == 0 -> "#{success_count} items added to inventory!"
        success_count == 0 -> "Failed to add items to inventory"
        true -> "#{success_count} items added, #{error_count} failed"
      end

    socket =
      socket
      |> load_receipts()
      |> put_flash(if(error_count == 0, do: :info, else: :warning), message)

    {:noreply, socket}
  end

  @impl true
  def handle_event("discard_receipt", _, socket) do
    receipt = socket.assigns.selected_receipt

    case Inventory.destroy_receipt(receipt, actor: socket.assigns.current_user) do
      :ok ->
        socket =
          socket
          |> load_receipts()
          |> put_flash(:info, "Receipt discarded")
          |> push_patch(to: ~p"/receipts")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to discard receipt")}
    end
  end

  @impl true
  def handle_event("retry_processing", _, socket) do
    receipt = socket.assigns.selected_receipt

    # Retry = clear the failure and re-enqueue the worker for the current stage
    # (AI-006 §2). The milestone is preserved, so an idempotent stage resumes
    # exactly where it stopped — no bespoke resume logic.
    case Inventory.clear_condition(receipt, actor: socket.assigns.current_user) do
      {:ok, updated_receipt} ->
        GroceryPlanner.Inventory.Receipts.Pipeline.enqueue_for_stage(updated_receipt)

        socket =
          socket
          |> assign(:selected_receipt, updated_receipt)
          |> put_flash(:info, "Receipt queued for reprocessing")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to retry processing")}
    end
  end

  @impl true
  def handle_event("delete_receipt", %{"id" => id}, socket) do
    case Inventory.get_receipt(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, receipt} ->
        # Delete the file from disk
        if receipt.file_path do
          file_path = resolve_file_path(receipt.file_path)
          if file_path, do: File.rm(file_path)
        end

        case Inventory.destroy_receipt(receipt,
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_account.id
             ) do
          :ok ->
            socket =
              socket
              |> load_receipts()
              |> assign(:selected_receipt, nil)
              |> put_flash(:info, "Receipt deleted")
              |> push_patch(to: ~p"/receipts")

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete receipt")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Receipt not found")}
    end
  end

  @impl true
  def handle_info({:receipt_updated, receipt}, socket) do
    # Durable stage/condition is already written; this is just the UI catching up
    # (AI-006 §1). Reload the list and, if the updated receipt is open, its detail.
    socket =
      socket
      |> load_receipts()
      |> then(fn s ->
        if s.assigns.selected_receipt && s.assigns.selected_receipt.id == receipt.id do
          load_receipt_detail(s, receipt.id)
        else
          s
        end
      end)
      |> maybe_flash_for(receipt)

    {:noreply, socket}
  end

  defp maybe_flash_for(socket, %{condition: :failed} = receipt) do
    put_flash(socket, :error, "Receipt processing failed: #{receipt.failure_reason}")
  end

  defp maybe_flash_for(socket, %{stage: stage}) when stage in [:ready_for_review, :confirmed] do
    put_flash(socket, :info, "Receipt processed successfully!")
  end

  defp maybe_flash_for(socket, _receipt), do: socket

  # Private helpers

  defp load_receipts(socket) do
    {:ok, receipts} =
      Inventory.list_receipts(
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id
      )

    assign(socket, :receipts, receipts)
  end

  defp load_receipt_detail(socket, id) do
    case Inventory.get_receipt(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, receipt} ->
        # Load receipt_items relationship
        receipt =
          Ash.load!(receipt, :receipt_items,
            actor: socket.assigns.current_user,
            tenant: socket.assigns.current_account.id
          )

        socket = assign(socket, :selected_receipt, receipt)

        # Subscribe to PubSub while the receipt is still moving through the
        # pipeline (not yet ready for review, or waiting on the AI service).
        if (receipt.stage in [:pending, :extracted, :items_created] or
              receipt.condition == :awaiting_ai) and connected?(socket) do
          Phoenix.PubSub.subscribe(GroceryPlanner.PubSub, "receipt:#{receipt.id}")
        end

        socket

      {:error, _} ->
        socket
        |> put_flash(:error, "Receipt not found")
        |> push_patch(to: ~p"/receipts")
    end
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp error_to_string(:too_large), do: "File is too large (max 10MB)"
  defp error_to_string(:not_accepted), do: "Invalid file type. Please use JPG, PNG, or WebP"
  defp error_to_string(:too_many_files), do: "Only one file allowed"
  defp error_to_string(err), do: "Error: #{inspect(err)}"

  defp create_inventory_entry_from_item(item, account_id, purchase_date, actor) do
    # Use final_name if available (user-corrected), otherwise use raw_name
    item_name = item.final_name || item.raw_name

    # Find or create a GroceryItem by name
    grocery_item =
      case find_grocery_item_by_name(item_name, account_id, actor) do
        {:ok, existing} ->
          existing

        :not_found ->
          # Create new grocery item
          case Inventory.create_grocery_item(account_id, %{name: item_name}, actor: actor) do
            {:ok, new_item} -> new_item
            {:error, _} -> nil
          end
      end

    if grocery_item do
      # Create inventory entry
      entry_attrs = %{
        quantity: item.final_quantity || item.quantity || Decimal.new(1),
        unit: item.final_unit || item.unit,
        purchase_price: item.unit_price,
        purchase_date: purchase_date,
        grocery_item_id: grocery_item.id
      }

      Inventory.create_inventory_entry(account_id, grocery_item.id, entry_attrs, actor: actor)
    else
      {:error, :no_grocery_item}
    end
  end

  defp find_grocery_item_by_name(name, account_id, actor) do
    case Inventory.get_item_by_name(name, actor: actor, tenant: account_id) do
      {:ok, item} -> {:ok, item}
      {:error, %Ash.Error.Query.NotFound{}} -> :not_found
      _ -> :not_found
    end
  end

  defp file_path_to_url(file_path) when is_binary(file_path) do
    # Already a web URL path
    if String.starts_with?(file_path, "/") and not String.contains?(file_path, "priv") do
      file_path
    else
      # Files are stored in priv/static/uploads/receipts/
      "/uploads/receipts/" <> Path.basename(file_path)
    end
  end

  defp file_path_to_url(_), do: nil

  defp resolve_file_path(path) when is_binary(path) do
    if File.exists?(path) do
      path
    else
      # Try resolving web URL path to filesystem path
      resolved =
        Path.join([:code.priv_dir(:grocery_planner), "static", String.trim_leading(path, "/")])

      if File.exists?(resolved), do: resolved, else: path
    end
  end

  defp resolve_file_path(_), do: nil
end
