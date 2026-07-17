defmodule GroceryPlannerWeb.InventoryLive.CategoryHandlers do
  @moduledoc "Event handlers for category operations."

  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias GroceryPlanner.Inventory

  def handle_event("new_category", _, socket) do
    {:noreply, assign(socket, show_form: :category, form: to_form(%{}, as: :category))}
  end

  def handle_event("save_category", %{"category" => params}, socket) do
    account_id = socket.assigns.current_account.id

    case Inventory.create_category!(
           account_id,
           params,
           authorize?: false,
           tenant: account_id
         ) do
      category when is_struct(category) ->
        socket =
          socket
          |> GroceryPlannerWeb.InventoryLive.load_data()
          |> assign(show_form: nil, form: nil)
          |> put_flash(:info, "Category created successfully")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create category")}
    end
  end

  def handle_event("delete_category", %{"id" => id}, socket) do
    case Inventory.get_category(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, category} ->
        result =
          Inventory.destroy_category(category,
            actor: socket.assigns.current_user,
            tenant: socket.assigns.current_account.id
          )

        case result do
          :ok ->
            socket =
              socket
              |> GroceryPlannerWeb.InventoryLive.load_data()
              |> put_flash(:info, "Category deleted successfully")

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete category")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Category not found")}
    end
  end
end
