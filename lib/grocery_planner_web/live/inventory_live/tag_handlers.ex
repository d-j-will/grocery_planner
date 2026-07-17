defmodule GroceryPlannerWeb.InventoryLive.TagHandlers do
  @moduledoc "Event handlers for tag operations."

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias GroceryPlanner.Inventory

  def handle_event("new_tag", _, socket) do
    {:noreply, assign(socket, show_form: :tag, form: to_form(%{}, as: :tag), editing_id: nil)}
  end

  def handle_event("save_tag", %{"tag" => params}, socket) do
    account_id = socket.assigns.current_account.id

    result =
      if socket.assigns.editing_id do
        case Inventory.get_grocery_item_tag(
               socket.assigns.editing_id,
               authorize?: false,
               tenant: account_id
             ) do
          {:ok, tag} ->
            Inventory.update_grocery_item_tag(
              tag,
              params,
              authorize?: false
            )

          error ->
            error
        end
      else
        Inventory.create_grocery_item_tag(
          account_id,
          params,
          authorize?: false,
          tenant: account_id
        )
      end

    case result do
      {:ok, _tag} ->
        socket =
          socket
          |> GroceryPlannerWeb.InventoryLive.load_data()
          |> assign(show_form: nil, form: nil, editing_id: nil)
          |> put_flash(
            :info,
            if(socket.assigns.editing_id,
              do: "Tag updated successfully",
              else: "Tag created successfully"
            )
          )

        {:noreply, socket}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           if(socket.assigns.editing_id, do: "Failed to update tag", else: "Failed to create tag")
         )}
    end
  end

  def handle_event("edit_tag", %{"id" => id}, socket) do
    case Inventory.get_grocery_item_tag(
           id,
           authorize?: false,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, tag} ->
        form =
          to_form(
            %{
              "name" => tag.name,
              "color" => tag.color,
              "description" => tag.description
            },
            as: :tag
          )

        {:noreply, assign(socket, show_form: :tag, form: form, editing_id: id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Tag not found")}
    end
  end

  def handle_event("delete_tag", %{"id" => id}, socket) do
    case Inventory.get_grocery_item_tag(
           id,
           authorize?: false,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, tag} ->
        result = Inventory.destroy_grocery_item_tag(tag, authorize?: false)

        case result do
          :ok ->
            socket =
              socket
              |> GroceryPlannerWeb.InventoryLive.load_data()
              |> put_flash(:info, "Tag deleted successfully")

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete tag")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Tag not found")}
    end
  end

  def handle_event("manage_tags", %{"id" => id}, socket) do
    case Inventory.get_grocery_item(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id,
           load: [:tags]
         ) do
      {:ok, item} ->
        {:noreply, assign(socket, managing_tags_for: item)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Item not found")}
    end
  end

  def handle_event("add_tag_to_item", %{"item-id" => item_id, "tag-id" => tag_id}, socket) do
    case Inventory.create_grocery_item_tagging(
           %{grocery_item_id: item_id, tag_id: tag_id},
           authorize?: false
         ) do
      {:ok, _} ->
        {:ok, updated_item} =
          Inventory.get_grocery_item(item_id,
            actor: socket.assigns.current_user,
            tenant: socket.assigns.current_account.id,
            load: [:tags]
          )

        socket =
          socket
          |> assign(managing_tags_for: updated_item)
          |> GroceryPlannerWeb.InventoryLive.load_data()

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add tag")}
    end
  end

  def handle_event("remove_tag_from_item", %{"item-id" => item_id, "tag-id" => tag_id}, socket) do
    case Inventory.get_tagging(
           item_id,
           tag_id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, tagging} ->
        case Inventory.destroy_grocery_item_tagging(tagging, authorize?: false) do
          :ok ->
            {:ok, updated_item} =
              Inventory.get_grocery_item(item_id,
                actor: socket.assigns.current_user,
                tenant: socket.assigns.current_account.id,
                load: [:tags]
              )

            socket =
              socket
              |> assign(managing_tags_for: updated_item)
              |> GroceryPlannerWeb.InventoryLive.load_data()

            {:noreply, socket}

          {:ok, _} ->
            {:ok, updated_item} =
              Inventory.get_grocery_item(item_id,
                actor: socket.assigns.current_user,
                tenant: socket.assigns.current_account.id,
                load: [:tags]
              )

            socket =
              socket
              |> assign(managing_tags_for: updated_item)
              |> GroceryPlannerWeb.InventoryLive.load_data()

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to remove tag")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Tag association not found")}
    end
  end

  def handle_event("cancel_tag_management", _, socket) do
    {:noreply, assign(socket, managing_tags_for: nil)}
  end

  def handle_event("toggle_tag_filter", %{"tag-id" => tag_id}, socket) do
    current_filters = socket.assigns.filter_tag_ids

    new_filters =
      if tag_id in current_filters do
        List.delete(current_filters, tag_id)
      else
        [tag_id | current_filters]
      end

    socket =
      socket
      |> assign(:filter_tag_ids, new_filters)
      |> assign(:inventory_page, 1)
      |> GroceryPlannerWeb.InventoryLive.load_data()

    {:noreply, socket}
  end

  def handle_event("clear_tag_filters", _, socket) do
    socket =
      socket
      |> assign(:filter_tag_ids, [])
      |> assign(:inventory_page, 1)
      |> GroceryPlannerWeb.InventoryLive.load_data()

    {:noreply, socket}
  end
end
