defmodule GroceryPlannerWeb.RecipeShowLinkableTest do
  @moduledoc """
  Locks the linkable-recipe picker on the recipe show page after it was migrated
  to `Recipes.browse_recipes/2` for name search (the linking-specific exclusions
  and take(20) stay in the LiveView).
  """
  use GroceryPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GroceryPlanner.InventoryTestHelpers

  alias GroceryPlanner.Recipes

  setup do
    account = create_account()
    user = create_user(account)

    conn =
      build_conn()
      |> init_test_session(%{user_id: user.id, account_id: account.id})

    %{conn: conn, account: account}
  end

  defp mk(account, attrs) do
    {:ok, recipe} =
      Recipes.create_recipe(
        account.id,
        Map.merge(%{name: "R#{System.unique_integer([:positive])}"}, attrs),
        authorize?: false,
        tenant: account.id
      )

    recipe
  end

  test "link modal lists candidates and excludes follow-ups", %{conn: conn, account: account} do
    base = mk(account, %{name: "Sunday Roast"})
    mk(account, %{name: "Leftover Soup"})
    mk(account, %{name: "Already A Follow Up", is_follow_up: true})

    {:ok, view, _html} = live(conn, "/recipes/#{base.id}")
    html = render_click(view, "open_link_modal")

    assert html =~ "Leftover Soup"
    refute html =~ "Already A Follow Up"
  end

  test "linkable search filters by name, case-insensitively", %{conn: conn, account: account} do
    base = mk(account, %{name: "Sunday Roast"})
    mk(account, %{name: "Leftover Soup"})
    mk(account, %{name: "Green Salad"})

    {:ok, view, _html} = live(conn, "/recipes/#{base.id}")
    render_click(view, "open_link_modal")
    html = render_hook(view, "search_linkable_recipes", %{"value" => "SOU"})

    assert html =~ "Leftover Soup"
    refute html =~ "Green Salad"
  end
end
