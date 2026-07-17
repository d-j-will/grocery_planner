defmodule GroceryPlanner.Recipes.RecipeAuthorizationTest do
  use GroceryPlanner.DataCase, async: true

  import GroceryPlanner.InventoryTestHelpers

  alias GroceryPlanner.Recipes

  describe "ActorMemberOfAccount check for recipe creation" do
    test "allows user to create recipe in their own account" do
      {account, user} = create_account_and_user()

      assert {:ok, recipe} =
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

      assert recipe.name == "Test Recipe"
      assert recipe.account_id == account.id
    end

    test "denies user from creating recipe in account they're not a member of" do
      {account1, _user1} = create_account_and_user()
      {_account2, user2} = create_account_and_user()

      # user2 trying to create recipe in account1 (which they're not a member of)
      assert {:error, error} =
               Recipes.create_recipe(
                 account1.id,
                 %{
                   name: "Unauthorized Recipe",
                   description: "Should not be created",
                   servings: 4
                 },
                 actor: user2,
                 tenant: account1.id
               )

      # Verify it's a forbidden error
      assert error.class == :forbidden
    end

    test "denies recipe creation when no actor is provided" do
      {account, _user} = create_account_and_user()

      assert {:error, error} =
               Recipes.create_recipe(
                 account.id,
                 %{
                   name: "No Actor Recipe",
                   description: "Should not be created",
                   servings: 4
                 },
                 tenant: account.id
               )

      # Verify it's a forbidden error
      assert error.class == :forbidden
    end

    test "allows user who is member of multiple accounts to create recipes in each" do
      {account1, user} = create_account_and_user()
      account2 = create_account()

      # Add user to account2 by creating a membership
      GroceryPlanner.Accounts.AccountMembership
      |> Ash.Changeset.for_create(:create, %{
        account_id: account2.id,
        user_id: user.id,
        role: :member
      })
      |> Ash.create!(authorize?: false, tenant: account2.id)

      # User should be able to create recipe in account1
      assert {:ok, recipe1} =
               Recipes.create_recipe(
                 account1.id,
                 %{
                   name: "Recipe in Account 1",
                   servings: 4
                 },
                 actor: user,
                 tenant: account1.id
               )

      assert recipe1.account_id == account1.id

      # User should also be able to create recipe in account2
      assert {:ok, recipe2} =
               Recipes.create_recipe(
                 account2.id,
                 %{
                   name: "Recipe in Account 2",
                   servings: 4
                 },
                 actor: user,
                 tenant: account2.id
               )

      assert recipe2.account_id == account2.id
    end
  end

  describe "Recipe update and destroy authorization" do
    test "allows user to update their own account's recipe" do
      {account, user} = create_account_and_user()

      {:ok, recipe} =
        Recipes.create_recipe(
          account.id,
          %{
            name: "Original Recipe",
            servings: 4
          },
          actor: user,
          tenant: account.id
        )

      assert {:ok, updated_recipe} =
               Recipes.update_recipe(
                 recipe,
                 %{name: "Updated Recipe"},
                 actor: user,
                 tenant: account.id
               )

      assert updated_recipe.name == "Updated Recipe"
    end

    test "denies user from updating another account's recipe" do
      {account1, user1} = create_account_and_user()
      {_account2, user2} = create_account_and_user()

      {:ok, recipe} =
        Recipes.create_recipe(
          account1.id,
          %{
            name: "Account 1 Recipe",
            servings: 4
          },
          actor: user1,
          tenant: account1.id
        )

      # user2 trying to update user1's recipe
      assert {:error, error} =
               Recipes.update_recipe(
                 recipe,
                 %{name: "Unauthorized Update"},
                 actor: user2,
                 tenant: account1.id
               )

      assert error.class == :forbidden
    end

    test "allows user to destroy their own account's recipe" do
      {account, user} = create_account_and_user()

      {:ok, recipe} =
        Recipes.create_recipe(
          account.id,
          %{
            name: "Recipe to Delete",
            servings: 4
          },
          actor: user,
          tenant: account.id
        )

      assert :ok = Recipes.destroy_recipe(recipe, actor: user, tenant: account.id)
    end

    test "denies user from destroying another account's recipe" do
      {account1, user1} = create_account_and_user()
      {_account2, user2} = create_account_and_user()

      {:ok, recipe} =
        Recipes.create_recipe(
          account1.id,
          %{
            name: "Account 1 Recipe",
            servings: 4
          },
          actor: user1,
          tenant: account1.id
        )

      # user2 trying to destroy user1's recipe
      assert {:error, error} = Recipes.destroy_recipe(recipe, actor: user2, tenant: account1.id)

      assert error.class == :forbidden
    end
  end
end
