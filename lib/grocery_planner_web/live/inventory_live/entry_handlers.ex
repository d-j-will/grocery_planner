defmodule GroceryPlannerWeb.InventoryLive.EntryHandlers do
  @moduledoc "Event handlers for inventory entry operations."

  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias GroceryPlanner.Inventory

  def handle_event("new_entry", _, socket) do
    {:noreply, assign(socket, show_form: :entry, form: to_form(%{}, as: :entry))}
  end

  def handle_event("save_entry", %{"entry" => params}, socket) do
    account_id = socket.assigns.current_account.id
    grocery_item_id = params["grocery_item_id"]

    params =
      if params["purchase_price"] && params["purchase_price"] != "" do
        currency = socket.assigns.current_account.currency || "USD"

        Map.put(params, "purchase_price", %{
          "amount" => params["purchase_price"],
          "currency" => currency
        })
      else
        params
      end

    case Inventory.create_inventory_entry!(
           account_id,
           grocery_item_id,
           params,
           authorize?: false,
           tenant: account_id
         ) do
      entry when is_struct(entry) ->
        socket =
          socket
          |> GroceryPlannerWeb.InventoryLive.load_data()
          |> assign(show_form: nil, form: nil)
          |> put_flash(:info, "Inventory entry created successfully")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create inventory entry")}
    end
  end

  def handle_event("delete_entry", %{"id" => id}, socket) do
    case Inventory.get_inventory_entry(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, entry} ->
        result =
          Inventory.destroy_inventory_entry(entry,
            actor: socket.assigns.current_user,
            tenant: socket.assigns.current_account.id
          )

        case result do
          :ok ->
            socket =
              socket
              |> GroceryPlannerWeb.InventoryLive.load_data()
              |> put_flash(:info, "Inventory entry deleted successfully")

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete inventory entry")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Inventory entry not found")}
    end
  end

  def handle_event("consume_entry", %{"id" => id}, socket) do
    handle_usage_log(socket, id, :consumed)
  end

  def handle_event("expire_entry", %{"id" => id}, socket) do
    handle_usage_log(socket, id, :expired)
  end

  def handle_event("bulk_mark_expired", _params, socket) do
    today = Date.utc_today()
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user

    expired_entries =
      Enum.filter(socket.assigns.inventory_entries, fn entry ->
        entry.use_by_date && Date.compare(entry.use_by_date, today) == :lt &&
          entry.status == :available
      end)

    if Enum.empty?(expired_entries) do
      {:noreply, put_flash(socket, :info, "No expired items to update")}
    else
      results =
        Enum.map(expired_entries, fn entry ->
          GroceryPlanner.Analytics.UsageLog.create!(
            %{
              quantity: entry.quantity,
              unit: entry.unit,
              reason: :expired,
              occurred_at: DateTime.utc_now(),
              cost: entry.purchase_price,
              grocery_item_id: entry.grocery_item_id,
              account_id: account_id
            },
            authorize?: false,
            tenant: account_id
          )

          Inventory.update_inventory_entry!(
            entry,
            %{status: :expired},
            actor: user,
            tenant: account_id
          )
        end)

      count = length(results)

      socket =
        socket
        |> GroceryPlannerWeb.InventoryLive.load_data()
        |> put_flash(:info, "#{count} item#{if count != 1, do: "s", else: ""} marked as expired")

      {:noreply, socket}
    end
  end

  def handle_event("bulk_consume_available", _params, socket) do
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user

    available_entries =
      Enum.filter(socket.assigns.inventory_entries, fn entry ->
        entry.status == :available
      end)

    if Enum.empty?(available_entries) do
      {:noreply, put_flash(socket, :info, "No available items to consume")}
    else
      results =
        Enum.map(available_entries, fn entry ->
          GroceryPlanner.Analytics.UsageLog.create!(
            %{
              quantity: entry.quantity,
              unit: entry.unit,
              reason: :consumed,
              occurred_at: DateTime.utc_now(),
              cost: entry.purchase_price,
              grocery_item_id: entry.grocery_item_id,
              account_id: account_id
            },
            authorize?: false,
            tenant: account_id
          )

          Inventory.update_inventory_entry!(
            entry,
            %{status: :consumed},
            actor: user,
            tenant: account_id
          )
        end)

      count = length(results)

      socket =
        socket
        |> GroceryPlannerWeb.InventoryLive.load_data()
        |> put_flash(:info, "#{count} item#{if count != 1, do: "s", else: ""} marked as consumed")

      {:noreply, socket}
    end
  end

  # Private helpers

  defp handle_usage_log(socket, entry_id, reason) do
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user

    case Inventory.get_inventory_entry(entry_id,
           actor: user,
           tenant: account_id
         ) do
      {:ok, entry} ->
        GroceryPlanner.Analytics.UsageLog.create!(
          %{
            quantity: entry.quantity,
            unit: entry.unit,
            reason: reason,
            occurred_at: DateTime.utc_now(),
            cost: entry.purchase_price,
            grocery_item_id: entry.grocery_item_id,
            account_id: account_id
          },
          authorize?: false,
          tenant: account_id
        )

        Inventory.update_inventory_entry!(
          entry,
          %{status: reason},
          actor: user,
          tenant: account_id
        )

        socket =
          socket
          |> GroceryPlannerWeb.InventoryLive.load_data()
          |> put_flash(:info, "Item marked as #{reason}")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Entry not found")}
    end
  end
end
