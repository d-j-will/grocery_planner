defmodule GroceryPlannerWeb.MealPlannerLive.DataLoader do
  @moduledoc """
  Shared data loading functions for all layouts.
  """

  import Phoenix.Component, only: [assign: 3]
  alias GroceryPlanner.{MealPlanning, Recipes}
  require Logger

  defp warn_on_slot_collision(date, meals) do
    dupes =
      meals
      |> Enum.frequencies_by(& &1.meal_type)
      |> Enum.filter(fn {_type, count} -> count > 1 end)

    if dupes != [] do
      Logger.warning(
        "Duplicate meal-plan slots on #{date}: #{inspect(dupes)} — the unique slot " <>
          "index should prevent this (grocery_planner-vzc)"
      )
    end
  end

  def load_week_meals(socket) do
    account_id = socket.assigns.current_account.id
    week_start = socket.assigns.week_start
    week_end = Date.add(week_start, 6)

    # Note: Ideally this should be a filtered query on the resource
    {:ok, all_meal_plans} =
      MealPlanning.list_meal_plans(
        actor: socket.assigns.current_user,
        tenant: account_id,
        load: [
          :requires_shopping,
          recipe: [
            :can_make,
            :ingredient_availability,
            :recipe_ingredients,
            recipe_ingredients: :grocery_item
          ]
        ]
      )

    meal_plans =
      Enum.filter(all_meal_plans, fn mp ->
        Date.compare(mp.scheduled_date, week_start) in [:eq, :gt] and
          Date.compare(mp.scheduled_date, week_end) in [:eq, :lt]
      end)

    # Assign both the list (for compatibility) and the map (for O(1) access).
    # Keying by meal_type collapses any duplicate slot to the last row; the
    # partial unique index (grocery_planner-vzc) should make that impossible, so
    # surface a collision rather than silently masking hidden orphan rows.
    week_meals_map =
      meal_plans
      |> Enum.group_by(& &1.scheduled_date)
      |> Map.new(fn {date, meals} ->
        warn_on_slot_collision(date, meals)
        {date, Enum.into(meals, %{}, &{&1.meal_type, &1})}
      end)

    socket
    |> assign(:meal_plans, meal_plans)
    |> assign(:week_meals, week_meals_map)
    |> compute_shopping_needs()
  end

  def load_favorite_recipes(socket) do
    {:ok, favorites} =
      Recipes.list_favorite_recipes(
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id
      )

    assign(socket, :favorite_recipes, favorites)
  end

  def load_recent_recipes(socket, days \\ 14) do
    cutoff = Date.add(Date.utc_today(), -days)

    {:ok, recent_plans} =
      MealPlanning.list_recent_meal_plans(
        cutoff,
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id,
        load: [:recipe]
      )

    recent_recipes =
      recent_plans
      |> Enum.map(& &1.recipe)
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(5)

    assign(socket, :recent_recipes, recent_recipes)
  end

  def load_all_recipes(socket, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    socket =
      if force || !socket.assigns[:recipes_loaded] do
        {:ok, all_recipes} =
          Recipes.list_recipes_for_meal_planner(
            actor: socket.assigns.current_user,
            tenant: socket.assigns.current_account.id
          )

        socket
        |> assign(:all_recipes_cache, all_recipes)
        |> assign(:recipes_loaded, true)
      else
        socket
      end

    assign(socket, :available_recipes, socket.assigns.all_recipes_cache)
  end

  def compute_shopping_needs(socket) do
    impact =
      GroceryPlanner.MealPlanning.GroceryImpact.calculate_impact(
        socket.assigns.meal_plans,
        socket.assigns.current_account.id,
        socket.assigns.current_user
      )

    assign(socket, :week_shopping_items, impact)
  end

  def compute_day_shopping_needs(socket, date) do
    day_meals =
      socket.assigns.meal_plans
      |> Enum.filter(&(&1.scheduled_date == date))

    impact =
      GroceryPlanner.MealPlanning.GroceryImpact.calculate_impact(
        day_meals,
        socket.assigns.current_account.id,
        socket.assigns.current_user
      )

    assign(socket, :day_shopping_items, impact)
  end
end
