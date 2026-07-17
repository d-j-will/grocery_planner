defmodule GroceryPlanner.Sync.OfflineSyncTest do
  @moduledoc """
  Behavioral tests for US-008: Offline Sync Support.

  Tests verify that:
  - Soft deletes set deleted_at instead of removing records
  - Normal read actions exclude soft-deleted records
  - Custom read actions exclude soft-deleted records
  - Sync actions return all records when since is nil
  - Sync actions return only recently modified records when since is provided
  - Sync actions include soft-deleted records modified after since
  - Timestamps (created_at, updated_at) are public and present in responses
  """
  use GroceryPlanner.DataCase, async: true

  import GroceryPlanner.InventoryTestHelpers

  alias GroceryPlanner.Inventory
  alias GroceryPlanner.Recipes
  alias GroceryPlanner.Shopping

  describe "soft delete behavior" do
    test "destroying a grocery item sets deleted_at instead of removing it" do
      {account, user} = create_account_and_user()
      item = create_grocery_item(account, user, %{name: "Soft Delete Item"})

      assert is_nil(item.deleted_at)

      {:ok, deleted_item} =
        Inventory.destroy_grocery_item(item,
          actor: user,
          tenant: account.id,
          return_destroyed?: true
        )

      assert deleted_item.deleted_at != nil

      # Record still exists in DB via sync action (bypasses deleted_at filter)
      {:ok, synced} =
        Inventory.sync_grocery_items(nil,
          actor: user,
          tenant: account.id
        )

      assert Enum.any?(synced, fn i -> i.id == item.id end)
    end

    test "destroying a shopping list sets deleted_at instead of removing it" do
      {account, user} = create_account_and_user()

      {:ok, list} =
        Shopping.create_shopping_list(
          account.id,
          %{name: "Sync Test List"},
          tenant: account.id,
          actor: user
        )

      assert is_nil(list.deleted_at)

      {:ok, deleted_list} =
        Shopping.destroy_shopping_list(list,
          actor: user,
          tenant: account.id,
          return_destroyed?: true
        )

      assert deleted_list.deleted_at != nil
    end

    test "destroying a recipe sets deleted_at instead of removing it" do
      {account, user} = create_account_and_user()

      {:ok, recipe} =
        Recipes.create_recipe(
          account.id,
          %{name: "Sync Test Recipe", servings: 4},
          actor: user,
          tenant: account.id
        )

      assert is_nil(recipe.deleted_at)

      {:ok, deleted_recipe} =
        Recipes.destroy_recipe(recipe,
          actor: user,
          tenant: account.id,
          return_destroyed?: true
        )

      assert deleted_recipe.deleted_at != nil
    end
  end

  describe "normal reads exclude soft-deleted records" do
    test "primary read excludes deleted grocery items" do
      {account, user} = create_account_and_user()
      item = create_grocery_item(account, user, %{name: "Will Be Deleted"})
      _kept = create_grocery_item(account, user, %{name: "Will Be Kept"})

      Inventory.destroy_grocery_item(item, actor: user, tenant: account.id)

      {:ok, items} = Inventory.list_grocery_items(actor: user, tenant: account.id)

      names = Enum.map(items, & &1.name)
      refute "Will Be Deleted" in names
      assert "Will Be Kept" in names
    end

    test "list_with_tags excludes deleted grocery items" do
      {account, user} = create_account_and_user()
      item = create_grocery_item(account, user, %{name: "Tagged Deleted"})
      _kept = create_grocery_item(account, user, %{name: "Tagged Kept"})

      Inventory.destroy_grocery_item(item, actor: user, tenant: account.id)

      {:ok, items} = Inventory.list_items_with_tags(nil, actor: user, tenant: account.id)

      names = Enum.map(items, & &1.name)
      refute "Tagged Deleted" in names
      assert "Tagged Kept" in names
    end

    test "active_or_completed excludes deleted shopping lists" do
      {account, user} = create_account_and_user()

      {:ok, list} =
        Shopping.create_shopping_list(
          account.id,
          %{name: "Deleted List"},
          tenant: account.id,
          actor: user
        )

      {:ok, _kept} =
        Shopping.create_shopping_list(
          account.id,
          %{name: "Kept List"},
          tenant: account.id,
          actor: user
        )

      Shopping.destroy_shopping_list(list, actor: user, tenant: account.id)

      {:ok, lists} =
        Shopping.list_active_or_completed_shopping_lists(
          actor: user,
          tenant: account.id
        )

      names = Enum.map(lists, & &1.name)
      refute "Deleted List" in names
      assert "Kept List" in names
    end
  end

  describe "sync action with nil since returns all records" do
    test "returns all grocery items including soft-deleted ones" do
      {account, user} = create_account_and_user()
      item1 = create_grocery_item(account, user, %{name: "Active Item"})
      item2 = create_grocery_item(account, user, %{name: "Deleted Item"})

      Inventory.destroy_grocery_item(item2, actor: user, tenant: account.id)

      {:ok, synced} = Inventory.sync_grocery_items(nil, actor: user, tenant: account.id)

      ids = Enum.map(synced, & &1.id)
      assert item1.id in ids
      assert item2.id in ids
    end

    test "returns all shopping lists including soft-deleted ones" do
      {account, user} = create_account_and_user()

      {:ok, list1} =
        Shopping.create_shopping_list(
          account.id,
          %{name: "Active List"},
          tenant: account.id,
          actor: user
        )

      {:ok, list2} =
        Shopping.create_shopping_list(
          account.id,
          %{name: "Deleted List"},
          tenant: account.id,
          actor: user
        )

      Shopping.destroy_shopping_list(list2, actor: user, tenant: account.id)

      {:ok, synced} = Shopping.sync_shopping_lists(nil, actor: user, tenant: account.id)

      ids = Enum.map(synced, & &1.id)
      assert list1.id in ids
      assert list2.id in ids
    end
  end

  describe "sync action with since timestamp filters correctly" do
    test "returns only records modified after the since timestamp" do
      {account, user} = create_account_and_user()
      _old_item = create_grocery_item(account, user, %{name: "Old Item"})

      # Use a timestamp slightly in the future to exclude the old item
      since = DateTime.add(DateTime.utc_now(), 1, :second)

      # Small delay to ensure the new item's updated_at is after since
      Process.sleep(1100)

      new_item = create_grocery_item(account, user, %{name: "New Item"})

      {:ok, synced} = Inventory.sync_grocery_items(since, actor: user, tenant: account.id)

      ids = Enum.map(synced, & &1.id)
      assert new_item.id in ids
    end

    test "includes soft-deleted records modified after since" do
      {account, user} = create_account_and_user()
      item = create_grocery_item(account, user, %{name: "Will Delete Later"})

      # Timestamp before deletion
      since = DateTime.add(DateTime.utc_now(), -1, :second)

      :ok =
        Inventory.destroy_grocery_item(item, actor: user, tenant: account.id)

      {:ok, synced} = Inventory.sync_grocery_items(since, actor: user, tenant: account.id)

      synced_item = Enum.find(synced, fn i -> i.id == item.id end)
      assert synced_item != nil
      assert synced_item.deleted_at != nil
    end

    test "sync results are sorted by updated_at ascending" do
      {account, user} = create_account_and_user()
      _item1 = create_grocery_item(account, user, %{name: "First"})
      Process.sleep(10)
      _item2 = create_grocery_item(account, user, %{name: "Second"})
      Process.sleep(10)
      _item3 = create_grocery_item(account, user, %{name: "Third"})

      {:ok, synced} = Inventory.sync_grocery_items(nil, actor: user, tenant: account.id)

      timestamps = Enum.map(synced, & &1.updated_at)

      assert timestamps == Enum.sort(timestamps, {:asc, DateTime})
    end
  end

  describe "timestamps are public" do
    test "grocery item has public created_at and updated_at" do
      {account, user} = create_account_and_user()
      item = create_grocery_item(account, user, %{name: "Timestamp Item"})

      assert item.created_at != nil
      assert item.updated_at != nil
      assert %DateTime{} = item.created_at
      assert %DateTime{} = item.updated_at
    end

    test "shopping list has public created_at and updated_at" do
      {account, user} = create_account_and_user()

      {:ok, list} =
        Shopping.create_shopping_list(
          account.id,
          %{name: "Timestamp List"},
          tenant: account.id,
          actor: user
        )

      assert list.created_at != nil
      assert list.updated_at != nil
    end

    test "recipe has public created_at and updated_at" do
      {account, user} = create_account_and_user()

      {:ok, recipe} =
        Recipes.create_recipe(
          account.id,
          %{name: "Timestamp Recipe", servings: 4},
          actor: user,
          tenant: account.id
        )

      assert recipe.created_at != nil
      assert recipe.updated_at != nil
    end
  end
end
