defmodule GroceryPlanner.Inventory.GroceryItemTest do
  use GroceryPlanner.DataCase, async: true

  alias GroceryPlanner.Inventory.GroceryItem

  describe "create/1" do
    setup do
      account = create_account()
      user = create_user(account)
      category = create_category(account, user, %{name: "Dairy"})
      %{account: account, user: user, category: category}
    end

    test "creates a grocery item with valid attributes", %{
      account: account,
      user: _user,
      category: category
    } do
      attrs = %{
        name: "Milk",
        description: "Whole milk",
        default_unit: "gallon",
        barcode: "1234567890",
        category_id: category.id,
        account_id: account.id
      }

      assert {:ok, item} =
               GroceryItem
               |> Ash.Changeset.for_create(:create, attrs)
               |> Ash.create(authorize?: false, tenant: account.id)

      assert item.name == "Milk"
      assert item.description == "Whole milk"
      assert item.default_unit == "gallon"
      assert item.barcode == "1234567890"
      assert item.category_id == category.id
    end

    test "creates grocery item with minimal attributes", %{account: account, user: _user} do
      attrs = %{name: "Bread", account_id: account.id}

      assert {:ok, item} =
               GroceryItem
               |> Ash.Changeset.for_create(:create, attrs)
               |> Ash.create(authorize?: false, tenant: account.id)

      assert item.name == "Bread"
      assert item.description == nil
    end

    test "requires name", %{account: account, user: _user} do
      attrs = %{description: "Some item", account_id: account.id}

      assert {:error, %Ash.Error.Invalid{}} =
               GroceryItem
               |> Ash.Changeset.for_create(:create, attrs)
               |> Ash.create(authorize?: false, tenant: account.id)
    end
  end

  describe "read/0" do
    setup do
      account = create_account()
      user = create_user(account)
      %{account: account, user: user}
    end

    test "lists grocery items for account", %{account: account, user: user} do
      create_grocery_item(account, user, %{name: "Milk"})
      create_grocery_item(account, user, %{name: "Bread"})

      items = GroceryPlanner.Inventory.list_grocery_items!(authorize?: false, tenant: account.id)
      assert length(items) == 2
      assert Enum.any?(items, &(&1.name == "Milk"))
      assert Enum.any?(items, &(&1.name == "Bread"))
    end
  end

  describe "update/2" do
    setup do
      account = create_account()
      user = create_user(account)
      item = create_grocery_item(account, user, %{name: "Milk", description: "Whole milk"})

      %{account: account, user: user, item: item}
    end

    test "updates grocery item attributes", %{account: account, user: _user, item: item} do
      update_attrs = %{name: "Organic Milk", description: "Organic whole milk"}

      assert {:ok, updated} =
               item
               |> Ash.Changeset.for_update(:update, update_attrs)
               |> Ash.update(authorize?: false, tenant: account.id)

      assert updated.name == "Organic Milk"
      assert updated.description == "Organic whole milk"
    end
  end

  describe "destroy/1" do
    setup do
      account = create_account()
      user = create_user(account)
      item = create_grocery_item(account, user, %{name: "Milk"})

      %{account: account, user: user, item: item}
    end

    test "deletes a grocery item", %{account: account, user: _user, item: item} do
      assert :ok = Ash.destroy(item, authorize?: false, tenant: account.id)

      items = GroceryPlanner.Inventory.list_grocery_items!(authorize?: false, tenant: account.id)
      assert items == []
    end
  end
end
