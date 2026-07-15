defmodule GroceryPlannerWeb.MealPlannerLive.UndoSystem do
  @max_stack_size 20

  defstruct [:undo_stack, :redo_stack, :toast]

  def new do
    %__MODULE__{
      undo_stack: [],
      redo_stack: [],
      toast: nil
    }
  end

  def push_undo(system, action, message) do
    %{
      system
      | undo_stack: Enum.take([action | system.undo_stack], @max_stack_size),
        redo_stack: [],
        toast: %{message: message, action: :undo, expires_at: now_plus(5)}
    }
  end

  def undo(system) do
    case system.undo_stack do
      [] ->
        {nil, system}

      [action | rest] ->
        {action,
         %{
           system
           | undo_stack: rest,
             redo_stack: Enum.take([action | system.redo_stack], @max_stack_size),
             toast: %{message: "Action undone", action: nil, expires_at: now_plus(3)}
         }}
    end
  end

  def redo(system) do
    case system.redo_stack do
      [] ->
        {nil, system}

      [action | rest] ->
        {action,
         %{
           system
           | redo_stack: rest,
             undo_stack: Enum.take([action | system.undo_stack], @max_stack_size),
             toast: %{message: "Action redone", action: nil, expires_at: now_plus(3)}
         }}
    end
  end

  def clear_toast(system), do: %{system | toast: nil}

  defp now_plus(seconds), do: DateTime.add(DateTime.utc_now(), seconds)
end

defmodule GroceryPlannerWeb.MealPlannerLive.UndoActions do
  alias GroceryPlanner.MealPlanning

  def create_meal(meal_id), do: {:create_meal, meal_id}
  def delete_meal(meal_data), do: {:delete_meal, meal_data}
  def move_meal(meal_id, from, to), do: {:move_meal, meal_id, from, to}

  def swap_meals(meal_a_id, meal_b_id, pos_a, pos_b),
    do: {:swap_meals, meal_a_id, meal_b_id, pos_a, pos_b}

  def update_meal(meal_id, old_attrs, new_attrs),
    do: {:update_meal, meal_id, old_attrs, new_attrs}

  def apply_undo({:create_meal, meal_id}, actor, tenant) do
    case MealPlanning.get_meal_plan(meal_id, actor: actor, tenant: tenant) do
      {:ok, meal_plan} ->
        MealPlanning.destroy_meal_plan(meal_plan, actor: actor)

      {:error, _} ->
        {:error, :not_found}
    end
  end

  def apply_undo({:delete_meal, meal_data}, actor, tenant) do
    # Restore-and-replace: put the meal back, replacing whatever now occupies the
    # slot (grocery_planner-vzc). place_meal accepts slot content only, so drop
    # the status/other keys the delete snapshot carried.
    attrs = Map.take(meal_data, [:recipe_id, :scheduled_date, :meal_type, :servings, :notes])
    MealPlanning.place_meal(attrs, actor: actor, tenant: tenant)
  end

  def apply_undo({:move_meal, meal_id, from, _to}, actor, tenant) do
    with {:ok, meal_plan} <- MealPlanning.get_meal_plan(meal_id, actor: actor, tenant: tenant) do
      MealPlanning.update_meal_plan(
        meal_plan,
        %{
          scheduled_date: from.date,
          meal_type: from.meal_type
        },
        actor: actor
      )
    end
  end

  def apply_undo({:update_meal, meal_id, old_attrs, _new_attrs}, actor, tenant) do
    with {:ok, meal_plan} <- MealPlanning.get_meal_plan(meal_id, actor: actor, tenant: tenant) do
      MealPlanning.update_meal_plan(meal_plan, old_attrs, actor: actor)
    end
  end

  def apply_undo({:swap_meals, meal_a_id, meal_b_id, _pos_a, _pos_b}, actor, tenant) do
    # The forward swap left the two meals in each other's slots; swapping their
    # current slots again atomically restores the originals. See swap_meal_slots
    # for why this must be one statement (grocery_planner-vzc).
    with {:ok, meal_a} <- MealPlanning.get_meal_plan(meal_a_id, actor: actor, tenant: tenant),
         {:ok, meal_b} <- MealPlanning.get_meal_plan(meal_b_id, actor: actor, tenant: tenant) do
      MealPlanning.swap_meal_slots(meal_a, meal_b)
    end
  end

  # Redo actions (reapply the forward action)
  def apply_redo({:create_meal, _meal_id}, _actor, _tenant) do
    # Redo create is the same as undo (delete it again)
    # This shouldn't happen in practice, but handle it
    :ok
  end

  def apply_redo({:delete_meal, _meal_data}, _actor, _tenant) do
    # Redo delete is the same as undo (recreate it)
    :ok
  end

  def apply_redo({:move_meal, meal_id, _from, to}, actor, tenant) do
    # For redo, move to the target position
    with {:ok, meal_plan} <- MealPlanning.get_meal_plan(meal_id, actor: actor, tenant: tenant) do
      MealPlanning.update_meal_plan(
        meal_plan,
        %{
          scheduled_date: to.date,
          meal_type: to.meal_type
        },
        actor: actor
      )
    end
  end

  def apply_redo({:update_meal, meal_id, _old_attrs, new_attrs}, actor, tenant) do
    # For redo, apply the new attributes
    with {:ok, meal_plan} <- MealPlanning.get_meal_plan(meal_id, actor: actor, tenant: tenant) do
      MealPlanning.update_meal_plan(meal_plan, new_attrs, actor: actor)
    end
  end

  def apply_redo({:swap_meals, meal_a_id, meal_b_id, pos_a, pos_b}, actor, tenant) do
    # For redo, swap them to their swapped positions (same as undo)
    apply_undo({:swap_meals, meal_a_id, meal_b_id, pos_a, pos_b}, actor, tenant)
  end
end
