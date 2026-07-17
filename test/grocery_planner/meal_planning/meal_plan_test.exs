defmodule GroceryPlanner.MealPlanning.MealPlanTest do
  use GroceryPlanner.DataCase, async: true
  alias GroceryPlanner.MealPlanning.MealPlan

  describe "meal plan creation" do
    test "creates a meal plan with valid attributes" do
      {account, user} = create_account_and_user()

      # Create a recipe first
      recipe = create_recipe(account, user, %{name: "Test Recipe"})

      today = Date.utc_today()

      assert {:ok, meal_plan} =
               MealPlan
               |> Ash.Changeset.new()
               |> Ash.Changeset.set_argument(:account_id, account.id)
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   recipe_id: recipe.id,
                   scheduled_date: today,
                   meal_type: :lunch,
                   servings: 4
                 }
               )
               |> Ash.create(actor: user, tenant: account.id)

      assert meal_plan.recipe_id == recipe.id
      assert meal_plan.scheduled_date == today
      assert meal_plan.meal_type == :lunch
      assert meal_plan.servings == 4
      assert meal_plan.status == :planned
      assert meal_plan.account_id == account.id
    end

    test "requires recipe_id" do
      {account, user} = create_account_and_user()
      today = Date.utc_today()

      assert {:error, %Ash.Error.Invalid{}} =
               MealPlan
               |> Ash.Changeset.new()
               |> Ash.Changeset.set_argument(:account_id, account.id)
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   scheduled_date: today,
                   meal_type: :lunch,
                   servings: 4
                 }
               )
               |> Ash.create(actor: user, tenant: account.id)
    end

    test "requires scheduled_date" do
      {account, user} = create_account_and_user()
      recipe = create_recipe(account, user, %{name: "Test Recipe"})

      assert {:error, %Ash.Error.Invalid{}} =
               MealPlan
               |> Ash.Changeset.new()
               |> Ash.Changeset.set_argument(:account_id, account.id)
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   recipe_id: recipe.id,
                   meal_type: :lunch,
                   servings: 4
                 }
               )
               |> Ash.create(actor: user, tenant: account.id)
    end

    test "requires meal_type" do
      {account, user} = create_account_and_user()
      recipe = create_recipe(account, user, %{name: "Test Recipe"})
      today = Date.utc_today()

      assert {:error, %Ash.Error.Invalid{}} =
               MealPlan
               |> Ash.Changeset.new()
               |> Ash.Changeset.set_argument(:account_id, account.id)
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   recipe_id: recipe.id,
                   scheduled_date: today,
                   servings: 4
                 }
               )
               |> Ash.create(actor: user, tenant: account.id)
    end

    test "validates meal_type is one of allowed values" do
      {account, user} = create_account_and_user()
      recipe = create_recipe(account, user, %{name: "Test Recipe"})
      today = Date.utc_today()

      for meal_type <- [:breakfast, :lunch, :dinner, :snack] do
        assert {:ok, _meal_plan} =
                 MealPlan
                 |> Ash.Changeset.new()
                 |> Ash.Changeset.set_argument(:account_id, account.id)
                 |> Ash.Changeset.for_create(
                   :create,
                   %{
                     recipe_id: recipe.id,
                     scheduled_date:
                       Date.add(
                         today,
                         Enum.find_index(
                           [:breakfast, :lunch, :dinner, :snack],
                           &(&1 == meal_type)
                         )
                       ),
                     meal_type: meal_type,
                     servings: 4
                   }
                 )
                 |> Ash.create(actor: user, tenant: account.id)
      end
    end

    test "defaults servings to 4 if not provided" do
      {account, user} = create_account_and_user()
      recipe = create_recipe(account, user, %{name: "Test Recipe"})
      today = Date.utc_today()

      assert {:ok, meal_plan} =
               MealPlan
               |> Ash.Changeset.new()
               |> Ash.Changeset.set_argument(:account_id, account.id)
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   recipe_id: recipe.id,
                   scheduled_date: today,
                   meal_type: :dinner
                 }
               )
               |> Ash.create(actor: user, tenant: account.id)

      assert meal_plan.servings == 4
    end
  end

  describe "meal plan reading" do
    test "reads meal plans with recipe relationship" do
      {account, user} = create_account_and_user()
      recipe = create_recipe(account, user, %{name: "Test Recipe"})
      today = Date.utc_today()

      {:ok, meal_plan} =
        MealPlan
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:account_id, account.id)
        |> Ash.Changeset.for_create(
          :create,
          %{
            recipe_id: recipe.id,
            scheduled_date: today,
            meal_type: :breakfast,
            servings: 4
          }
        )
        |> Ash.create(actor: user, tenant: account.id)

      loaded_meal_plan = Ash.load!(meal_plan, :recipe, actor: user)
      assert loaded_meal_plan.recipe.name == "Test Recipe"
    end

    test "lists meal plans for an account" do
      {account, user} = create_account_and_user()
      recipe1 = create_recipe(account, user, %{name: "Breakfast Recipe"})
      recipe2 = create_recipe(account, user, %{name: "Lunch Recipe"})
      today = Date.utc_today()

      {:ok, _mp1} =
        MealPlan
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:account_id, account.id)
        |> Ash.Changeset.for_create(
          :create,
          %{
            recipe_id: recipe1.id,
            scheduled_date: today,
            meal_type: :breakfast,
            servings: 2
          }
        )
        |> Ash.create(actor: user, tenant: account.id)

      {:ok, _mp2} =
        MealPlan
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:account_id, account.id)
        |> Ash.Changeset.for_create(
          :create,
          %{
            recipe_id: recipe2.id,
            scheduled_date: today,
            meal_type: :lunch,
            servings: 4
          }
        )
        |> Ash.create(actor: user, tenant: account.id)

      {:ok, meal_plans} = Ash.read(MealPlan, actor: user, tenant: account.id)
      assert length(meal_plans) == 2
    end

    test "does not list meal plans from other accounts" do
      {account1, user1} = create_account_and_user()
      {account2, user2} = create_account_and_user()

      recipe1 = create_recipe(account1, user1, %{name: "Account 1 Recipe"})
      recipe2 = create_recipe(account2, user2, %{name: "Account 2 Recipe"})
      today = Date.utc_today()

      {:ok, _mp1} =
        MealPlan
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:account_id, account1.id)
        |> Ash.Changeset.for_create(
          :create,
          %{
            recipe_id: recipe1.id,
            scheduled_date: today,
            meal_type: :breakfast,
            servings: 2
          }
        )
        |> Ash.create(actor: user1, tenant: account1.id)

      {:ok, _mp2} =
        MealPlan
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:account_id, account2.id)
        |> Ash.Changeset.for_create(
          :create,
          %{
            recipe_id: recipe2.id,
            scheduled_date: today,
            meal_type: :lunch,
            servings: 4
          }
        )
        |> Ash.create(actor: user2, tenant: account2.id)

      {:ok, meal_plans} = Ash.read(MealPlan, actor: user1, tenant: account1.id)
      assert length(meal_plans) == 1
    end
  end

  describe "meal plan deletion" do
    test "deletes a meal plan" do
      {account, user} = create_account_and_user()
      recipe = create_recipe(account, user, %{name: "Test Recipe"})
      today = Date.utc_today()

      {:ok, meal_plan} =
        MealPlan
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:account_id, account.id)
        |> Ash.Changeset.for_create(
          :create,
          %{
            recipe_id: recipe.id,
            scheduled_date: today,
            meal_type: :dinner,
            servings: 4
          }
        )
        |> Ash.create(actor: user, tenant: account.id)

      assert :ok = Ash.destroy(meal_plan, actor: user)

      {:ok, meal_plans} = Ash.read(MealPlan, actor: user, tenant: account.id)
      assert length(meal_plans) == 0
    end
  end

  # Helper function to create a recipe for testing
  defp create_recipe(account, _user, attrs) do
    default_attrs = %{
      name: "Test Recipe #{System.unique_integer()}",
      difficulty: :easy
    }

    attrs = Map.merge(default_attrs, attrs)

    GroceryPlanner.Recipes.create_recipe!(
      account.id,
      attrs,
      authorize?: false,
      tenant: account.id
    )
  end
end
