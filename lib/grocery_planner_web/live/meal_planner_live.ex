defmodule GroceryPlannerWeb.MealPlannerLive do
  use GroceryPlannerWeb, :live_view
  import GroceryPlannerWeb.UIComponents

  on_mount {GroceryPlannerWeb.Auth, :require_authenticated_user}

  alias GroceryPlanner.AI.MealOptimizer
  alias GroceryPlanner.MealPlanning.Voting
  alias GroceryPlanner.Notifications.ExpirationAlerts
  alias GroceryPlannerWeb.MealPlannerLive.{DataLoader, Terminology, UndoSystem, UndoActions}
  alias GroceryPlannerWeb.MealPlannerLive.{ExplorerLayout, FocusLayout, PowerLayout}

  def mount(_params, _session, socket) do
    voting_active =
      Voting.voting_active?(socket.assigns.current_account.id, socket.assigns.current_user)

    socket = assign(socket, :current_scope, socket.assigns.current_account)

    today = Date.utc_today()
    week_start = get_week_start(today)

    layout = resolve_meal_planner_layout(socket.assigns.current_user)

    socket =
      socket
      |> assign(:voting_active, voting_active)
      |> assign(:meal_planner_layout, layout)
      |> assign(:week_start, week_start)
      |> assign(:days, get_week_days(week_start))
      |> assign(:selected_day, if(layout == "focus", do: today, else: nil))
      # Mobile UI state
      |> assign(:mobile_view, if(layout == "focus", do: "day", else: "week"))
      |> assign(:show_mobile_actions, false)
      # Shared UI state
      |> assign(:show_add_meal_modal, false)
      |> assign(:show_edit_meal_modal, false)
      |> assign(:editing_meal_plan, nil)
      |> assign(:editing_notes_id, nil)
      |> assign(:selected_date, nil)
      |> assign(:selected_meal_type, nil)
      # Populated by DataLoader or specific searches
      |> assign(:available_recipes, [])
      # Semantic search feature flag
      |> assign(:semantic_search_enabled, GroceryPlanner.AI.Embeddings.enabled?())
      # Chain suggestion state
      |> assign(:show_chain_suggestion_modal, false)
      |> assign(:chain_suggestion_base_recipe, nil)
      |> assign(:chain_suggestion_follow_ups, [])
      |> assign(:chain_suggestion_slot, nil)
      |> assign(:selected_follow_up_id, nil)
      # Initialize Explorer-specific state (used in shared template)
      |> assign(:show_explorer_slot_picker, false)
      |> assign(:explorer_picking_recipe, nil)
      |> assign(:explorer_selected_slot, nil)
      # Undo System
      |> assign(:undo_system, UndoSystem.new())
      |> assign(:recipes_loaded, false)
      # Waste Watch & Cook With These
      |> assign(:expiring_count, 0)
      |> assign(:waste_watch_dismissed, false)
      |> assign(:waste_watch_suggestions, nil)
      |> assign(:show_cook_with_modal, false)
      |> assign(:cook_with_inventory, [])
      |> assign(:cook_with_selected, MapSet.new())
      |> assign(:cook_with_suggestions, nil)
      |> load_expiring_count()
      # Load data
      |> DataLoader.load_week_meals()
      # Layout specific init
      |> init_layout(layout)

    {:ok, socket}
  end

  # Helper to render the layout from the template
  def render_layout(assigns) do
    case assigns.meal_planner_layout do
      "explorer" -> ExplorerLayout.render(assigns)
      "focus" -> FocusLayout.render(assigns)
      "power" -> PowerLayout.render(assigns)
      _ -> ExplorerLayout.render(assigns)
    end
  end

  # Layout switching
  def handle_event("meal_planner_set_layout", %{"layout" => layout}, socket)
      when layout in ["explorer", "focus", "power"] do
    case GroceryPlanner.Accounts.User.update(
           socket.assigns.current_user,
           %{meal_planner_layout: layout},
           actor: socket.assigns.current_user
         ) do
      {:ok, user} ->
        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:meal_planner_layout, layout)
          |> assign(:mobile_view, if(layout == "focus", do: "day", else: "week"))
          |> assign(:show_mobile_actions, false)
          |> init_layout(layout)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update layout")}
    end
  end

  # Shared Navigation
  def handle_event("prev_week", _params, socket) do
    week_start = Date.add(socket.assigns.week_start, -7)
    refresh_week(socket, week_start)
  end

  def handle_event("next_week", _params, socket) do
    week_start = Date.add(socket.assigns.week_start, 7)
    refresh_week(socket, week_start)
  end

  def handle_event("today", _params, socket) do
    today = Date.utc_today()
    week_start = get_week_start(today)

    socket =
      cond do
        socket.assigns.meal_planner_layout == "focus" ->
          assign(socket, :selected_day, today)

        socket.assigns.meal_planner_layout == "power" ->
          assign(socket, :mobile_selected_date, today)

        true ->
          socket
      end

    refresh_week(socket, week_start)
  end

  def handle_event("set_mobile_view", %{"view" => view}, socket)
      when view in ["week", "day"] do
    {:noreply, assign(socket, :mobile_view, view)}
  end

  def handle_event("open_mobile_actions", _params, socket) do
    {:noreply, assign(socket, :show_mobile_actions, true)}
  end

  def handle_event("close_mobile_actions", _params, socket) do
    {:noreply, assign(socket, :show_mobile_actions, false)}
  end

  # Shared Modal / Add Meal
  def handle_event("add_meal", %{"date" => date_str, "meal_type" => meal_type}, socket) do
    date = Date.from_iso8601!(date_str)
    meal_type_atom = String.to_existing_atom(meal_type)

    socket =
      socket
      # Ensure recipes are loaded for the picker
      |> DataLoader.load_all_recipes(force: true)
      |> assign(:show_add_meal_modal, true)
      |> assign(:selected_date, date)
      |> assign(:selected_meal_type, meal_type_atom)
      # Reset explorer specific prompt state if it was lingering
      |> assign(:explorer_slot_prompt_open, false)
      |> assign(:explorer_slot_prompt_slot, nil)

    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_add_meal_modal, false)
      |> assign(:selected_date, nil)
      |> assign(:selected_meal_type, nil)
      |> assign(:explorer_slot_prompt_open, false)
      |> assign(:explorer_slot_prompt_slot, nil)
      |> assign(:show_mobile_actions, false)

    {:noreply, socket}
  end

  def handle_event("prevent_close", _params, socket), do: {:noreply, socket}

  def handle_event("search_recipes", %{"value" => search_term}, socket) do
    # Shared search for the modal
    # Use cached all_recipes if available, otherwise fetch
    all_recipes =
      if socket.assigns[:all_recipes_cache] do
        socket.assigns.all_recipes_cache
      else
        {:ok, recipes} =
          GroceryPlanner.Recipes.list_recipes_for_meal_planner(
            actor: socket.assigns.current_user,
            tenant: socket.assigns.current_account.id
          )

        recipes
      end

    recipes =
      if String.trim(search_term) == "" do
        all_recipes
      else
        filter_recipes_by_query(all_recipes, search_term, socket.assigns.current_account.id)
      end

    socket =
      socket
      |> assign(:available_recipes, recipes)
      # Ensure cache is populated if it wasn't
      |> then(fn s ->
        if s.assigns[:all_recipes_cache], do: s, else: assign(s, :all_recipes_cache, all_recipes)
      end)

    {:noreply, socket}
  end

  def handle_event("select_recipe", %{"id" => recipe_id}, socket) do
    # Determine target slot (explorer prompt vs standard modal)
    {selected_date, selected_meal_type} =
      case socket.assigns[:explorer_slot_prompt_slot] do
        %{date: date, meal_type: meal_type} -> {date, meal_type}
        _ -> {socket.assigns.selected_date, socket.assigns.selected_meal_type}
      end

    perform_add_meal(socket, recipe_id, selected_date, selected_meal_type)
  end

  # Shared Actions
  def handle_event("remove_meal", %{"id" => meal_plan_id}, socket) do
    case GroceryPlanner.MealPlanning.get_meal_plan(
           meal_plan_id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id,
           load: [:recipe]
         ) do
      {:ok, meal_plan} ->
        meal_data = %{
          recipe_id: meal_plan.recipe_id,
          scheduled_date: meal_plan.scheduled_date,
          meal_type: meal_plan.meal_type,
          servings: meal_plan.servings,
          notes: meal_plan.notes,
          status: meal_plan.status
        }

        case GroceryPlanner.MealPlanning.destroy_meal_plan(meal_plan,
               actor: socket.assigns.current_user
             ) do
          {:ok, _} ->
            undo_system =
              UndoSystem.push_undo(
                socket.assigns.undo_system,
                UndoActions.delete_meal(meal_data),
                "Meal removed successfully"
              )

            socket =
              socket
              |> assign(:undo_system, undo_system)
              |> DataLoader.load_week_meals()
              # Re-load explorer recipes in case recent list changed
              |> maybe_refresh_layout()

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to remove meal")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Meal not found")}
    end
  end

  def handle_event("edit_meal", %{"id" => meal_plan_id}, socket) do
    {:ok, meal_plan} =
      GroceryPlanner.MealPlanning.get_meal_plan(
        meal_plan_id,
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id,
        load: [:recipe]
      )

    socket =
      socket
      |> assign(:show_edit_meal_modal, true)
      |> assign(:editing_meal_plan, meal_plan)

    {:noreply, socket}
  end

  def handle_event("long_press", %{"id" => id}, socket) do
    handle_event("edit_meal", %{"id" => id}, socket)
  end

  def handle_event("close_edit_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_edit_meal_modal, false)
      |> assign(:editing_meal_plan, nil)

    {:noreply, socket}
  end

  def handle_event("update_meal", %{"servings" => servings, "notes" => notes}, socket) do
    old_attrs = %{
      servings: socket.assigns.editing_meal_plan.servings,
      notes: socket.assigns.editing_meal_plan.notes
    }

    new_attrs = %{
      servings: String.to_integer(servings),
      notes: notes
    }

    result =
      GroceryPlanner.MealPlanning.update_meal_plan(
        socket.assigns.editing_meal_plan,
        new_attrs,
        actor: socket.assigns.current_user
      )

    case result do
      {:ok, meal_plan} ->
        undo_system =
          UndoSystem.push_undo(
            socket.assigns.undo_system,
            UndoActions.update_meal(meal_plan.id, old_attrs, new_attrs),
            "Meal updated successfully"
          )

        socket =
          socket
          |> assign(:undo_system, undo_system)
          |> assign(:show_edit_meal_modal, false)
          |> assign(:editing_meal_plan, nil)
          |> DataLoader.load_week_meals()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update meal")}
    end
  end

  def handle_event("mark_complete", %{"id" => id}, socket) do
    case GroceryPlanner.MealPlanning.get_meal_plan(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, meal_plan} ->
        case GroceryPlanner.MealPlanning.complete_meal_plan(meal_plan,
               actor: socket.assigns.current_user
             ) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Meal marked as completed")
              |> DataLoader.load_week_meals()

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to complete meal")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Meal not found")}
    end
  end

  def handle_event("toggle_edit_notes", %{"id" => id}, socket) do
    id = if socket.assigns.editing_notes_id == id, do: nil, else: id
    {:noreply, assign(socket, :editing_notes_id, id)}
  end

  def handle_event("save_notes", %{"id" => id, "value" => notes}, socket) do
    case GroceryPlanner.MealPlanning.get_meal_plan(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, meal_plan} ->
        case GroceryPlanner.MealPlanning.update_meal_plan(meal_plan, %{notes: notes},
               actor: socket.assigns.current_user
             ) do
          {:ok, _} ->
            socket =
              socket
              |> assign(:editing_notes_id, nil)
              |> DataLoader.load_week_meals()

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to save notes")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Meal not found")}
    end
  end

  def handle_event("swap_meal", %{"id" => id}, socket) do
    case GroceryPlanner.MealPlanning.get_meal_plan(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, meal_plan} ->
        # To swap, we remove the current meal and open the picker for the same slot
        case GroceryPlanner.MealPlanning.destroy_meal_plan(meal_plan,
               actor: socket.assigns.current_user
             ) do
          {:ok, _} ->
            socket =
              socket
              |> DataLoader.load_week_meals()
              |> assign(:selected_date, meal_plan.scheduled_date)
              |> assign(:selected_meal_type, meal_plan.meal_type)
              |> assign(:show_add_meal_modal, true)
              |> DataLoader.load_all_recipes(force: true)

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to initiate swap")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Meal not found")}
    end
  end

  # =============================================================================
  # Power Mode: Drag and Drop Events
  # =============================================================================

  def handle_event("drag_start", params, socket) do
    # Track which meal is being dragged for grocery delta calculation
    meal_id = params["meal_id"]
    {:noreply, assign(socket, :dragging_meal_id, meal_id)}
  end

  def handle_event("sidebar_drag_start", %{"recipe_id" => recipe_id}, socket) do
    # Track which recipe is being dragged from the sidebar for grocery delta calculation
    {:noreply, assign(socket, :dragging_recipe_id, recipe_id)}
  end

  def handle_event("drag_over", params, socket) do
    # Calculate grocery delta when hovering over a target slot
    %{
      "target_date" => target_date_str,
      "target_meal_type" => target_type_str
    } = params

    if socket.assigns.meal_planner_layout == "power" do
      target_date = Date.from_iso8601!(target_date_str)
      target_meal_type = String.to_existing_atom(target_type_str)

      meal_id = socket.assigns[:dragging_meal_id]
      recipe_id = socket.assigns[:dragging_recipe_id]

      delta =
        cond do
          meal_id ->
            calculate_grocery_delta(socket, meal_id, target_date, target_meal_type)

          recipe_id ->
            calculate_grocery_delta_for_recipe(socket, recipe_id, target_date, target_meal_type)

          true ->
            nil
        end

      {:noreply, assign(socket, :grocery_delta, delta)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("drag_end", _params, socket) do
    # Clear drag state and grocery delta
    {:noreply,
     socket
     |> assign(:dragging_meal_id, nil)
     |> assign(:dragging_recipe_id, nil)
     |> assign(:grocery_delta, nil)}
  end

  def handle_event("sidebar_drag_end", _params, socket) do
    # Clear sidebar drag state and grocery delta
    {:noreply,
     socket
     |> assign(:dragging_recipe_id, nil)
     |> assign(:grocery_delta, nil)}
  end

  def handle_event("drop_meal", params, socket) do
    %{
      "meal_id" => meal_id,
      "target_date" => target_date_str,
      "target_meal_type" => target_type_str
    } =
      params

    target_date = Date.from_iso8601!(target_date_str)
    target_meal_type = String.to_existing_atom(target_type_str)

    case GroceryPlanner.MealPlanning.get_meal_plan(meal_id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id,
           load: [:recipe]
         ) do
      {:ok, meal_plan} ->
        old_state = %{
          date: meal_plan.scheduled_date,
          meal_type: meal_plan.meal_type
        }

        case GroceryPlanner.MealPlanning.update_meal_plan(
               meal_plan,
               %{scheduled_date: target_date, meal_type: target_meal_type},
               actor: socket.assigns.current_user
             ) do
          {:ok, _updated} ->
            undo_system =
              UndoSystem.push_undo(
                socket.assigns.undo_system,
                UndoActions.move_meal(meal_id, old_state, %{
                  date: target_date,
                  meal_type: target_meal_type
                }),
                "Meal moved"
              )

            socket =
              socket
              |> assign(:undo_system, undo_system)
              |> DataLoader.load_week_meals()
              |> maybe_refresh_layout()

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to move meal")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Meal not found")}
    end
  end

  def handle_event("drop_recipe", params, socket) do
    %{
      "recipe_id" => recipe_id,
      "target_date" => target_date_str,
      "target_meal_type" => target_type_str
    } =
      params

    target_date = Date.from_iso8601!(target_date_str)
    target_meal_type = String.to_existing_atom(target_type_str)

    # Create a new meal plan from the dropped recipe
    result =
      GroceryPlanner.MealPlanning.create_meal_plan(
        socket.assigns.current_account.id,
        %{
          recipe_id: recipe_id,
          scheduled_date: target_date,
          meal_type: target_meal_type,
          servings: 4
        },
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id
      )

    case result do
      {:ok, meal_plan} ->
        undo_system =
          UndoSystem.push_undo(
            socket.assigns.undo_system,
            UndoActions.create_meal(meal_plan.id),
            "Meal added from sidebar"
          )

        socket =
          socket
          |> assign(:undo_system, undo_system)
          |> DataLoader.load_week_meals()
          |> maybe_refresh_layout()

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add meal")}
    end
  end

  def handle_event("request_swap_confirmation", params, socket) do
    %{
      "dragged_meal_id" => dragged_id,
      "target_meal_id" => target_id,
      "target_date" => target_date_str,
      "target_meal_type" => target_type_str
    } = params

    pending_swap = %{
      dragged_meal_id: dragged_id,
      target_meal_id: target_id,
      target_date: Date.from_iso8601!(target_date_str),
      target_meal_type: String.to_existing_atom(target_type_str)
    }

    {:noreply, assign(socket, :pending_swap, pending_swap)}
  end

  def handle_event("confirm_swap", _params, socket) do
    %{
      dragged_meal_id: dragged_id,
      target_meal_id: target_id
    } = socket.assigns.pending_swap

    # Get both meals
    with {:ok, dragged_meal} <-
           GroceryPlanner.MealPlanning.get_meal_plan(dragged_id,
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_account.id
           ),
         {:ok, target_meal} <-
           GroceryPlanner.MealPlanning.get_meal_plan(target_id,
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_account.id
           ) do
      # Swap the positions
      dragged_old = %{date: dragged_meal.scheduled_date, meal_type: dragged_meal.meal_type}
      target_old = %{date: target_meal.scheduled_date, meal_type: target_meal.meal_type}

      # Update dragged meal to target position
      {:ok, _} =
        GroceryPlanner.MealPlanning.update_meal_plan(
          dragged_meal,
          %{scheduled_date: target_old.date, meal_type: target_old.meal_type},
          actor: socket.assigns.current_user
        )

      # Update target meal to dragged position
      {:ok, _} =
        GroceryPlanner.MealPlanning.update_meal_plan(
          target_meal,
          %{scheduled_date: dragged_old.date, meal_type: dragged_old.meal_type},
          actor: socket.assigns.current_user
        )

      undo_system =
        UndoSystem.push_undo(
          socket.assigns.undo_system,
          UndoActions.swap_meals(dragged_id, target_id, dragged_old, target_old),
          "Meals swapped"
        )

      socket =
        socket
        |> assign(:undo_system, undo_system)
        |> assign(:pending_swap, nil)
        |> DataLoader.load_week_meals()
        |> maybe_refresh_layout()

      {:noreply, socket}
    else
      _ ->
        socket =
          socket
          |> assign(:pending_swap, nil)
          |> put_flash(:error, "Failed to swap meals")

        {:noreply, socket}
    end
  end

  def handle_event("cancel_swap", _params, socket) do
    {:noreply, assign(socket, :pending_swap, nil)}
  end

  # =============================================================================
  # Power Mode: Sidebar and Selection
  # =============================================================================

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns[:sidebar_open])}
  end

  def handle_event("search_sidebar", %{"query" => query}, socket) do
    socket =
      socket
      |> assign(:sidebar_search, query)
      |> PowerLayout.filter_sidebar_recipes(query)

    {:noreply, socket}
  end

  def handle_event("toggle_meal_selection", %{"meal-id" => meal_id}, socket) do
    selected = socket.assigns[:selected_meals] || MapSet.new()

    selected =
      if MapSet.member?(selected, meal_id) do
        MapSet.delete(selected, meal_id)
      else
        MapSet.put(selected, meal_id)
      end

    {:noreply, assign(socket, :selected_meals, selected)}
  end

  def handle_event("select_all", _params, socket) do
    # Select all meals in the current week
    all_meal_ids =
      socket.assigns.week_meals
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> Enum.filter(& &1)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    {:noreply, assign(socket, :selected_meals, all_meal_ids)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_meals, MapSet.new())}
  end

  def handle_event("delete_selected", _params, socket) do
    selected = socket.assigns[:selected_meals] || MapSet.new()

    if MapSet.size(selected) == 0 do
      {:noreply, socket}
    else
      # Delete all selected meals
      Enum.each(selected, fn meal_id ->
        case GroceryPlanner.MealPlanning.get_meal_plan(meal_id,
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_account.id
             ) do
          {:ok, meal_plan} ->
            GroceryPlanner.MealPlanning.destroy_meal_plan(meal_plan,
              actor: socket.assigns.current_user
            )

          _ ->
            :ok
        end
      end)

      socket =
        socket
        |> assign(:selected_meals, MapSet.new())
        |> DataLoader.load_week_meals()
        |> maybe_refresh_layout()
        |> put_flash(:info, "#{MapSet.size(selected)} meal(s) deleted")

      {:noreply, socket}
    end
  end

  # =============================================================================
  # Power Mode: Bulk Operations
  # =============================================================================

  def handle_event("clear_week", _params, socket) do
    # Get all meals in the week
    meals =
      socket.assigns.week_meals
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> Enum.filter(& &1)

    # Delete all
    Enum.each(meals, fn meal ->
      GroceryPlanner.MealPlanning.destroy_meal_plan(meal,
        actor: socket.assigns.current_user
      )
    end)

    socket =
      socket
      |> DataLoader.load_week_meals()
      |> maybe_refresh_layout()
      |> put_flash(:info, "Week cleared (#{length(meals)} meals removed)")

    {:noreply, socket}
  end

  def handle_event("copy_last_week", _params, socket) do
    last_week_start = Date.add(socket.assigns.week_start, -7)
    last_week_end = Date.add(last_week_start, 6)

    # Load last week's meals
    {:ok, last_week_meals} =
      GroceryPlanner.MealPlanning.list_meal_plans_by_date_range(
        last_week_start,
        last_week_end,
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id
      )

    # Create copies for this week
    created_count =
      Enum.reduce(last_week_meals, 0, fn meal, count ->
        new_date = Date.add(meal.scheduled_date, 7)

        case GroceryPlanner.MealPlanning.create_meal_plan(
               socket.assigns.current_account.id,
               %{
                 recipe_id: meal.recipe_id,
                 scheduled_date: new_date,
                 meal_type: meal.meal_type,
                 servings: meal.servings,
                 notes: meal.notes
               },
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_account.id
             ) do
          {:ok, _} -> count + 1
          _ -> count
        end
      end)

    socket =
      socket
      |> DataLoader.load_week_meals()
      |> maybe_refresh_layout()
      |> put_flash(:info, "Copied #{created_count} meals from last week")

    {:noreply, socket}
  end

  def handle_event("auto_fill_week", _params, socket) do
    # Get empty slots
    empty_slots =
      for day <- socket.assigns.days,
          meal_type <- [:breakfast, :lunch, :dinner],
          is_nil(get_in(socket.assigns.week_meals, [day, meal_type])),
          do: {day, meal_type}

    if empty_slots == [] do
      {:noreply, put_flash(socket, :info, "No empty slots to fill")}
    else
      # Sort by availability (can_make first, then by ingredient availability descending)
      {:ok, recipes} =
        GroceryPlanner.Recipes.list_recipes_for_meal_planner(
          actor: socket.assigns.current_user,
          tenant: socket.assigns.current_account.id
        )

      # Sort by availability (can_make first, then by ingredient availability descending)
      sorted_recipes =
        recipes
        |> Enum.sort_by(fn r ->
          availability =
            case Map.get(r, :ingredient_availability) do
              %Decimal{} = d -> Decimal.to_float(d)
              nil -> 0.0
              n when is_number(n) -> n * 1.0
              _ -> 0.0
            end

          {!Map.get(r, :can_make, false), -availability}
        end)

      # Fill slots, avoiding repeats
      {filled_count, _used_recipes} =
        Enum.reduce(empty_slots, {0, MapSet.new()}, fn {day, meal_type}, {count, used} ->
          # Find a recipe not used this week
          recipe = Enum.find(sorted_recipes, fn r -> !MapSet.member?(used, r.id) end)

          if recipe do
            case GroceryPlanner.MealPlanning.create_meal_plan(
                   socket.assigns.current_account.id,
                   %{
                     recipe_id: recipe.id,
                     scheduled_date: day,
                     meal_type: meal_type,
                     servings: 4
                   },
                   actor: socket.assigns.current_user,
                   tenant: socket.assigns.current_account.id
                 ) do
              {:ok, _} -> {count + 1, MapSet.put(used, recipe.id)}
              _ -> {count, used}
            end
          else
            {count, used}
          end
        end)

      socket =
        socket
        |> DataLoader.load_week_meals()
        |> maybe_refresh_layout()
        |> put_flash(:info, "Auto-filled #{filled_count} meals (pantry-optimized)")

      {:noreply, socket}
    end
  end

  def handle_event("generate_shopping_list", _params, socket) do
    start_date = socket.assigns.week_start
    end_date = Date.add(start_date, 6)

    name =
      "Meals for #{Calendar.strftime(start_date, "%b %d")} - #{Calendar.strftime(end_date, "%b %d")}"

    case GroceryPlanner.Shopping.generate_shopping_list_from_meal_plans(
           socket.assigns.current_account.id,
           start_date,
           end_date,
           %{name: name},
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, _list} ->
        {:noreply,
         socket
         |> put_flash(:info, "Shopping list generated!")
         |> push_navigate(to: "/shopping")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to generate shopping list")}
    end
  end

  # Undo Action
  def handle_event("undo", _params, socket) do
    {action, undo_system} = UndoSystem.undo(socket.assigns.undo_system)

    socket = assign(socket, :undo_system, undo_system)

    if action do
      case UndoActions.apply_undo(
             action,
             socket.assigns.current_user,
             socket.assigns.current_account.id
           ) do
        {:ok, _} ->
          socket =
            socket
            |> DataLoader.load_week_meals()
            |> maybe_refresh_layout()

          {:noreply, socket}

        :ok ->
          socket =
            socket
            |> DataLoader.load_week_meals()
            |> maybe_refresh_layout()

          {:noreply, socket}

        _ ->
          {:noreply, put_flash(socket, :error, "Undo failed")}
      end
    else
      {:noreply, socket}
    end
  end

  # Redo Action
  def handle_event("redo", _params, socket) do
    {action, undo_system} = UndoSystem.redo(socket.assigns.undo_system)

    socket = assign(socket, :undo_system, undo_system)

    if action do
      case UndoActions.apply_redo(
             action,
             socket.assigns.current_user,
             socket.assigns.current_account.id
           ) do
        {:ok, _} ->
          socket =
            socket
            |> DataLoader.load_week_meals()
            |> maybe_refresh_layout()

          {:noreply, socket}

        :ok ->
          socket =
            socket
            |> DataLoader.load_week_meals()
            |> maybe_refresh_layout()

          {:noreply, socket}

        _ ->
          {:noreply, put_flash(socket, :error, "Redo failed")}
      end
    else
      {:noreply, socket}
    end
  end

  # Handling Chain Modal Events (Must be here since we kept the logic)
  def handle_event("dismiss_chain_suggestion", _params, socket) do
    {:noreply, close_chain_suggestion_modal(socket)}
  end

  def handle_event("select_follow_up", %{"id" => follow_up_id}, socket) do
    {:noreply, assign(socket, selected_follow_up_id: follow_up_id)}
  end

  def handle_event("accept_chain_suggestion", _params, socket) do
    %{date: date, meal_type: meal_type} = socket.assigns.chain_suggestion_slot

    follow_up_id =
      socket.assigns.selected_follow_up_id ||
        case socket.assigns.chain_suggestion_follow_ups do
          [%{id: id} | _] -> id
          _ -> nil
        end

    if is_nil(follow_up_id) do
      {:noreply, close_chain_suggestion_modal(socket)}
    else
      perform_add_meal(socket, follow_up_id, date, meal_type)
    end
  end

  # --- Waste Watch ---

  def handle_event("dismiss_waste_watch", _params, socket) do
    {:noreply, assign(socket, :waste_watch_dismissed, true)}
  end

  def handle_event("waste_watch_suggestions", _params, socket) do
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user

    case MealOptimizer.suggest_for_expiring(account_id, user, limit: 3) do
      {:ok, suggestions} ->
        {:noreply, assign(socket, :waste_watch_suggestions, suggestions)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't load rescue suggestions.")}
    end
  end

  def handle_event(
        "waste_watch_add_to_plan",
        %{"recipe-id" => recipe_id, "date" => date_str},
        socket
      ) do
    account_id = socket.assigns.current_account.id
    date = Date.from_iso8601!(date_str)

    case GroceryPlanner.MealPlanning.create_meal_plan(
           account_id,
           %{recipe_id: recipe_id, scheduled_date: date, meal_type: :dinner, servings: 2},
           authorize?: false,
           tenant: account_id
         ) do
      {:ok, _} ->
        socket =
          socket
          |> DataLoader.load_week_meals()
          |> maybe_refresh_layout()
          |> put_flash(:info, "Rescue recipe added to plan!")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't add to plan.")}
    end
  end

  # --- Cook With These ---

  def handle_event("open_cook_with_modal", _params, socket) do
    account_id = socket.assigns.current_account.id

    {:ok, entries} =
      GroceryPlanner.Inventory.list_inventory_entries_filtered(
        %{status: :available},
        authorize?: false,
        tenant: account_id
      )

    inventory_items =
      entries
      |> Enum.uniq_by(& &1.grocery_item_id)
      |> Enum.filter(& &1.grocery_item)
      |> Enum.sort_by(& &1.grocery_item.name)

    {:noreply,
     socket
     |> assign(:show_cook_with_modal, true)
     |> assign(:cook_with_inventory, inventory_items)
     |> assign(:cook_with_selected, MapSet.new())
     |> assign(:cook_with_suggestions, nil)}
  end

  def handle_event("close_cook_with_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_cook_with_modal, false)
     |> assign(:cook_with_suggestions, nil)
     |> assign(:cook_with_selected, MapSet.new())}
  end

  def handle_event("toggle_cook_with_ingredient", %{"id" => item_id}, socket) do
    selected = socket.assigns.cook_with_selected

    updated =
      if MapSet.member?(selected, item_id) do
        MapSet.delete(selected, item_id)
      else
        MapSet.put(selected, item_id)
      end

    {:noreply, assign(socket, :cook_with_selected, updated)}
  end

  def handle_event("find_cook_with_recipes", _params, socket) do
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user
    selected_ids = MapSet.to_list(socket.assigns.cook_with_selected)

    if selected_ids == [] do
      {:noreply, put_flash(socket, :info, "Select at least one ingredient.")}
    else
      case MealOptimizer.suggest_for_ingredients(account_id, selected_ids, user, limit: 5) do
        {:ok, suggestions} ->
          {:noreply, assign(socket, :cook_with_suggestions, suggestions)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Couldn't find recipes.")}
      end
    end
  end

  def handle_event("cook_with_add_to_plan", %{"recipe-id" => recipe_id}, socket) do
    account_id = socket.assigns.current_account.id
    today = Date.utc_today()

    case GroceryPlanner.MealPlanning.create_meal_plan(
           account_id,
           %{recipe_id: recipe_id, scheduled_date: today, meal_type: :dinner, servings: 2},
           authorize?: false,
           tenant: account_id
         ) do
      {:ok, _} ->
        socket =
          socket
          |> assign(:show_cook_with_modal, false)
          |> assign(:cook_with_suggestions, nil)
          |> assign(:cook_with_selected, MapSet.new())
          |> DataLoader.load_week_meals()
          |> maybe_refresh_layout()
          |> put_flash(:info, "Recipe added to today's plan!")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't add to plan.")}
    end
  end

  # Delegate catch-all (Must be last handle_event)
  def handle_event(event, params, socket) do
    # Delegate to the current layout module
    layout_module =
      case socket.assigns.meal_planner_layout do
        "explorer" -> ExplorerLayout
        "focus" -> FocusLayout
        "power" -> PowerLayout
        _ -> ExplorerLayout
      end

    if function_exported?(layout_module, :handle_event, 3) do
      layout_module.handle_event(event, params, socket)
    else
      {:noreply, socket}
    end
  end

  # Private helpers for recipe filtering
  defp filter_recipes_by_query(all_recipes, search_term, account_id)
       when byte_size(search_term) >= 3 do
    alias GroceryPlanner.AI.Embeddings

    if Embeddings.enabled?() do
      case Embeddings.hybrid_search(search_term, account_id: account_id, limit: 50) do
        results when is_list(results) and results != [] ->
          # Map search results back to full recipe structs
          result_map =
            Map.new(results, fn %{recipe_id: id} ->
              # Handle both string and binary UUIDs
              {to_string(id), true}
            end)

          matched =
            Enum.filter(all_recipes, fn r ->
              Map.has_key?(result_map, to_string(r.id))
            end)

          # Fallback to keyword search if no matches (e.g., embeddings not ready yet)
          if matched == [] do
            filter_recipes_by_name(all_recipes, search_term)
          else
            matched
          end

        _ ->
          filter_recipes_by_name(all_recipes, search_term)
      end
    else
      filter_recipes_by_name(all_recipes, search_term)
    end
  end

  defp filter_recipes_by_query(all_recipes, search_term, _account_id) do
    # Query too short, use keyword search
    filter_recipes_by_name(all_recipes, search_term)
  end

  defp filter_recipes_by_name(all_recipes, search_term) do
    Enum.filter(all_recipes, &GroceryPlanner.Recipes.name_matches?(&1, search_term))
  end

  # Messages from Layouts
  def handle_info(
        {:add_meal_internal, %{recipe_id: recipe_id, date: date, meal_type: meal_type}},
        socket
      ) do
    perform_add_meal(socket, recipe_id, date, meal_type)
  end

  def handle_info({:refresh_meals}, socket) do
    socket =
      socket
      |> DataLoader.load_week_meals()

    {:noreply, socket}
  end

  def handle_info({:open_add_meal_modal, %{date: date, meal_type: meal_type}}, socket) do
    # We call the handle_event logic
    handle_event(
      "add_meal",
      %{"date" => Date.to_iso8601(date), "meal_type" => to_string(meal_type)},
      socket
    )
  end

  def handle_info({:toggle_favorite, recipe_id}, socket) do
    # This logic was in explorer_toggle_favorite
    with {:ok, recipe} <-
           GroceryPlanner.Recipes.get_recipe(recipe_id,
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_account.id
           ),
         {:ok, _updated} <-
           GroceryPlanner.Recipes.update_recipe(
             recipe,
             %{is_favorite: !recipe.is_favorite},
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_account.id
           ) do
      socket =
        socket
        # Invalidate cache so recipes are reloaded with updated favorite status
        |> assign(:recipes_loaded, false)
        |> maybe_refresh_layout()

      {:noreply, socket}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Failed to update favorite")}
    end
  end

  # Private Helpers

  defp init_layout(socket, layout) do
    case layout do
      "explorer" -> ExplorerLayout.init(socket)
      "focus" -> FocusLayout.init(socket)
      "power" -> PowerLayout.init(socket)
      _ -> ExplorerLayout.init(socket)
    end
  end

  defp refresh_week(socket, week_start) do
    socket
    |> assign(:week_start, week_start)
    |> assign(:days, get_week_days(week_start))
    |> assign(:selected_day, maybe_clamp_selected_day(socket.assigns[:selected_day], week_start))
    |> DataLoader.load_week_meals()
    |> maybe_refresh_layout()
    |> then(&{:noreply, &1})
  end

  defp maybe_clamp_selected_day(nil, _week_start), do: nil

  defp maybe_clamp_selected_day(selected_day, week_start) do
    week_end = Date.add(week_start, 6)

    cond do
      Date.compare(selected_day, week_start) == :lt -> week_start
      Date.compare(selected_day, week_end) == :gt -> week_start
      true -> selected_day
    end
  end

  defp maybe_refresh_layout(socket) do
    # Re-run init logic for the current layout to refresh lists (e.g. recents)
    init_layout(socket, socket.assigns.meal_planner_layout)
  end

  defp calculate_grocery_delta(socket, meal_id, target_date, target_meal_type) do
    # Get current week meals (structure: %{date => %{meal_type => meal}})
    week_meals = socket.assigns[:week_meals] || %{}

    # Flatten to a list of meals
    current_meals =
      week_meals
      |> Enum.flat_map(fn {_date, meals_by_type} ->
        meals_by_type |> Map.values() |> Enum.reject(&is_nil/1)
      end)

    # Find the meal being dragged
    dragged_meal = Enum.find(current_meals, &(&1.id == meal_id))

    if dragged_meal do
      # Check if target slot is already occupied
      target_meal =
        Enum.find(current_meals, fn m ->
          m.scheduled_date == target_date && m.meal_type == target_meal_type && m.id != meal_id
        end)

      # Calculate current grocery impact
      current_impact =
        GroceryPlanner.MealPlanning.GroceryImpact.calculate_impact(
          current_meals,
          socket.assigns.current_account.id,
          socket.assigns.current_user
        )

      # Simulate the week after the move
      hypothetical_meals =
        current_meals
        |> Enum.reject(&(&1.id == meal_id))
        |> Enum.reject(fn m -> target_meal && m.id == target_meal.id end)
        |> then(fn meals ->
          # Add the moved meal at new position
          [
            Map.merge(dragged_meal, %{scheduled_date: target_date, meal_type: target_meal_type})
            | meals
          ]
        end)
        |> then(fn meals ->
          # If there was a swap, add the swapped meal at the dragged meal's old position
          if target_meal do
            [
              Map.merge(target_meal, %{
                scheduled_date: dragged_meal.scheduled_date,
                meal_type: dragged_meal.meal_type
              })
              | meals
            ]
          else
            meals
          end
        end)

      # Calculate hypothetical grocery impact
      hypothetical_impact =
        GroceryPlanner.MealPlanning.GroceryImpact.calculate_impact(
          hypothetical_meals,
          socket.assigns.current_account.id,
          socket.assigns.current_user
        )

      # Calculate delta
      current_item_ids = MapSet.new(current_impact, & &1.grocery_item_id)
      hypothetical_item_ids = MapSet.new(hypothetical_impact, & &1.grocery_item_id)

      added = MapSet.difference(hypothetical_item_ids, current_item_ids) |> MapSet.to_list()
      removed = MapSet.difference(current_item_ids, hypothetical_item_ids) |> MapSet.to_list()

      %{
        added: added,
        removed: removed,
        added_count: length(added),
        removed_count: length(removed)
      }
    else
      nil
    end
  end

  defp calculate_grocery_delta_for_recipe(socket, recipe_id, target_date, target_meal_type) do
    # Find the recipe from available recipes (already loaded with ingredients)
    recipe =
      Enum.find(socket.assigns[:available_recipes] || [], &(&1.id == recipe_id))

    if recipe do
      week_meals = socket.assigns[:week_meals] || %{}

      current_meals =
        week_meals
        |> Enum.flat_map(fn {_date, meals_by_type} ->
          meals_by_type |> Map.values() |> Enum.reject(&is_nil/1)
        end)

      # Calculate current grocery impact
      current_impact =
        GroceryPlanner.MealPlanning.GroceryImpact.calculate_impact(
          current_meals,
          socket.assigns.current_account.id,
          socket.assigns.current_user
        )

      # Build a hypothetical meal plan struct for the recipe being added
      hypothetical_meal = %{
        id: "hypothetical-sidebar-drag",
        recipe: recipe,
        recipe_id: recipe.id,
        servings: recipe.servings || 4,
        scheduled_date: target_date,
        meal_type: target_meal_type
      }

      # If target slot is occupied, the existing meal gets replaced
      hypothetical_meals =
        current_meals
        |> Enum.reject(fn m ->
          m.scheduled_date == target_date && m.meal_type == target_meal_type
        end)
        |> List.insert_at(0, hypothetical_meal)

      # Calculate hypothetical grocery impact
      hypothetical_impact =
        GroceryPlanner.MealPlanning.GroceryImpact.calculate_impact(
          hypothetical_meals,
          socket.assigns.current_account.id,
          socket.assigns.current_user
        )

      # Calculate delta
      current_item_ids = MapSet.new(current_impact, & &1.grocery_item_id)
      hypothetical_item_ids = MapSet.new(hypothetical_impact, & &1.grocery_item_id)

      added = MapSet.difference(hypothetical_item_ids, current_item_ids) |> MapSet.to_list()
      removed = MapSet.difference(current_item_ids, hypothetical_item_ids) |> MapSet.to_list()

      %{
        added: added,
        removed: removed,
        added_count: length(added),
        removed_count: length(removed)
      }
    else
      nil
    end
  end

  defp resolve_meal_planner_layout(user) do
    case Map.get(user, :meal_planner_layout) do
      "focus" -> "focus"
      "power" -> "power"
      _ -> "explorer"
    end
  end

  defp get_week_start(date) do
    day_of_week = Date.day_of_week(date)
    Date.add(date, -(day_of_week - 1))
  end

  defp get_week_days(week_start) do
    Enum.map(0..6, fn i -> Date.add(week_start, i) end)
  end

  defp perform_add_meal(socket, recipe_id, date, meal_type) do
    # Logic extracted from select_recipe
    result =
      GroceryPlanner.MealPlanning.create_meal_plan(
        socket.assigns.current_account.id,
        %{
          recipe_id: recipe_id,
          scheduled_date: date,
          meal_type: meal_type,
          servings: 4
        },
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id
      )

    case result do
      {:ok, meal_plan} ->
        undo_system =
          UndoSystem.push_undo(
            socket.assigns.undo_system,
            UndoActions.create_meal(meal_plan.id),
            "Meal added successfully"
          )

        recipe = Enum.find(socket.assigns.available_recipes, &(&1.id == recipe_id))

        socket =
          socket
          |> assign(:undo_system, undo_system)
          |> assign(:show_add_meal_modal, false)
          |> assign(:explorer_slot_prompt_open, false)
          |> assign(:explorer_slot_prompt_slot, nil)
          |> assign(:selected_date, nil)
          |> assign(:selected_meal_type, nil)
          |> DataLoader.load_week_meals()
          |> maybe_refresh_layout()
          |> maybe_show_chain_suggestion(recipe, date, meal_type)

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to add meal")}
    end
  end

  # Chain Suggestion Logic (Kept here for now as it uses Modal state)

  defp maybe_show_chain_suggestion(socket, nil, _date, _meal_type), do: socket

  defp maybe_show_chain_suggestion(socket, recipe, date, meal_type) do
    # ... logic from original file ...
    # We need to copy the chain logic helper functions or move them to a helper module
    # For now, I'll assume they are needed and will paste them back.
    follow_ups = chain_follow_up_candidates(recipe)

    if follow_ups == [] do
      socket
    else
      case calculate_suggested_slot(socket, date, meal_type) do
        nil ->
          socket

        slot ->
          socket
          |> assign(:show_chain_suggestion_modal, true)
          |> assign(:chain_suggestion_base_recipe, chain_base_recipe(recipe))
          |> assign(:chain_suggestion_follow_ups, follow_ups)
          |> assign(:chain_suggestion_slot, slot)
          |> assign(:selected_follow_up_id, hd(follow_ups).id)
      end
    end
  end

  # Chain helpers (Private)
  defp chain_base_recipe(%{is_follow_up: true, parent_recipe: parent}) when is_map(parent),
    do: parent

  defp chain_base_recipe(recipe), do: recipe

  defp chain_follow_up_candidates(%{is_base_recipe: true, follow_up_recipes: follow_ups})
       when is_list(follow_ups),
       do: follow_ups

  defp chain_follow_up_candidates(%{
         is_follow_up: true,
         parent_recipe: %{follow_up_recipes: follow_ups}
       })
       when is_list(follow_ups),
       do: follow_ups

  defp chain_follow_up_candidates(
         %{recipe_ingredients: ingredients, parent_recipe: parent} = recipe
       )
       when is_list(ingredients) do
    if Enum.any?(ingredients, &(&1.usage_type == :leftover)) do
      cond do
        recipe.is_base_recipe && is_list(recipe.follow_up_recipes) ->
          recipe.follow_up_recipes

        recipe.is_follow_up && is_map(parent) && is_list(parent.follow_up_recipes) ->
          parent.follow_up_recipes

        true ->
          []
      end
    else
      []
    end
  end

  defp chain_follow_up_candidates(%{recipe_ingredients: ingredients} = recipe)
       when is_list(ingredients) do
    if Enum.any?(ingredients, &(&1.usage_type == :leftover)) do
      cond do
        recipe.is_base_recipe && is_list(recipe.follow_up_recipes) ->
          recipe.follow_up_recipes

        recipe.is_follow_up && is_map(recipe.parent_recipe) &&
            is_list(recipe.parent_recipe.follow_up_recipes) ->
          recipe.parent_recipe.follow_up_recipes

        true ->
          []
      end
    else
      []
    end
  end

  defp chain_follow_up_candidates(_recipe), do: []

  defp calculate_suggested_slot(socket, base_date, base_meal_type) do
    candidates = get_slot_candidates(base_date, base_meal_type)

    Enum.find(candidates, fn {date, meal_type} ->
      not slot_occupied?(socket.assigns.meal_plans, date, meal_type)
    end)
    |> case do
      nil -> nil
      {date, meal_type} -> %{date: date, meal_type: meal_type}
    end
  end

  defp get_slot_candidates(base_date, :breakfast) do
    [
      {base_date, :lunch},
      {base_date, :dinner},
      {Date.add(base_date, 1), :lunch}
    ]
  end

  defp get_slot_candidates(base_date, :lunch) do
    [
      {base_date, :dinner},
      {Date.add(base_date, 1), :lunch},
      {Date.add(base_date, 1), :dinner}
    ]
  end

  defp get_slot_candidates(base_date, :dinner) do
    [
      {Date.add(base_date, 1), :lunch},
      {Date.add(base_date, 1), :dinner}
    ]
  end

  defp get_slot_candidates(base_date, :snack), do: get_slot_candidates(base_date, :lunch)

  defp slot_occupied?(meal_plans, date, meal_type) do
    Enum.any?(meal_plans, fn mp -> mp.scheduled_date == date && mp.meal_type == meal_type end)
  end

  defp close_chain_suggestion_modal(socket) do
    socket
    |> assign(:show_chain_suggestion_modal, false)
    |> assign(:chain_suggestion_base_recipe, nil)
    |> assign(:chain_suggestion_follow_ups, [])
    |> assign(:chain_suggestion_slot, nil)
    |> assign(:selected_follow_up_id, nil)
  end

  defp load_expiring_count(socket) do
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user

    case ExpirationAlerts.get_expiring_summary(account_id, user, days_threshold: 7) do
      {:ok, summary} -> assign(socket, :expiring_count, summary.total_count)
      _ -> socket
    end
  end
end
