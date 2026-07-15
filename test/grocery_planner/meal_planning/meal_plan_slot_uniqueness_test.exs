defmodule GroceryPlanner.MealPlanning.MealPlanSlotUniquenessTest do
  @moduledoc """
  Boundary tests for the (account_id, scheduled_date, meal_type) slot uniqueness
  guarantee (grocery_planner-vzc): a partial unique index (live rows only) plus
  the `:place` upsert action that gives interactive/undo paths replace semantics.
  """
  use GroceryPlanner.DataCase, async: true

  import GroceryPlanner.MealPlanningTestHelpers, only: [create_recipe: 3]

  alias GroceryPlanner.MealPlanning
  alias GroceryPlanner.MealPlanning.MealPlan
  require Ash.Query

  defp place(account, user, attrs) do
    MealPlanning.place_meal(attrs, actor: user, tenant: account.id)
  end

  defp create(account, user, attrs) do
    MealPlanning.create_meal_plan(account.id, attrs, actor: user, tenant: account.id)
  end

  defp live_slot_count(account, date, meal_type) do
    MealPlan
    |> Ash.Query.filter(
      account_id == ^account.id and scheduled_date == ^date and meal_type == ^meal_type and
        is_nil(deleted_at)
    )
    |> Ash.read!(authorize?: false, tenant: account.id)
    |> length()
  end

  describe "slot uniqueness" do
    test "rejects a second live meal in the same (date, meal_type) slot" do
      {account, user} = create_account_and_user()
      r1 = create_recipe(account, user, %{})
      r2 = create_recipe(account, user, %{})
      today = Date.utc_today()

      assert {:ok, _} =
               create(account, user, %{
                 recipe_id: r1.id,
                 scheduled_date: today,
                 meal_type: :dinner
               })

      assert {:error, %Ash.Error.Invalid{}} =
               create(account, user, %{
                 recipe_id: r2.id,
                 scheduled_date: today,
                 meal_type: :dinner
               })

      assert live_slot_count(account, today, :dinner) == 1
    end

    test "the same slot is independent per account (tenant isolation)" do
      {account_a, user_a} = create_account_and_user()
      {account_b, user_b} = create_account_and_user()
      ra = create_recipe(account_a, user_a, %{})
      rb = create_recipe(account_b, user_b, %{})
      today = Date.utc_today()

      assert {:ok, _} =
               create(account_a, user_a, %{
                 recipe_id: ra.id,
                 scheduled_date: today,
                 meal_type: :lunch
               })

      assert {:ok, _} =
               create(account_b, user_b, %{
                 recipe_id: rb.id,
                 scheduled_date: today,
                 meal_type: :lunch
               })
    end

    # The discriminating test for the PARTIAL predicate: a full unique index would
    # reject this because the soft-deleted row still occupies the slot columns.
    test "a slot can be re-used after its meal is soft-deleted" do
      {account, user} = create_account_and_user()
      r1 = create_recipe(account, user, %{})
      r2 = create_recipe(account, user, %{})
      today = Date.utc_today()

      {:ok, first} =
        create(account, user, %{recipe_id: r1.id, scheduled_date: today, meal_type: :dinner})

      :ok = Ash.destroy!(first, actor: user, tenant: account.id)

      assert {:ok, _second} =
               create(account, user, %{
                 recipe_id: r2.id,
                 scheduled_date: today,
                 meal_type: :dinner
               })

      assert live_slot_count(account, today, :dinner) == 1
    end
  end

  describe "place_meal (create-or-replace)" do
    test "creates the meal when the slot is empty" do
      {account, user} = create_account_and_user()
      r1 = create_recipe(account, user, %{})
      today = Date.utc_today()

      assert {:ok, meal} =
               place(account, user, %{recipe_id: r1.id, scheduled_date: today, meal_type: :dinner})

      assert meal.recipe_id == r1.id
      assert meal.status == :planned
      assert live_slot_count(account, today, :dinner) == 1
    end

    test "replaces the occupant when the slot is filled, leaving exactly one live meal" do
      {account, user} = create_account_and_user()
      r1 = create_recipe(account, user, %{})
      r2 = create_recipe(account, user, %{})
      today = Date.utc_today()

      {:ok, _} =
        place(account, user, %{recipe_id: r1.id, scheduled_date: today, meal_type: :dinner})

      assert {:ok, replaced} =
               place(account, user, %{recipe_id: r2.id, scheduled_date: today, meal_type: :dinner})

      assert replaced.recipe_id == r2.id
      assert live_slot_count(account, today, :dinner) == 1
    end

    test "a replaced slot resets a completed meal back to planned" do
      {account, user} = create_account_and_user()
      r1 = create_recipe(account, user, %{})
      r2 = create_recipe(account, user, %{})
      today = Date.utc_today()

      {:ok, meal} =
        place(account, user, %{recipe_id: r1.id, scheduled_date: today, meal_type: :dinner})

      {:ok, _} = MealPlanning.complete_meal_plan(meal, actor: user, tenant: account.id)

      assert {:ok, replaced} =
               place(account, user, %{recipe_id: r2.id, scheduled_date: today, meal_type: :dinner})

      assert replaced.recipe_id == r2.id
      assert replaced.status == :planned
      assert replaced.completed_at == nil
    end
  end

  describe "swap_meal_slots" do
    # Two sequential updates would move the first meal onto the second's still
    # occupied slot and trip the unique index; the atomic swap must not.
    test "atomically swaps two occupied slots without tripping the unique index" do
      {account, user} = create_account_and_user()
      r1 = create_recipe(account, user, %{})
      r2 = create_recipe(account, user, %{})
      today = Date.utc_today()
      tomorrow = Date.add(today, 1)

      {:ok, a} =
        place(account, user, %{recipe_id: r1.id, scheduled_date: today, meal_type: :dinner})

      {:ok, b} =
        place(account, user, %{recipe_id: r2.id, scheduled_date: tomorrow, meal_type: :lunch})

      assert :ok = MealPlanning.swap_meal_slots(a, b)

      a2 = Ash.get!(MealPlan, a.id, actor: user, tenant: account.id)
      b2 = Ash.get!(MealPlan, b.id, actor: user, tenant: account.id)

      assert {a2.scheduled_date, a2.meal_type} == {tomorrow, :lunch}
      assert {b2.scheduled_date, b2.meal_type} == {today, :dinner}
      assert live_slot_count(account, today, :dinner) == 1
      assert live_slot_count(account, tomorrow, :lunch) == 1
    end

    test "undo of a swap restores both meals to their original slots" do
      {account, user} = create_account_and_user()
      r1 = create_recipe(account, user, %{})
      r2 = create_recipe(account, user, %{})
      today = Date.utc_today()
      tomorrow = Date.add(today, 1)

      {:ok, a} =
        place(account, user, %{recipe_id: r1.id, scheduled_date: today, meal_type: :dinner})

      {:ok, b} =
        place(account, user, %{recipe_id: r2.id, scheduled_date: tomorrow, meal_type: :lunch})

      :ok = MealPlanning.swap_meal_slots(a, b)

      # Undo swaps their (now exchanged) slots back — pos args are unused.
      assert :ok =
               GroceryPlannerWeb.MealPlannerLive.UndoActions.apply_undo(
                 {:swap_meals, a.id, b.id, %{date: today, meal_type: :dinner},
                  %{date: tomorrow, meal_type: :lunch}},
                 user,
                 account.id
               )

      a2 = Ash.get!(MealPlan, a.id, actor: user, tenant: account.id)
      b2 = Ash.get!(MealPlan, b.id, actor: user, tenant: account.id)

      assert {a2.scheduled_date, a2.meal_type} == {today, :dinner}
      assert {b2.scheduled_date, b2.meal_type} == {tomorrow, :lunch}
    end
  end
end
