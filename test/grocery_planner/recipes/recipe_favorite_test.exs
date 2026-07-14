defmodule GroceryPlanner.Recipes.RecipeFavoriteTest do
  use GroceryPlanner.DataCase, async: true

  import GroceryPlanner.InventoryTestHelpers

  alias GroceryPlanner.Recipes

  describe "Recipe favorite toggling" do
    test "can set a recipe as favorite" do
      {account, user} = create_account_and_user()

      {:ok, recipe} =
        Recipes.create_recipe(
          account.id,
          %{
            name: "Test Recipe",
            description: "A test recipe",
            servings: 4
          },
          actor: user,
          tenant: account.id
        )

      # Recipe should not be favorite by default
      assert recipe.is_favorite == false

      # Update to favorite
      assert {:ok, updated_recipe} =
               Recipes.update_recipe(
                 recipe,
                 %{is_favorite: true},
                 actor: user,
                 tenant: account.id
               )

      assert updated_recipe.is_favorite == true
    end

    test "can toggle favorite status from true to false" do
      {account, user} = create_account_and_user()

      {:ok, recipe} =
        Recipes.create_recipe(
          account.id,
          %{
            name: "Test Recipe",
            servings: 4,
            is_favorite: true
          },
          actor: user,
          tenant: account.id
        )

      assert recipe.is_favorite == true

      # Toggle to not favorite
      assert {:ok, updated_recipe} =
               Recipes.update_recipe(
                 recipe,
                 %{is_favorite: false},
                 actor: user,
                 tenant: account.id
               )

      assert updated_recipe.is_favorite == false
    end

    test "favorite status persists across reads" do
      {account, user} = create_account_and_user()

      {:ok, recipe} =
        Recipes.create_recipe(
          account.id,
          %{
            name: "Test Recipe",
            servings: 4
          },
          actor: user,
          tenant: account.id
        )

      # Set as favorite
      {:ok, _updated_recipe} =
        Recipes.update_recipe(
          recipe,
          %{is_favorite: true},
          actor: user,
          tenant: account.id
        )

      # Read recipe again and verify favorite status persisted
      {:ok, reloaded_recipe} = Recipes.get_recipe(recipe.id, actor: user, tenant: account.id)

      assert reloaded_recipe.is_favorite == true
    end

    test "toggle_favorite action flips the flag each call" do
      {account, user} = create_account_and_user()

      {:ok, recipe} =
        Recipes.create_recipe(
          account.id,
          %{name: "Toggle Me", servings: 4},
          actor: user,
          tenant: account.id
        )

      assert recipe.is_favorite == false

      assert {:ok, on} = Recipes.toggle_favorite(recipe, actor: user, tenant: account.id)
      assert on.is_favorite == true

      assert {:ok, off} = Recipes.toggle_favorite(on, actor: user, tenant: account.id)
      assert off.is_favorite == false
    end

    test "can create recipe with favorite status" do
      {account, user} = create_account_and_user()

      {:ok, recipe} =
        Recipes.create_recipe(
          account.id,
          %{
            name: "Favorite Recipe",
            servings: 4,
            is_favorite: true
          },
          actor: user,
          tenant: account.id
        )

      assert recipe.is_favorite == true
    end
  end
end
