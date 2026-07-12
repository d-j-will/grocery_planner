defmodule GroceryPlanner.Analytics.TrendsTest do
  use GroceryPlanner.DataCase, async: true

  alias GroceryPlanner.Accounts
  alias GroceryPlanner.Analytics
  alias GroceryPlanner.Analytics.UsageLog
  alias GroceryPlanner.Inventory

  setup do
    account = Accounts.Account.create!(%{name: "Test Account", currency: "USD"})

    user =
      Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        email: "test_#{System.unique_integer()}@example.com",
        name: "Test User",
        password: "password123"
      })
      |> Ash.create!()

    # Link user to account
    case Accounts.AccountMembership.create(account.id, user.id, %{role: :owner},
           authorize?: false
         ) do
      {:ok, membership} ->
        membership

      {:error, error} ->
        IO.puts(:stderr, "Membership Create Error: #{inspect(error)}")
        raise error
    end

    %{account: account, user: user}
  end

  describe "spending trends" do
    test "returns daily spending summary", %{account: account, user: user} do
      today = Date.utc_today()
      yesterday = Date.add(today, -1)

      # Create inventory entries with prices
      category =
        Inventory.Category.create!(%{name: "General", account_id: account.id},
          tenant: account.id,
          actor: user,
          authorize?: false
        )

      item =
        Inventory.GroceryItem.create_grocery_item!(
          %{name: "Apple", category_id: category.id, account_id: account.id},
          tenant: account.id,
          actor: user,
          authorize?: false
        )

      Inventory.InventoryEntry.create_inventory_entry!(
        %{
          grocery_item_id: item.id,
          quantity: 1,
          unit: "kg",
          purchase_price: %{amount: 10, currency: :USD},
          purchase_date: today,
          status: :available,
          account_id: account.id
        },
        tenant: account.id,
        actor: user,
        authorize?: false
      )

      Inventory.InventoryEntry.create_inventory_entry!(
        %{
          grocery_item_id: item.id,
          quantity: 1,
          unit: "kg",
          purchase_price: %{amount: 5, currency: :USD},
          purchase_date: today,
          status: :available,
          account_id: account.id
        },
        tenant: account.id,
        actor: user,
        authorize?: false
      )

      Inventory.InventoryEntry.create_inventory_entry!(
        %{
          grocery_item_id: item.id,
          quantity: 1,
          unit: "kg",
          purchase_price: %{amount: 20, currency: :USD},
          purchase_date: yesterday,
          status: :available,
          account_id: account.id
        },
        tenant: account.id,
        actor: user,
        authorize?: false
      )

      trends = Analytics.get_spending_trends(account.id, :USD, user)

      assert length(trends) == 2

      yesterday_trend = Enum.find(trends, &(&1.date == yesterday))
      assert Money.compare(yesterday_trend.amount, Money.new(20, :USD)) == :eq

      today_trend = Enum.find(trends, &(&1.date == today))
      assert Money.compare(today_trend.amount, Money.new(15, :USD)) == :eq
    end
  end

  describe "usage trends" do
    test "returns consumed vs wasted counts", %{account: account, user: user} do
      today = DateTime.utc_now()
      yesterday = DateTime.add(today, -24, :hour)

      category =
        Inventory.Category.create!(%{name: "General", account_id: account.id},
          tenant: account.id,
          actor: user,
          authorize?: false
        )

      item =
        Inventory.GroceryItem.create_grocery_item!(
          %{name: "Apple", category_id: category.id, account_id: account.id},
          tenant: account.id,
          actor: user,
          authorize?: false
        )

      # Today: 1 consumed, 1 wasted
      UsageLog.create!(
        %{
          grocery_item_id: item.id,
          quantity: 1,
          unit: "ea",
          reason: :consumed,
          occurred_at: today,
          account_id: account.id
        },
        tenant: account.id,
        actor: user,
        authorize?: false
      )

      UsageLog.create!(
        %{
          grocery_item_id: item.id,
          quantity: 1,
          unit: "ea",
          reason: :wasted,
          occurred_at: today,
          account_id: account.id
        },
        tenant: account.id,
        actor: user,
        authorize?: false
      )

      # Yesterday: 2 consumed
      UsageLog.create!(
        %{
          grocery_item_id: item.id,
          quantity: 1,
          unit: "ea",
          reason: :consumed,
          occurred_at: yesterday,
          account_id: account.id
        },
        tenant: account.id,
        actor: user,
        authorize?: false
      )

      UsageLog.create!(
        %{
          grocery_item_id: item.id,
          quantity: 1,
          unit: "ea",
          reason: :consumed,
          occurred_at: yesterday,
          account_id: account.id
        },
        tenant: account.id,
        actor: user,
        authorize?: false
      )

      trends = Analytics.get_usage_trends(account.id, user)

      assert length(trends) == 2

      yesterday_trend =
        Enum.find(trends, &(&1.date == Date.to_iso8601(DateTime.to_date(yesterday))))

      assert yesterday_trend.consumed == 2
      assert yesterday_trend.wasted == 0

      today_trend = Enum.find(trends, &(&1.date == Date.to_iso8601(DateTime.to_date(today))))
      assert today_trend.consumed == 1
      assert today_trend.wasted == 1
    end
  end

  describe "most wasted items" do
    test "returns top wasted items by count and cost", %{account: account, user: user} do
      category =
        Inventory.Category.create!(%{name: "General", account_id: account.id},
          tenant: account.id,
          actor: user,
          authorize?: false
        )

      apple =
        Inventory.GroceryItem.create_grocery_item!(
          %{name: "Apple", category_id: category.id, account_id: account.id},
          tenant: account.id,
          actor: user,
          authorize?: false
        )

      banana =
        Inventory.GroceryItem.create_grocery_item!(
          %{name: "Banana", category_id: category.id, account_id: account.id},
          tenant: account.id,
          actor: user,
          authorize?: false
        )

      # Waste 2 apples, cost 5 each
      UsageLog.create!(
        %{
          grocery_item_id: apple.id,
          quantity: 1,
          unit: "ea",
          reason: :wasted,
          cost: %{amount: 5, currency: :USD},
          account_id: account.id
        },
        tenant: account.id,
        actor: user,
        authorize?: false
      )

      UsageLog.create!(
        %{
          grocery_item_id: apple.id,
          quantity: 1,
          unit: "ea",
          reason: :expired,
          cost: %{amount: 5, currency: :USD},
          account_id: account.id
        },
        tenant: account.id,
        actor: user,
        authorize?: false
      )

      # Waste 1 banana, cost 2
      UsageLog.create!(
        %{
          grocery_item_id: banana.id,
          quantity: 1,
          unit: "ea",
          reason: :wasted,
          cost: %{amount: 2, currency: :USD},
          account_id: account.id
        },
        tenant: account.id,
        actor: user,
        authorize?: false
      )

      items = Analytics.get_most_wasted_items(account.id, :USD, user)

      assert length(items) == 2

      first = List.first(items)
      assert first.name == "Apple"
      assert first.count == 2
      assert Money.compare(first.total_cost, Money.new(10, :USD)) == :eq

      second = List.last(items)
      assert second.name == "Banana"
      assert second.count == 1
      assert Money.compare(second.total_cost, Money.new(2, :USD)) == :eq
    end
  end
end
