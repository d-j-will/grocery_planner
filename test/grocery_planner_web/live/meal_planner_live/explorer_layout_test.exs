defmodule GroceryPlannerWeb.MealPlannerLive.ExplorerLayoutTest do
  use GroceryPlannerWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import GroceryPlanner.MealPlanningTestHelpers

  setup do
    account = create_account()
    user = create_user(account)

    # Create some recipes for quick picks
    create_recipe(account, user, %{
      name: "Quick Pasta",
      prep_time_minutes: 10,
      cook_time_minutes: 10
    })

    create_recipe(account, user, %{name: "Easy Salad", prep_time_minutes: 5, cook_time_minutes: 0})

    create_recipe(account, user, %{name: "Toast", prep_time_minutes: 2, cook_time_minutes: 2})

    # Set layout to explorer
    {:ok, user} =
      GroceryPlanner.Accounts.User.update(user, %{meal_planner_layout: "explorer"}, actor: user)

    today = Date.utc_today()
    week_start = Date.add(today, -(Date.day_of_week(today) - 1))

    conn =
      build_conn()
      |> init_test_session(%{
        user_id: user.id,
        account_id: account.id
      })

    %{conn: conn, account: account, user: user, week_start: week_start}
  end

  describe "explorer mobile layout" do
    test "renders mobile components", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Mobile header search (escaped selector)
      assert has_element?(view, ".lg\\:hidden input[name='query']")

      # Mobile week strip
      assert has_element?(view, ".lg\\:hidden .flex.gap-1.justify-center")

      # Filter bar
      assert has_element?(view, "button", "Under 30 min")
      assert has_element?(view, "button", "Pantry-first")
    end

    test "expanding a day works", %{conn: conn, week_start: week_start} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Initially expanded day is today.
      # The close button in the expanded pane (using the animate-in class to distinguish from week strip)
      # We target the button itself, not the icon inside
      close_btn_selector = ".lg\\:hidden .animate-in button[phx-click='collapse_day']"

      assert has_element?(view, close_btn_selector)

      # Collapse it
      view |> element(close_btn_selector) |> render_click()

      # Now verify expanded view is gone
      refute has_element?(view, close_btn_selector)

      # Expand a specific day (Tuesday)
      tuesday = Date.add(week_start, 1)

      view
      |> element("button[phx-click='expand_day'][phx-value-date='#{tuesday}']")
      |> render_click()

      # Expanded view should be back
      assert has_element?(view, close_btn_selector)
      assert render(view) =~ Calendar.strftime(tuesday, "%A, %B %d")
    end

    test "quick picks are rendered for empty slots", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Ensure today is expanded
      today = Date.utc_today()
      close_btn_selector = ".lg\\:hidden .animate-in button[phx-click='collapse_day']"

      unless has_element?(view, close_btn_selector) do
        view
        |> element("button[phx-click='expand_day'][phx-value-date='#{today}']")
        |> render_click()
      end

      # Check for quick pick buttons
      assert has_element?(view, "button[phx-click='explorer_quick_add']")
      assert render(view) =~ "Quick Pasta"
    end
  end
end
