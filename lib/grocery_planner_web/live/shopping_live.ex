defmodule GroceryPlannerWeb.ShoppingLive do
  use GroceryPlannerWeb, :live_view
  import GroceryPlannerWeb.UIComponents
  require Logger

  on_mount({GroceryPlannerWeb.Auth, :require_authenticated_user})

  alias GroceryPlanner.MealPlanning.Voting

  @per_page 12

  def mount(_params, _session, socket) do
    voting_active =
      Voting.voting_active?(socket.assigns.current_account.id, socket.assigns.current_user)

    socket = assign(socket, :current_scope, socket.assigns.current_account)

    socket =
      socket
      |> assign(:voting_active, voting_active)
      |> assign(:show_create_modal, false)
      |> assign(:show_generate_modal, false)
      |> assign(:show_add_item_modal, false)
      |> assign(:show_transfer_modal, false)
      |> assign(:selected_list, nil)
      |> assign(:start_date, Date.utc_today() |> Date.to_iso8601())
      |> assign(:end_date, Date.utc_today() |> Date.add(7) |> Date.to_iso8601())
      |> assign(:new_list_name, "")
      |> assign(:new_item_name, "")
      |> assign(:new_item_quantity, "1")
      |> assign(:new_item_unit, "")
      |> assign(:storage_locations, [])
      |> assign(:transferable_items, [])
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:total_count, 0)
      |> assign(:total_pages, 1)
      |> load_shopping_lists()

    {:ok, socket}
  end

  def handle_event("show_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, true)}
  end

  def handle_event("page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    socket =
      socket
      |> assign(:page, page)
      |> load_shopping_lists()

    {:noreply, socket}
  end

  def handle_event("hide_create_modal", _params, socket) do
    {:noreply, assign(socket, show_create_modal: false, new_list_name: "")}
  end

  def handle_event("show_generate_modal", _params, socket) do
    today = Date.utc_today()
    week_end = Date.add(today, 7)

    socket =
      socket
      |> assign(:show_generate_modal, true)
      |> assign(:start_date, Date.to_iso8601(today))
      |> assign(:end_date, Date.to_iso8601(week_end))

    {:noreply, socket}
  end

  def handle_event("hide_generate_modal", _params, socket) do
    {:noreply, assign(socket, :show_generate_modal, false)}
  end

  def handle_event("create_list", %{"name" => name}, socket) do
    case GroceryPlanner.Shopping.create_shopping_list(
           socket.assigns.current_account.id,
           %{name: name},
           tenant: socket.assigns.current_account.id,
           actor: socket.assigns.current_user
         ) do
      {:ok, _list} ->
        socket =
          socket
          |> put_flash(:info, "Shopping list created successfully")
          |> assign(:show_create_modal, false)
          |> assign(:new_list_name, "")
          |> load_shopping_lists()

        {:noreply, socket}

      {:error, error} ->
        Logger.error("Failed to create shopping list: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to create shopping list")}
    end
  end

  def handle_event(
        "generate_list",
        %{"start_date" => start_date_str, "end_date" => end_date_str, "name" => name},
        socket
      ) do
    start_date = Date.from_iso8601!(start_date_str)
    end_date = Date.from_iso8601!(end_date_str)

    case GroceryPlanner.Shopping.generate_shopping_list_from_meal_plans(
           socket.assigns.current_account.id,
           start_date,
           end_date,
           %{name: name},
           tenant: socket.assigns.current_account.id,
           actor: socket.assigns.current_user
         ) do
      {:ok, _list} ->
        socket =
          socket
          |> put_flash(:info, "Shopping list generated from meal plans")
          |> assign(:show_generate_modal, false)
          |> load_shopping_lists()

        {:noreply, socket}

      {:error, error} ->
        Logger.error("Failed to generate shopping list: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to generate shopping list")}
    end
  end

  def handle_event("select_list", %{"id" => id}, socket) do
    {:ok, list} =
      GroceryPlanner.Shopping.get_shopping_list(
        id,
        tenant: socket.assigns.current_account.id,
        actor: socket.assigns.current_user,
        load: [:items, :total_items, :checked_items, :progress_percentage]
      )

    {:noreply, assign(socket, :selected_list, list)}
  end

  def handle_event("back_to_lists", _params, socket) do
    {:noreply, assign(socket, :selected_list, nil)}
  end

  def handle_event("delete_list", %{"id" => id}, socket) do
    {:ok, list} =
      GroceryPlanner.Shopping.get_shopping_list(
        id,
        tenant: socket.assigns.current_account.id,
        actor: socket.assigns.current_user
      )

    case GroceryPlanner.Shopping.destroy_shopping_list(list,
           tenant: socket.assigns.current_account.id,
           actor: socket.assigns.current_user
         ) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Shopping list deleted")
          |> assign(:selected_list, nil)
          |> load_shopping_lists()

        {:noreply, socket}

      {:error, error} ->
        Logger.error("Failed to delete shopping list: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to delete shopping list")}
    end
  end

  def handle_event("toggle_item", %{"id" => id}, socket) do
    {:ok, item} =
      GroceryPlanner.Shopping.get_shopping_list_item(
        id,
        tenant: socket.assigns.current_account.id,
        actor: socket.assigns.current_user
      )

    case GroceryPlanner.Shopping.toggle_shopping_list_item_check(item,
           tenant: socket.assigns.current_account.id,
           actor: socket.assigns.current_user
         ) do
      {:ok, _item} ->
        socket =
          if socket.assigns.selected_list do
            {:ok, list} =
              GroceryPlanner.Shopping.get_shopping_list(
                socket.assigns.selected_list.id,
                tenant: socket.assigns.current_account.id,
                actor: socket.assigns.current_user,
                load: [:items, :total_items, :checked_items, :progress_percentage]
              )

            assign(socket, :selected_list, list)
          else
            socket
          end

        {:noreply, socket}

      {:error, error} ->
        Logger.error("Failed to toggle item: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to update item")}
    end
  end

  def handle_event("show_add_item_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_add_item_modal, true)
      |> assign(:new_item_name, "")
      |> assign(:new_item_quantity, "1")
      |> assign(:new_item_unit, "")

    {:noreply, socket}
  end

  def handle_event("hide_add_item_modal", _params, socket) do
    {:noreply, assign(socket, :show_add_item_modal, false)}
  end

  def handle_event("prevent_close", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("show_transfer_modal", _params, socket) do
    # Get checked items that have a grocery_item_id (can be transferred)
    checked_items = Enum.filter(socket.assigns.selected_list.items, & &1.checked)

    transferable =
      Enum.filter(checked_items, fn item -> item.grocery_item_id != nil end)

    # Load storage locations for the dropdown
    {:ok, locations} =
      GroceryPlanner.Inventory.list_storage_locations_sorted(
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id
      )

    socket =
      socket
      |> assign(:show_transfer_modal, true)
      |> assign(:storage_locations, locations)
      |> assign(:transferable_items, transferable)

    {:noreply, socket}
  end

  def handle_event("hide_transfer_modal", _params, socket) do
    {:noreply, assign(socket, :show_transfer_modal, false)}
  end

  def handle_event("check_all", _params, socket) do
    results =
      socket.assigns.selected_list.items
      |> Enum.filter(fn item -> !item.checked end)
      |> Enum.map(fn item ->
        GroceryPlanner.Shopping.ShoppingListItem.check(item,
          tenant: socket.assigns.current_account.id,
          actor: socket.assigns.current_user
        )
      end)

    {:ok, list} =
      GroceryPlanner.Shopping.get_shopping_list(
        socket.assigns.selected_list.id,
        tenant: socket.assigns.current_account.id,
        actor: socket.assigns.current_user,
        load: [:items, :total_items, :checked_items, :progress_percentage]
      )

    checked_count = Enum.count(results, fn r -> match?({:ok, _}, r) end)

    socket =
      socket
      |> assign(:selected_list, list)
      |> put_flash(
        :info,
        "#{checked_count} item#{if checked_count != 1, do: "s", else: ""} checked"
      )

    {:noreply, socket}
  end

  def handle_event("uncheck_all", _params, socket) do
    results =
      socket.assigns.selected_list.items
      |> Enum.filter(fn item -> item.checked end)
      |> Enum.map(fn item ->
        GroceryPlanner.Shopping.ShoppingListItem.uncheck(item,
          tenant: socket.assigns.current_account.id,
          actor: socket.assigns.current_user
        )
      end)

    {:ok, list} =
      GroceryPlanner.Shopping.get_shopping_list(
        socket.assigns.selected_list.id,
        tenant: socket.assigns.current_account.id,
        actor: socket.assigns.current_user,
        load: [:items, :total_items, :checked_items, :progress_percentage]
      )

    unchecked_count = Enum.count(results, fn r -> match?({:ok, _}, r) end)

    socket =
      socket
      |> assign(:selected_list, list)
      |> put_flash(
        :info,
        "#{unchecked_count} item#{if unchecked_count != 1, do: "s", else: ""} unchecked"
      )

    {:noreply, socket}
  end

  def handle_event("transfer_to_inventory", %{"storage_location_id" => location_id}, socket) do
    location_id = if location_id == "", do: nil, else: location_id
    transferable = socket.assigns.transferable_items
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user

    results =
      Enum.map(transferable, fn item ->
        attrs = %{
          quantity: item.quantity,
          unit: item.unit,
          purchase_date: Date.utc_today(),
          status: :available
        }

        attrs = if location_id, do: Map.put(attrs, :storage_location_id, location_id), else: attrs

        attrs =
          if item.price do
            Map.put(attrs, :purchase_price, item.price)
          else
            attrs
          end

        GroceryPlanner.Inventory.create_inventory_entry(
          account_id,
          item.grocery_item_id,
          attrs,
          authorize?: false,
          tenant: account_id
        )
      end)

    successful = Enum.count(results, fn result -> match?({:ok, _}, result) end)
    failed = length(results) - successful

    # Reload the list to get updated state
    {:ok, list} =
      GroceryPlanner.Shopping.get_shopping_list(
        socket.assigns.selected_list.id,
        tenant: account_id,
        actor: user,
        load: [:items, :total_items, :checked_items, :progress_percentage]
      )

    message =
      cond do
        failed == 0 && successful > 0 ->
          "#{successful} item#{if successful > 1, do: "s", else: ""} added to inventory"

        successful > 0 && failed > 0 ->
          "#{successful} item#{if successful > 1, do: "s", else: ""} added, #{failed} failed"

        true ->
          "Failed to add items to inventory"
      end

    flash_type = if failed == 0 && successful > 0, do: :info, else: :error

    socket =
      socket
      |> put_flash(flash_type, message)
      |> assign(:show_transfer_modal, false)
      |> assign(:selected_list, list)

    {:noreply, socket}
  end

  def handle_event(
        "add_item",
        %{"name" => name, "quantity" => quantity_str, "unit" => unit} = params,
        socket
      ) do
    quantity = Decimal.new(quantity_str)

    attrs = %{
      shopping_list_id: socket.assigns.selected_list.id,
      name: name,
      quantity: quantity,
      unit: unit
    }

    attrs =
      if params["estimated_price"] && params["estimated_price"] != "" do
        currency = socket.assigns.current_account.currency || "USD"
        Map.put(attrs, :estimated_price, %{amount: params["estimated_price"], currency: currency})
      else
        attrs
      end

    case GroceryPlanner.Shopping.create_shopping_list_item(
           socket.assigns.current_account.id,
           attrs,
           tenant: socket.assigns.current_account.id,
           actor: socket.assigns.current_user
         ) do
      {:ok, _item} ->
        {:ok, list} =
          GroceryPlanner.Shopping.get_shopping_list(
            socket.assigns.selected_list.id,
            tenant: socket.assigns.current_account.id,
            actor: socket.assigns.current_user,
            load: [:items, :total_items, :checked_items, :progress_percentage]
          )

        socket =
          socket
          |> put_flash(:info, "Item added")
          |> assign(:show_add_item_modal, false)
          |> assign(:selected_list, list)

        {:noreply, socket}

      {:error, error} ->
        Logger.error("Failed to add item: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to add item")}
    end
  end

  def handle_event("delete_item", %{"id" => id}, socket) do
    {:ok, item} =
      GroceryPlanner.Shopping.get_shopping_list_item(
        id,
        tenant: socket.assigns.current_account.id,
        actor: socket.assigns.current_user
      )

    case GroceryPlanner.Shopping.destroy_shopping_list_item(item,
           tenant: socket.assigns.current_account.id,
           actor: socket.assigns.current_user
         ) do
      :ok ->
        {:ok, list} =
          GroceryPlanner.Shopping.get_shopping_list(
            socket.assigns.selected_list.id,
            tenant: socket.assigns.current_account.id,
            actor: socket.assigns.current_user,
            load: [:items, :total_items, :checked_items, :progress_percentage]
          )

        socket =
          socket
          |> put_flash(:info, "Item removed")
          |> assign(:selected_list, list)

        {:noreply, socket}

      {:error, error} ->
        Logger.error("Failed to delete item: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to remove item")}
    end
  end

  defp load_shopping_lists(socket) do
    {:ok, all_lists} =
      GroceryPlanner.Shopping.list_active_or_completed_shopping_lists(
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id,
        load: [:total_items, :checked_items, :progress_percentage]
      )

    # Paginate the lists
    page = socket.assigns[:page] || 1
    per_page = socket.assigns[:per_page] || @per_page
    total_count = length(all_lists)
    total_pages = max(1, ceil(total_count / per_page))

    lists =
      all_lists
      |> Enum.drop((page - 1) * per_page)
      |> Enum.take(per_page)

    socket
    |> assign(:shopping_lists, lists)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
  end
end
