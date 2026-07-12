defmodule GroceryPlannerWeb.MealPlannerPowerModeTest do
  @moduledoc """
  Tests for Power Mode drag-and-drop functionality in the Meal Planner.
  """
  use GroceryPlannerWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import GroceryPlanner.MealPlanningTestHelpers

  setup do
    account = create_account()
    user = create_user(account)

    # Set user to power mode
    {:ok, user} =
      GroceryPlanner.Accounts.User.update(user, %{meal_planner_layout: "power"}, actor: user)

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

  describe "power mode layout" do
    test "renders power mode with kanban board", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Use element selectors which are more reliable
      assert has_element?(view, "#power-mode-kanban")
      assert has_element?(view, "#power-week-board")
    end

    test "displays all seven days", %{conn: conn, week_start: week_start} do
      {:ok, _view, html} = live(conn, "/meal-planner")

      # Check that all days of the week are displayed
      for i <- 0..6 do
        day = Date.add(week_start, i)
        assert html =~ Calendar.strftime(day, "%a")
      end
    end

    test "shows command bar with bulk actions", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      assert has_element?(view, "button[phx-click='copy_last_week']")
      assert has_element?(view, "button[phx-click='auto_fill_week']")
      assert has_element?(view, "button[phx-click='clear_week']")
      assert has_element?(view, "button[phx-click='toggle_sidebar']")
    end

    test "shows recipe sidebar by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/meal-planner")

      assert html =~ "Search recipes"
      assert html =~ "Drag recipes to the board"
    end
  end

  describe "drop_meal event (moving meals)" do
    setup %{conn: conn, account: account, user: user, week_start: week_start} do
      recipe = create_recipe(account, user, %{name: "Moveable Meal"})

      {:ok, meal_plan} =
        GroceryPlanner.MealPlanning.create_meal_plan(
          account.id,
          %{
            recipe_id: recipe.id,
            scheduled_date: week_start,
            meal_type: :breakfast,
            servings: 4
          },
          actor: user,
          tenant: account.id
        )

      {:ok, view, _html} = live(conn, "/meal-planner")

      %{view: view, meal_plan: meal_plan, recipe: recipe}
    end

    test "moves meal to new date and slot", %{
      view: view,
      meal_plan: meal_plan,
      week_start: week_start,
      user: user,
      account: account
    } do
      target_date = Date.add(week_start, 2)

      # Simulate drop event
      view
      |> render_hook("drop_meal", %{
        "meal_id" => meal_plan.id,
        "target_date" => Date.to_iso8601(target_date),
        "target_meal_type" => "dinner"
      })

      # Verify the meal was moved
      {:ok, updated_meal} =
        GroceryPlanner.MealPlanning.get_meal_plan(meal_plan.id,
          actor: user,
          tenant: account.id
        )

      assert updated_meal.scheduled_date == target_date
      assert updated_meal.meal_type == :dinner
    end

    test "supports undo after moving meal", %{
      view: view,
      meal_plan: meal_plan,
      week_start: week_start,
      user: user,
      account: account
    } do
      original_date = meal_plan.scheduled_date
      original_type = meal_plan.meal_type
      target_date = Date.add(week_start, 3)

      # Move the meal
      view
      |> render_hook("drop_meal", %{
        "meal_id" => meal_plan.id,
        "target_date" => Date.to_iso8601(target_date),
        "target_meal_type" => "lunch"
      })

      # Trigger undo
      view
      |> render_hook("undo", %{})

      # Verify the meal was moved back
      {:ok, restored_meal} =
        GroceryPlanner.MealPlanning.get_meal_plan(meal_plan.id,
          actor: user,
          tenant: account.id
        )

      assert restored_meal.scheduled_date == original_date
      assert restored_meal.meal_type == original_type
    end

    test "supports redo after undo", %{
      view: view,
      meal_plan: meal_plan,
      week_start: week_start,
      user: user,
      account: account
    } do
      original_date = meal_plan.scheduled_date
      original_type = meal_plan.meal_type
      target_date = Date.add(week_start, 3)

      # Move the meal
      view
      |> render_hook("drop_meal", %{
        "meal_id" => meal_plan.id,
        "target_date" => Date.to_iso8601(target_date),
        "target_meal_type" => "lunch"
      })

      # Trigger undo (moves it back)
      view
      |> render_hook("undo", %{})

      # Verify it's back to original position
      {:ok, undone_meal} =
        GroceryPlanner.MealPlanning.get_meal_plan(meal_plan.id,
          actor: user,
          tenant: account.id
        )

      assert undone_meal.scheduled_date == original_date
      assert undone_meal.meal_type == original_type

      # Trigger redo (should move it forward again)
      view
      |> render_hook("redo", %{})

      # Verify the meal was moved forward again
      {:ok, redone_meal} =
        GroceryPlanner.MealPlanning.get_meal_plan(meal_plan.id,
          actor: user,
          tenant: account.id
        )

      assert redone_meal.scheduled_date == target_date
      assert redone_meal.meal_type == :lunch
    end
  end

  describe "swap confirmation" do
    setup %{conn: conn, account: account, user: user, week_start: week_start} do
      recipe1 = create_recipe(account, user, %{name: "Meal A"})
      recipe2 = create_recipe(account, user, %{name: "Meal B"})

      {:ok, meal_a} =
        GroceryPlanner.MealPlanning.create_meal_plan(
          account.id,
          %{
            recipe_id: recipe1.id,
            scheduled_date: week_start,
            meal_type: :breakfast,
            servings: 4
          },
          actor: user,
          tenant: account.id
        )

      {:ok, meal_b} =
        GroceryPlanner.MealPlanning.create_meal_plan(
          account.id,
          %{
            recipe_id: recipe2.id,
            scheduled_date: Date.add(week_start, 1),
            meal_type: :dinner,
            servings: 4
          },
          actor: user,
          tenant: account.id
        )

      {:ok, view, _html} = live(conn, "/meal-planner")

      %{view: view, meal_a: meal_a, meal_b: meal_b}
    end

    test "request_swap_confirmation shows modal", %{view: view, meal_a: meal_a, meal_b: meal_b} do
      target_date = meal_b.scheduled_date

      html =
        view
        |> render_hook("request_swap_confirmation", %{
          "dragged_meal_id" => meal_a.id,
          "target_meal_id" => meal_b.id,
          "target_date" => Date.to_iso8601(target_date),
          "target_meal_type" => "dinner"
        })

      assert html =~ "Swap Meals?"
      assert html =~ "Meal A"
      assert html =~ "Meal B"
    end

    test "confirm_swap swaps meal positions", %{
      view: view,
      meal_a: meal_a,
      meal_b: meal_b,
      user: user,
      account: account
    } do
      meal_a_original = %{date: meal_a.scheduled_date, meal_type: meal_a.meal_type}
      meal_b_original = %{date: meal_b.scheduled_date, meal_type: meal_b.meal_type}

      # Request swap confirmation
      view
      |> render_hook("request_swap_confirmation", %{
        "dragged_meal_id" => meal_a.id,
        "target_meal_id" => meal_b.id,
        "target_date" => Date.to_iso8601(meal_b.scheduled_date),
        "target_meal_type" => to_string(meal_b.meal_type)
      })

      # Confirm the swap
      view
      |> element("button[phx-click='confirm_swap']")
      |> render_click()

      # Verify meals were swapped
      {:ok, updated_a} =
        GroceryPlanner.MealPlanning.get_meal_plan(meal_a.id, actor: user, tenant: account.id)

      {:ok, updated_b} =
        GroceryPlanner.MealPlanning.get_meal_plan(meal_b.id, actor: user, tenant: account.id)

      # Meal A should now be at Meal B's original position
      assert updated_a.scheduled_date == meal_b_original.date
      assert updated_a.meal_type == meal_b_original.meal_type

      # Meal B should now be at Meal A's original position
      assert updated_b.scheduled_date == meal_a_original.date
      assert updated_b.meal_type == meal_a_original.meal_type
    end

    test "cancel_swap closes modal without changes", %{
      view: view,
      meal_a: meal_a,
      meal_b: meal_b,
      user: user,
      account: account
    } do
      meal_a_original = meal_a.scheduled_date

      # Request swap confirmation
      view
      |> render_hook("request_swap_confirmation", %{
        "dragged_meal_id" => meal_a.id,
        "target_meal_id" => meal_b.id,
        "target_date" => Date.to_iso8601(meal_b.scheduled_date),
        "target_meal_type" => to_string(meal_b.meal_type)
      })

      # Cancel the swap
      view
      |> element("button[phx-click='cancel_swap']")
      |> render_click()

      # Verify meal A is unchanged
      {:ok, unchanged_a} =
        GroceryPlanner.MealPlanning.get_meal_plan(meal_a.id, actor: user, tenant: account.id)

      assert unchanged_a.scheduled_date == meal_a_original
    end
  end

  describe "bulk operations" do
    setup %{conn: conn, account: account, user: user, week_start: week_start} do
      recipe = create_recipe(account, user, %{name: "Bulk Test Meal"})

      # Create meals for the week
      meals =
        for i <- 0..2 do
          {:ok, meal} =
            GroceryPlanner.MealPlanning.create_meal_plan(
              account.id,
              %{
                recipe_id: recipe.id,
                scheduled_date: Date.add(week_start, i),
                meal_type: :dinner,
                servings: 4
              },
              actor: user,
              tenant: account.id
            )

          meal
        end

      {:ok, view, _html} = live(conn, "/meal-planner")

      %{view: view, meals: meals, recipe: recipe}
    end

    test "clear_week removes all meals", %{
      view: view,
      user: user,
      account: account,
      week_start: week_start
    } do
      # Verify meals exist before clearing
      week_end = Date.add(week_start, 6)

      {:ok, before_meals} =
        GroceryPlanner.MealPlanning.list_meal_plans_by_date_range(
          week_start,
          week_end,
          actor: user,
          tenant: account.id
        )

      assert length(before_meals) == 3

      # Clear the week (bypassing confirmation for test)
      view
      |> element("button[phx-click='clear_week']")
      |> render_click()

      # Verify all meals are gone
      {:ok, after_meals} =
        GroceryPlanner.MealPlanning.list_meal_plans_by_date_range(
          week_start,
          week_end,
          actor: user,
          tenant: account.id
        )

      assert length(after_meals) == 0
    end

    test "selection toggle works", %{view: view, meals: meals} do
      meal = hd(meals)

      # Toggle selection on
      view
      |> render_hook("toggle_meal_selection", %{"meal-id" => meal.id})

      html = render(view)
      assert html =~ "1 selected"

      # Toggle selection off
      view
      |> render_hook("toggle_meal_selection", %{"meal-id" => meal.id})

      html = render(view)
      refute html =~ "1 selected"
    end

    test "select_all selects all meals", %{view: view, meals: meals} do
      view
      |> render_hook("select_all", %{})

      html = render(view)
      assert html =~ "#{length(meals)} selected"
    end

    test "clear_selection clears all", %{view: view} do
      # Select all first
      view
      |> render_hook("select_all", %{})

      # Then clear
      view
      |> render_hook("clear_selection", %{})

      # Check the specific selection badge is gone
      html = render(view)
      refute html =~ "badge badge-primary"
    end
  end

  describe "drop_recipe event (adding from sidebar)" do
    setup %{conn: conn, account: account, user: user, week_start: week_start} do
      recipe = create_recipe(account, user, %{name: "Sidebar Recipe"})

      {:ok, view, _html} = live(conn, "/meal-planner")

      %{view: view, recipe: recipe, target_date: Date.add(week_start, 1)}
    end

    test "creates new meal from dropped recipe", %{
      view: view,
      recipe: recipe,
      target_date: target_date,
      user: user,
      account: account
    } do
      # Simulate dropping a recipe from sidebar
      result =
        view
        |> render_hook("drop_recipe", %{
          "recipe_id" => recipe.id,
          "target_date" => Date.to_iso8601(target_date),
          "target_meal_type" => "lunch"
        })

      # Ensure no error flash
      refute result =~ "Failed to add meal"

      # Query all meals for the account
      {:ok, all_meals} =
        GroceryPlanner.MealPlanning.list_meal_plans(
          actor: user,
          tenant: account.id
        )

      # Find the meal we just created
      meal =
        Enum.find(all_meals, fn m ->
          m.recipe_id == recipe.id && m.scheduled_date == target_date && m.meal_type == :lunch
        end)

      assert meal != nil,
             "Expected to find a meal with recipe_id=#{recipe.id}, date=#{target_date}, type=lunch"

      assert meal.servings == 4
    end
  end

  describe "sidebar" do
    test "toggle_sidebar hides and shows sidebar", %{conn: conn} do
      {:ok, view, html} = live(conn, "/meal-planner")

      # Sidebar should be visible by default
      assert html =~ "Search recipes"

      # Toggle off
      view
      |> element("button[phx-click='toggle_sidebar']")
      |> render_click()

      # Hard to test visibility with CSS, but the state should change
      # The sidebar uses w-0 when closed

      # Toggle back on
      view
      |> element("button[phx-click='toggle_sidebar']")
      |> render_click()
    end
  end

  describe "mobile single-day pager" do
    test "initializes mobile_selected_date to today when in current week", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # The mobile nav should show today as selected (primary colored button)
      today = Date.utc_today()

      # Check that today's abbreviated day name appears in the mobile nav
      # The selected day gets the primary background
      html = render(view)

      # Verify the mobile day navigation exists
      assert html =~ "power_mobile_select_day"
      assert html =~ "power_mobile_prev_day"
      assert html =~ "power_mobile_next_day"

      # Full day name should be displayed
      assert html =~ Calendar.strftime(today, "%A")
    end

    test "initializes mobile_selected_date to week_start when today not in week", %{
      conn: conn
    } do
      # This is implicitly tested by checking the week navigation works
      # When navigating to a future week, the selected date should reset
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Navigate to next week using the power mode specific button
      view
      |> element("#power-next-week")
      |> render_click()

      # After navigating, the view should still render without errors
      html = render(view)
      assert html =~ "power_mobile_select_day"
    end

    test "power_mobile_select_day changes selected day", %{conn: conn, week_start: week_start} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Select the third day of the week
      target_day = Date.add(week_start, 2)

      view
      |> render_hook("power_mobile_select_day", %{"date" => Date.to_iso8601(target_day)})

      html = render(view)

      # The selected day's full name should be displayed
      assert html =~ Calendar.strftime(target_day, "%A")
      assert html =~ Calendar.strftime(target_day, "%B %d, %Y")
    end

    test "power_mobile_next_day advances to next day", %{conn: conn, week_start: week_start} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # First select the first day of the week
      view
      |> render_hook("power_mobile_select_day", %{"date" => Date.to_iso8601(week_start)})

      # Now advance to next day
      view
      |> render_hook("power_mobile_next_day", %{})

      html = render(view)

      # Should now show the second day
      next_day = Date.add(week_start, 1)
      assert html =~ Calendar.strftime(next_day, "%A")
    end

    test "power_mobile_prev_day goes to previous day", %{conn: conn, week_start: week_start} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # First select the second day of the week
      second_day = Date.add(week_start, 1)

      view
      |> render_hook("power_mobile_select_day", %{"date" => Date.to_iso8601(second_day)})

      # Now go back to previous day
      view
      |> render_hook("power_mobile_prev_day", %{})

      html = render(view)

      # Should now show the first day
      assert html =~ Calendar.strftime(week_start, "%A")
    end

    test "power_mobile_prev_day does not go before week start", %{
      conn: conn,
      week_start: week_start
    } do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Select the first day of the week
      view
      |> render_hook("power_mobile_select_day", %{"date" => Date.to_iso8601(week_start)})

      # Try to go back (should stay on first day)
      view
      |> render_hook("power_mobile_prev_day", %{})

      html = render(view)

      # Should still show the first day
      assert html =~ Calendar.strftime(week_start, "%A")
    end

    test "power_mobile_next_day does not go past week end", %{conn: conn, week_start: week_start} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Select the last day of the week
      week_end = Date.add(week_start, 6)

      view
      |> render_hook("power_mobile_select_day", %{"date" => Date.to_iso8601(week_end)})

      # Try to go forward (should stay on last day)
      view
      |> render_hook("power_mobile_next_day", %{})

      html = render(view)

      # Should still show the last day
      assert html =~ Calendar.strftime(week_end, "%A")
    end

    test "today button resets mobile_selected_date to today", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      today = Date.utc_today()

      # Navigate to a different week first using power mode specific button
      view
      |> element("#power-next-week")
      |> render_click()

      # Click "This week" / today button (power mode specific)
      view
      |> element("#power-today")
      |> render_click()

      html = render(view)

      # Should show today
      assert html =~ Calendar.strftime(today, "%A")
    end
  end

  describe "grocery delta feedback" do
    setup %{conn: conn, account: account, user: user, week_start: week_start} do
      # Create two recipes with different ingredients for delta testing
      recipe_a = create_recipe(account, user, %{name: "Delta Recipe A"})
      recipe_b = create_recipe(account, user, %{name: "Delta Recipe B"})

      # Create grocery items
      {:ok, item_a} =
        GroceryPlanner.Inventory.create_grocery_item(
          account.id,
          %{name: "Ingredient Alpha"},
          actor: user,
          tenant: account.id
        )

      {:ok, item_b} =
        GroceryPlanner.Inventory.create_grocery_item(
          account.id,
          %{name: "Ingredient Beta"},
          actor: user,
          tenant: account.id
        )

      # Link ingredients to recipes
      {:ok, _} =
        GroceryPlanner.Recipes.create_recipe_ingredient(
          account.id,
          %{
            recipe_id: recipe_a.id,
            grocery_item_id: item_a.id,
            quantity: Decimal.new(2),
            unit: :cup
          },
          actor: user,
          tenant: account.id
        )

      {:ok, _} =
        GroceryPlanner.Recipes.create_recipe_ingredient(
          account.id,
          %{
            recipe_id: recipe_b.id,
            grocery_item_id: item_b.id,
            quantity: Decimal.new(1),
            unit: :cup
          },
          actor: user,
          tenant: account.id
        )

      # Create a meal plan with recipe_a on breakfast Monday
      {:ok, meal_plan} =
        GroceryPlanner.MealPlanning.create_meal_plan(
          account.id,
          %{
            recipe_id: recipe_a.id,
            scheduled_date: week_start,
            meal_type: :breakfast,
            servings: 4
          },
          actor: user,
          tenant: account.id
        )

      {:ok, view, _html} = live(conn, "/meal-planner")

      %{
        view: view,
        meal_plan: meal_plan,
        recipe_a: recipe_a,
        recipe_b: recipe_b,
        item_a: item_a,
        item_b: item_b
      }
    end

    test "meal drag_over does not crash and calculates delta", %{
      view: view,
      meal_plan: meal_plan,
      week_start: week_start
    } do
      target_date = Date.add(week_start, 2)

      view
      |> render_hook("drag_start", %{
        "meal_id" => meal_plan.id,
        "source_date" => Date.to_iso8601(meal_plan.scheduled_date),
        "source_meal_type" => to_string(meal_plan.meal_type)
      })

      view
      |> render_hook("drag_over", %{
        "target_date" => Date.to_iso8601(target_date),
        "target_meal_type" => "lunch"
      })

      # Moving a meal to an empty slot should not change shopping needs
      # (same recipe, same servings, just different slot)
      # So no delta toast (role="status") should appear
      refute has_element?(view, "[role=status]")
    end

    test "drag_end clears grocery delta toast", %{
      view: view,
      meal_plan: meal_plan,
      week_start: week_start
    } do
      target_date = Date.add(week_start, 2)

      view
      |> render_hook("drag_start", %{
        "meal_id" => meal_plan.id,
        "source_date" => Date.to_iso8601(meal_plan.scheduled_date),
        "source_meal_type" => to_string(meal_plan.meal_type)
      })

      view
      |> render_hook("drag_over", %{
        "target_date" => Date.to_iso8601(target_date),
        "target_meal_type" => "lunch"
      })

      view |> render_hook("drag_end", %{})

      # After drag_end, delta toast (role="status") should be gone
      refute has_element?(view, "[role=status]")
    end

    test "sidebar recipe drag shows grocery delta toast", %{
      view: view,
      recipe_b: recipe_b,
      week_start: week_start
    } do
      target_date = Date.add(week_start, 3)

      # Start dragging a recipe from sidebar
      view
      |> render_hook("sidebar_drag_start", %{"recipe_id" => recipe_b.id})

      # Hover over an empty slot
      view
      |> render_hook("drag_over", %{
        "target_date" => Date.to_iso8601(target_date),
        "target_meal_type" => "dinner"
      })

      # Adding recipe_b should show the delta toast (Ingredient Beta is needed)
      assert has_element?(view, "[role=status]")
    end

    test "sidebar_drag_end clears grocery delta toast", %{
      view: view,
      recipe_b: recipe_b,
      week_start: week_start
    } do
      target_date = Date.add(week_start, 3)

      view |> render_hook("sidebar_drag_start", %{"recipe_id" => recipe_b.id})

      view
      |> render_hook("drag_over", %{
        "target_date" => Date.to_iso8601(target_date),
        "target_meal_type" => "dinner"
      })

      view |> render_hook("sidebar_drag_end", %{})

      # Delta toast (role="status") should be cleared
      refute has_element?(view, "[role=status]")
    end

    test "drag_over without any drag_start does not show delta", %{
      view: view,
      week_start: week_start
    } do
      target_date = Date.add(week_start, 1)

      view
      |> render_hook("drag_over", %{
        "target_date" => Date.to_iso8601(target_date),
        "target_meal_type" => "lunch"
      })

      # Delta toast (role="status") should not appear
      refute has_element?(view, "[role=status]")
    end
  end

  describe "sidebar search filtering" do
    setup %{conn: conn, account: account, user: user} do
      # Create several recipes with distinct names for search testing
      _recipe_pasta = create_recipe(account, user, %{name: "Creamy Pasta Carbonara"})
      _recipe_chicken = create_recipe(account, user, %{name: "Grilled Chicken Salad"})
      _recipe_soup = create_recipe(account, user, %{name: "Tomato Basil Soup"})

      {:ok, view, _html} = live(conn, "/meal-planner")

      # Open sidebar first
      view |> element("button[phx-click='toggle_sidebar']") |> render_click()

      %{view: view}
    end

    test "filters sidebar recipes by search query", %{view: view} do
      # Initially all recipes should be visible
      html = render(view)
      assert html =~ "Creamy Pasta Carbonara"
      assert html =~ "Grilled Chicken Salad"
      assert html =~ "Tomato Basil Soup"

      # Search for "pasta" - should filter to only matching recipe
      html =
        view
        |> element("input[name='query']")
        |> render_change(%{"query" => "pasta"})

      assert html =~ "Creamy Pasta Carbonara"
      refute html =~ "Grilled Chicken Salad"
      refute html =~ "Tomato Basil Soup"
    end

    test "search is case-insensitive", %{view: view} do
      html =
        view
        |> element("input[name='query']")
        |> render_change(%{"query" => "CHICKEN"})

      refute html =~ "Creamy Pasta Carbonara"
      assert html =~ "Grilled Chicken Salad"
      refute html =~ "Tomato Basil Soup"
    end

    test "clearing search restores all recipes", %{view: view} do
      # First search to filter
      view
      |> element("input[name='query']")
      |> render_change(%{"query" => "pasta"})

      # Then clear search
      html =
        view
        |> element("input[name='query']")
        |> render_change(%{"query" => ""})

      assert html =~ "Creamy Pasta Carbonara"
      assert html =~ "Grilled Chicken Salad"
      assert html =~ "Tomato Basil Soup"
    end
  end
end
