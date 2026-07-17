defmodule GroceryPlannerWeb.InventoryLive.LocationHandlers do
  @moduledoc "Event handlers for storage location operations."

  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias GroceryPlanner.Inventory

  def handle_event("new_location", _, socket) do
    {:noreply, assign(socket, show_form: :location, form: to_form(%{}, as: :location))}
  end

  def handle_event("save_location", %{"location" => params}, socket) do
    account_id = socket.assigns.current_account.id

    case Inventory.create_storage_location!(
           account_id,
           params,
           authorize?: false,
           tenant: account_id
         ) do
      location when is_struct(location) ->
        socket =
          socket
          |> GroceryPlannerWeb.InventoryLive.load_data()
          |> assign(show_form: nil, form: nil)
          |> put_flash(:info, "Storage location created successfully")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create storage location")}
    end
  end

  def handle_event("delete_location", %{"id" => id}, socket) do
    case Inventory.get_storage_location(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, location} ->
        result =
          Inventory.destroy_storage_location(location,
            actor: socket.assigns.current_user,
            tenant: socket.assigns.current_account.id
          )

        case result do
          :ok ->
            socket =
              socket
              |> GroceryPlannerWeb.InventoryLive.load_data()
              |> put_flash(:info, "Storage location deleted successfully")

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete storage location")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Storage location not found")}
    end
  end
end
