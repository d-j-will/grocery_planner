defmodule GroceryPlannerWeb.InventoryLive.ItemHandlers do
  @moduledoc "Event handlers for grocery item operations."

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias GroceryPlanner.AI.Categorizer
  alias GroceryPlanner.AI.CategorizationFeedback
  alias GroceryPlanner.Inventory

  def handle_event("new_item", _, socket) do
    {:noreply,
     assign(socket,
       show_form: :item,
       form: to_form(%{}, as: :item),
       form_params: %{},
       editing_id: nil,
       selected_tag_ids: [],
       category_suggestion: nil,
       category_suggestion_loading: false,
       last_categorized_name: nil
     )}
  end

  def handle_event("edit_item", %{"id" => id}, socket) do
    case Inventory.get_grocery_item(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id,
           load: [:tags]
         ) do
      {:ok, item} ->
        form_params = %{
          "name" => item.name,
          "description" => item.description,
          "category_id" => item.category_id,
          "default_unit" => item.default_unit,
          "barcode" => item.barcode
        }

        form = to_form(form_params, as: :item)

        selected_tag_ids = Enum.map(item.tags || [], fn tag -> to_string(tag.id) end)

        {:noreply,
         assign(socket,
           show_form: :item,
           form: form,
           form_params: form_params,
           editing_id: id,
           selected_tag_ids: selected_tag_ids,
           category_suggestion: nil,
           category_suggestion_loading: false,
           last_categorized_name: item.name
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Item not found")}
    end
  end

  def handle_event("validate_item", %{"item" => params}, socket) do
    new_params = Map.merge(socket.assigns.form_params || %{}, params)
    form = to_form(new_params, as: :item)

    # Check if name has changed and trigger auto-categorization
    new_name = params["name"] || ""
    last_name = socket.assigns.last_categorized_name

    socket =
      if String.length(new_name) >= 3 && new_name != last_name && socket.assigns.categories != [] do
        trigger_auto_categorization(socket, new_name)
      else
        socket
      end

    {:noreply, assign(socket, form: form, form_params: new_params)}
  end

  def handle_event("save_item", %{"item" => params}, socket) do
    account_id = socket.assigns.current_account.id
    item_params = Map.drop(params, ["tag_ids"])

    result =
      if socket.assigns.editing_id do
        case Inventory.get_grocery_item(
               socket.assigns.editing_id,
               actor: socket.assigns.current_user,
               tenant: account_id
             ) do
          {:ok, item} ->
            Inventory.update_grocery_item(
              item,
              item_params,
              actor: socket.assigns.current_user,
              tenant: account_id
            )

          error ->
            error
        end
      else
        case Inventory.create_grocery_item!(
               account_id,
               item_params,
               authorize?: false,
               tenant: account_id
             ) do
          item when is_struct(item) -> {:ok, item}
          error -> error
        end
      end

    case result do
      {:ok, item} ->
        sync_item_tags(item.id, socket.assigns.selected_tag_ids, socket)
        log_categorization_feedback(socket, item)

        action = if socket.assigns.editing_id, do: "updated", else: "created"

        socket =
          socket
          |> GroceryPlannerWeb.InventoryLive.load_data()
          |> assign(
            show_form: nil,
            form: nil,
            editing_id: nil,
            selected_tag_ids: [],
            category_suggestion: nil
          )
          |> put_flash(:info, "Grocery item #{action} successfully")

        {:noreply, socket}

      {:error, _} ->
        action = if socket.assigns.editing_id, do: "update", else: "create"
        {:noreply, put_flash(socket, :error, "Failed to #{action} grocery item")}
    end
  end

  def handle_event("delete_item", %{"id" => id}, socket) do
    case Inventory.get_grocery_item(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, item} ->
        result =
          Inventory.destroy_grocery_item(item,
            actor: socket.assigns.current_user,
            tenant: socket.assigns.current_account.id
          )

        case result do
          :ok ->
            socket =
              socket
              |> GroceryPlannerWeb.InventoryLive.load_data()
              |> put_flash(:info, "Item deleted successfully")

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete item")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Item not found")}
    end
  end

  def handle_event("suggest_category", _params, socket) do
    form_params = socket.assigns.form_params || %{}
    name = form_params["name"]

    if is_nil(name) || name == "" do
      {:noreply, put_flash(socket, :warning, "Please enter an item name first")}
    else
      categories = socket.assigns.categories
      labels = Enum.map(categories, & &1.name)

      opts = [
        candidate_labels: labels,
        tenant_id: socket.assigns.current_account.id,
        user_id: socket.assigns.current_user.id
      ]

      case Categorizer.predict(name, opts) do
        {:ok, %{category: predicted_category}} ->
          case Enum.find(categories, fn c ->
                 String.downcase(c.name) == String.downcase(predicted_category)
               end) do
            nil ->
              {:noreply,
               put_flash(
                 socket,
                 :warning,
                 "Suggested category '#{predicted_category}' not found in list"
               )}

            category ->
              new_params = Map.put(form_params, "category_id", category.id)
              form = to_form(new_params, as: :item)

              socket =
                socket
                |> assign(form: form, form_params: new_params)
                |> put_flash(:info, "Suggested category: #{category.name}")

              {:noreply, socket}
          end

        {:error, :disabled} ->
          {:noreply, put_flash(socket, :info, "AI categorization is not enabled")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not predict category")}
      end
    end
  end

  def handle_event("accept_suggestion", _params, socket) do
    case socket.assigns.category_suggestion do
      %{category: category} ->
        new_params = Map.put(socket.assigns.form_params, "category_id", category.id)
        form = to_form(new_params, as: :item)

        {:noreply,
         assign(socket,
           form: form,
           form_params: new_params,
           category_suggestion: nil
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_form_tag", %{"tag-id" => tag_id}, socket) do
    current = socket.assigns.selected_tag_ids

    new_selected =
      if tag_id in current do
        List.delete(current, tag_id)
      else
        [tag_id | current]
      end

    {:noreply, assign(socket, :selected_tag_ids, new_selected)}
  end

  # Private helpers

  defp trigger_auto_categorization(socket, item_name) do
    categories = socket.assigns.categories
    labels = Enum.map(categories, & &1.name)

    opts = [
      candidate_labels: labels,
      tenant_id: socket.assigns.current_account.id,
      user_id: socket.assigns.current_user.id,
      timeout: 3000
    ]

    pid = self()

    Task.start(fn ->
      result = Categorizer.predict(item_name, opts)
      send(pid, {:category_suggestion_result, item_name, result})
    end)

    socket
    |> assign(:category_suggestion_loading, true)
    |> assign(:last_categorized_name, item_name)
  end

  defp log_categorization_feedback(socket, item) do
    suggestion = socket.assigns[:category_suggestion]

    if suggestion do
      predicted_name = suggestion.category.name
      predicted_confidence = suggestion.confidence

      saved_category =
        Enum.find(socket.assigns.categories, fn c -> c.id == item.category_id end)

      saved_category_name = if saved_category, do: saved_category.name, else: "Unknown"
      was_correction = String.downcase(predicted_name) != String.downcase(saved_category_name)

      form_params = socket.assigns.form_params || %{}
      item_name = form_params["name"] || ""

      account_id = socket.assigns.current_account.id

      Task.start(fn ->
        try do
          CategorizationFeedback.log_correction(
            item_name,
            predicted_name,
            predicted_confidence,
            saved_category_name,
            was_correction: was_correction,
            account_id: account_id,
            authorize?: false,
            tenant: account_id
          )
        rescue
          _ -> :ok
        end
      end)
    end
  end

  defp sync_item_tags(item_id, selected_tag_ids, socket) do
    {:ok, current_taggings} =
      Inventory.list_taggings_for_item(
        item_id,
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id
      )

    current_tag_ids = Enum.map(current_taggings, fn t -> to_string(t.tag_id) end)

    tags_to_add = selected_tag_ids -- current_tag_ids
    tags_to_remove = current_tag_ids -- selected_tag_ids

    for tag_id <- tags_to_add do
      Inventory.create_grocery_item_tagging(
        %{grocery_item_id: item_id, tag_id: tag_id},
        authorize?: false
      )
    end

    for tag_id <- tags_to_remove do
      tagging = Enum.find(current_taggings, &(&1.tag_id == tag_id))

      if tagging do
        Inventory.destroy_grocery_item_tagging(tagging, authorize?: false)
      end
    end
  end
end
