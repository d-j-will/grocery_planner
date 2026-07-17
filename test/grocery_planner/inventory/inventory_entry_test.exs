defmodule GroceryPlanner.Inventory.InventoryEntryTest do
  use GroceryPlanner.DataCase, async: true

  alias GroceryPlanner.Inventory.InventoryEntry

  describe "create/1" do
    setup do
      account = create_account()
      user = create_user(account)
      item = create_grocery_item(account, user, %{name: "Milk"})
      location = create_storage_location(account, user, %{name: "Fridge"})

      %{account: account, user: user, item: item, location: location}
    end

    test "creates an inventory entry with all attributes", %{
      account: account,
      user: _user,
      item: item,
      location: location
    } do
      attrs = %{
        quantity: Decimal.new("2.5"),
        unit: "gallon",
        purchase_price: Money.new(:USD, "4.99"),
        purchase_date: ~D[2024-01-15],
        use_by_date: ~D[2024-01-25],
        notes: "Organic whole milk",
        status: :available,
        storage_location_id: location.id,
        account_id: account.id,
        grocery_item_id: item.id
      }

      assert {:ok, entry} =
               InventoryEntry
               |> Ash.Changeset.for_create(:create, attrs)
               |> Ash.create(authorize?: false, tenant: account.id)

      assert Decimal.equal?(entry.quantity, Decimal.new("2.5"))
      assert entry.unit == "gallon"
      assert Money.equal?(entry.purchase_price, Money.new(:USD, "4.99"))
      assert entry.purchase_date == ~D[2024-01-15]
      assert entry.use_by_date == ~D[2024-01-25]
      assert entry.notes == "Organic whole milk"
      assert entry.status == :available
    end

    test "creates inventory entry with minimal attributes", %{
      account: account,
      user: _user,
      item: item
    } do
      attrs = %{quantity: Decimal.new("1"), account_id: account.id, grocery_item_id: item.id}

      assert {:ok, entry} =
               InventoryEntry
               |> Ash.Changeset.for_create(:create, attrs)
               |> Ash.create(authorize?: false, tenant: account.id)

      assert Decimal.equal?(entry.quantity, Decimal.new("1"))
      assert entry.status == :available
    end

    test "validates status enum values", %{account: account, user: _user, item: item} do
      for status <- [:available, :reserved, :expired, :consumed] do
        attrs = %{
          quantity: Decimal.new("1"),
          status: status,
          account_id: account.id,
          grocery_item_id: item.id
        }

        assert {:ok, entry} =
                 InventoryEntry
                 |> Ash.Changeset.for_create(:create, attrs)
                 |> Ash.create(authorize?: false, tenant: account.id)

        assert entry.status == status
      end
    end
  end

  describe "calculations" do
    setup do
      account = create_account()
      user = create_user(account)
      item = create_grocery_item(account, user, %{name: "Milk"})

      %{account: account, user: user, item: item}
    end

    test "calculates days_until_expiry correctly", %{account: account, user: user, item: item} do
      today = Date.utc_today()
      future_date = Date.add(today, 10)

      entry =
        create_inventory_entry(account, user, item, %{
          quantity: Decimal.new("1"),
          use_by_date: future_date
        })

      entry_with_calc =
        GroceryPlanner.Inventory.get_inventory_entry!(entry.id,
          authorize?: false,
          tenant: account.id,
          load: [:days_until_expiry]
        )

      assert entry_with_calc.days_until_expiry == 10
    end

    test "calculates is_expiring_soon correctly", %{account: account, user: user, item: item} do
      today = Date.utc_today()
      soon_date = Date.add(today, 5)

      entry =
        create_inventory_entry(account, user, item, %{
          quantity: Decimal.new("1"),
          use_by_date: soon_date
        })

      entry_with_calc =
        GroceryPlanner.Inventory.get_inventory_entry!(entry.id,
          authorize?: false,
          tenant: account.id,
          load: [:is_expiring_soon]
        )

      assert entry_with_calc.is_expiring_soon == true
    end

    test "calculates is_expired correctly", %{account: account, user: user, item: item} do
      today = Date.utc_today()
      past_date = Date.add(today, -5)

      entry =
        create_inventory_entry(account, user, item, %{
          quantity: Decimal.new("1"),
          use_by_date: past_date
        })

      entry_with_calc =
        GroceryPlanner.Inventory.get_inventory_entry!(entry.id,
          authorize?: false,
          tenant: account.id,
          load: [:is_expired]
        )

      assert entry_with_calc.is_expired == true
    end
  end

  describe "read/0" do
    setup do
      account = create_account()
      user = create_user(account)
      item = create_grocery_item(account, user, %{name: "Milk"})

      %{account: account, user: user, item: item}
    end

    test "lists inventory entries for account", %{account: account, user: user, item: item} do
      create_inventory_entry(account, user, item, %{quantity: Decimal.new("1"), notes: "Entry 1"})
      create_inventory_entry(account, user, item, %{quantity: Decimal.new("2"), notes: "Entry 2"})

      entries =
        GroceryPlanner.Inventory.list_inventory_entries!(authorize?: false, tenant: account.id)

      assert length(entries) == 2
    end
  end

  describe "update/2" do
    setup do
      account = create_account()
      user = create_user(account)
      item = create_grocery_item(account, user, %{name: "Milk"})
      entry = create_inventory_entry(account, user, item, %{quantity: Decimal.new("1")})

      %{account: account, user: user, entry: entry}
    end

    test "updates inventory entry attributes", %{account: account, user: _user, entry: entry} do
      update_attrs = %{quantity: Decimal.new("2.5"), status: :reserved}

      assert {:ok, updated} =
               entry
               |> Ash.Changeset.for_update(:update, update_attrs)
               |> Ash.update(authorize?: false, tenant: account.id)

      assert Decimal.equal?(updated.quantity, Decimal.new("2.5"))
      assert updated.status == :reserved
    end
  end

  describe "destroy/1" do
    setup do
      account = create_account()
      user = create_user(account)
      item = create_grocery_item(account, user, %{name: "Milk"})
      entry = create_inventory_entry(account, user, item, %{quantity: Decimal.new("1")})

      %{account: account, user: user, entry: entry}
    end

    test "deletes an inventory entry", %{account: account, user: _user, entry: entry} do
      assert :ok = Ash.destroy(entry, authorize?: false, tenant: account.id)

      entries =
        GroceryPlanner.Inventory.list_inventory_entries!(authorize?: false, tenant: account.id)

      assert entries == []
    end
  end
end
