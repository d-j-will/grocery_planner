defmodule GroceryPlannerWeb.MealPlannerFocusLiveTest do
  use GroceryPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GroceryPlanner.MealPlanningTestHelpers

  setup do
    account = create_account()
    user = create_user(account)

    {:ok, user} =
      GroceryPlanner.Accounts.User.update(user, %{meal_planner_layout: "focus"}, actor: user)

    conn =
      build_conn()
      |> init_test_session(%{
        user_id: user.id,
        account_id: account.id
      })

    %{conn: conn, account: account, user: user}
  end

  describe "focus mode rendering" do
    test "renders focus mode with day header and week strip", %{conn: conn} do
      {:ok, view, html} = live(conn, "/meal-planner")

      assert has_element?(view, "#focus-mode")

      today = Date.utc_today()
      assert html =~ Calendar.strftime(today, "%A, %B %d")
      assert html =~ "Planning"
    end

    test "shows all 4 meal type slots", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/meal-planner")

      assert html =~ "breakfast"
      assert html =~ "lunch"
      assert html =~ "dinner"
      assert html =~ "snack"
    end

    test "empty slots show Add buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/meal-planner")

      assert html =~ "Add breakfast"
      assert html =~ "Add lunch"
      assert html =~ "Add dinner"
      assert html =~ "Add snack"
    end
  end

  describe "day navigation" do
    test "selecting a different day updates the header", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      tomorrow = Date.utc_today() |> Date.add(1)

      html = render_click(view, "focus_select_day", %{"date" => Date.to_iso8601(tomorrow)})

      assert html =~ Calendar.strftime(tomorrow, "%A, %B %d")
    end

    test "jump to today button appears on non-today day and works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      tomorrow = Date.utc_today() |> Date.add(1)
      render_click(view, "focus_select_day", %{"date" => Date.to_iso8601(tomorrow)})

      html = render(view)
      assert html =~ "Jump to Today"

      html = render_click(view, "focus_today", %{})

      today = Date.utc_today()
      assert html =~ Calendar.strftime(today, "%A, %B %d")
    end
  end

  describe "viewing meals" do
    test "planned meal shows recipe name and servings", %{
      conn: conn,
      account: account,
      user: user
    } do
      recipe = create_recipe(account, user, %{name: "Grilled Salmon"})
      today = Date.utc_today()

      create_meal_plan(account, user, recipe, %{
        scheduled_date: today,
        meal_type: :dinner,
        servings: 4
      })

      {:ok, _view, html} = live(conn, "/meal-planner")

      assert html =~ "Grilled Salmon"
      assert html =~ "4 servings"
    end

    test "planned meal shows status badge", %{conn: conn, account: account, user: user} do
      recipe = create_recipe(account, user, %{name: "Pasta Primavera"})
      today = Date.utc_today()

      create_meal_plan(account, user, recipe, %{
        scheduled_date: today,
        meal_type: :lunch,
        servings: 2
      })

      {:ok, _view, html} = live(conn, "/meal-planner")

      assert html =~ "planned"
    end

    test "filled slot does not show Add button for that meal type", %{
      conn: conn,
      account: account,
      user: user
    } do
      recipe = create_recipe(account, user, %{name: "Morning Oats"})
      today = Date.utc_today()

      create_meal_plan(account, user, recipe, %{
        scheduled_date: today,
        meal_type: :breakfast,
        servings: 1
      })

      {:ok, _view, html} = live(conn, "/meal-planner")

      assert html =~ "Morning Oats"
      # The other empty slots still show Add buttons
      assert html =~ "Add lunch"
      assert html =~ "Add dinner"
      assert html =~ "Add snack"
    end
  end

  describe "quick recipe picker" do
    test "opening picker from empty slot shows the picker", %{
      conn: conn,
      account: account,
      user: user
    } do
      _recipe = create_recipe(account, user, %{name: "Picker Recipe"})

      {:ok, view, _html} = live(conn, "/meal-planner")

      today = Date.utc_today()

      render_click(view, "focus_open_picker", %{
        "date" => Date.to_iso8601(today),
        "meal_type" => "dinner"
      })

      html = render(view)

      assert html =~ "Add Dinner"
      assert html =~ "Search recipes"
      assert html =~ "Picker Recipe"
    end

    test "selecting a recipe from picker creates a meal plan and closes picker", %{
      conn: conn,
      account: account,
      user: user
    } do
      recipe = create_recipe(account, user, %{name: "Selected Recipe"})

      {:ok, view, _html} = live(conn, "/meal-planner")

      today = Date.utc_today()

      render_click(view, "focus_open_picker", %{
        "date" => Date.to_iso8601(today),
        "meal_type" => "dinner"
      })

      render_click(view, "focus_select_recipe", %{"id" => recipe.id})

      # The focus_select_recipe event sends {:add_meal_internal, ...} via send/2.
      # Calling render/1 processes that pending message and refreshes week meals.
      html = render(view)

      # Picker should be closed
      refute html =~ "Search recipes"

      # Meal should now appear after the async message was processed
      assert html =~ "Selected Recipe"
    end

    test "search in picker filters recipes", %{conn: conn, account: account, user: user} do
      _recipe1 = create_recipe(account, user, %{name: "Chicken Soup"})
      _recipe2 = create_recipe(account, user, %{name: "Veggie Stir Fry"})

      {:ok, view, _html} = live(conn, "/meal-planner")

      today = Date.utc_today()

      render_click(view, "focus_open_picker", %{
        "date" => Date.to_iso8601(today),
        "meal_type" => "dinner"
      })

      html =
        render_click(view, "focus_search_recipes", %{"value" => "Chicken"})

      assert html =~ "Chicken Soup"
      refute html =~ "Veggie Stir Fry"
    end
  end

  describe "copy previous day" do
    test "copies yesterday's meals to today", %{conn: conn, account: account, user: user} do
      recipe = create_recipe(account, user, %{name: "Yesterday Dinner"})
      yesterday = Date.utc_today() |> Date.add(-1)

      create_meal_plan(account, user, recipe, %{
        scheduled_date: yesterday,
        meal_type: :dinner,
        servings: 4
      })

      {:ok, view, _html} = live(conn, "/meal-planner")

      render_click(view, "copy_previous_day", %{})

      # render/1 processes the pending {:refresh_meals} message which reloads week data
      html = render(view)

      assert html =~ "Copied meals from yesterday"
      assert html =~ "Yesterday Dinner"
    end

    test "copies meals across the week boundary (Monday copying from Sunday)", %{
      conn: conn,
      account: account,
      user: user
    } do
      # Regression: source meals used to be read from the week_meals cache,
      # which only holds the displayed week - so on Mondays "yesterday" was
      # never found. Pin the Monday case by selecting the week's first day.
      today = Date.utc_today()
      monday = Date.add(today, -(Date.day_of_week(today) - 1))
      sunday_before = Date.add(monday, -1)

      recipe = create_recipe(account, user, %{name: "Sunday Dinner"})

      create_meal_plan(account, user, recipe, %{
        scheduled_date: sunday_before,
        meal_type: :dinner,
        servings: 4
      })

      {:ok, view, _html} = live(conn, "/meal-planner")

      render_click(view, "focus_select_day", %{"date" => Date.to_iso8601(monday)})
      render_click(view, "copy_previous_day", %{})

      html = render(view)

      assert html =~ "Copied meals from yesterday"
      assert html =~ "Sunday Dinner"
    end

    test "shows info flash when no meals on previous day", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      html = render_click(view, "copy_previous_day", %{})

      assert html =~ "No meals found on previous day"
    end
  end

  describe "repeat last week" do
    test "repeats previous week's meals to current week", %{
      conn: conn,
      account: account,
      user: user
    } do
      recipe = create_recipe(account, user, %{name: "Last Week Recipe"})

      today = Date.utc_today()
      day_of_week = Date.day_of_week(today, :monday)
      week_start = Date.add(today, -(day_of_week - 1))
      prev_week_day = Date.add(week_start, -7)

      create_meal_plan(account, user, recipe, %{
        scheduled_date: prev_week_day,
        meal_type: :dinner,
        servings: 3
      })

      {:ok, view, _html} = live(conn, "/meal-planner")

      html = render_click(view, "repeat_last_week", %{})

      assert html =~ "Repeated"
      assert html =~ "meals from last week"
    end

    test "shows info flash when no meals in last week", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      html = render_click(view, "repeat_last_week", %{})

      assert html =~ "No meals found in last week"
    end
  end

  describe "auto-fill day" do
    test "auto-fills dinner slot with a favorite recipe", %{
      conn: conn,
      account: account,
      user: user
    } do
      _recipe = create_recipe(account, user, %{name: "Favorite Dinner", is_favorite: true})

      {:ok, view, _html} = live(conn, "/meal-planner")

      html = render_click(view, "auto_fill_day", %{})

      assert html =~ "Auto-filled dinner"
    end

    test "shows info flash when no favorites exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      html = render_click(view, "auto_fill_day", %{})

      assert html =~ "Mark some favorites to use Auto-fill"
    end

    test "shows info flash when dinner is already planned", %{
      conn: conn,
      account: account,
      user: user
    } do
      recipe = create_recipe(account, user, %{name: "Existing Dinner", is_favorite: true})
      today = Date.utc_today()

      create_meal_plan(account, user, recipe, %{
        scheduled_date: today,
        meal_type: :dinner,
        servings: 4
      })

      {:ok, view, _html} = live(conn, "/meal-planner")

      html = render_click(view, "auto_fill_day", %{})

      assert html =~ "Dinner already planned for today"
    end
  end

  describe "meal prep" do
    test "repeats meal for remaining days of the week", %{
      conn: conn,
      account: account,
      user: user
    } do
      recipe = create_recipe(account, user, %{name: "Prep Meal"})

      today = Date.utc_today()
      day_of_week = Date.day_of_week(today, :monday)
      week_start = Date.add(today, -(day_of_week - 1))

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: week_start,
          meal_type: :dinner,
          servings: 4
        })

      {:ok, view, _html} = live(conn, "/meal-planner")

      html = render_click(view, "meal_prep", %{"id" => meal_plan.id})

      assert html =~ "Repeated meal for"
      assert html =~ "days"
    end
  end

  describe "remove meal" do
    test "removes meal when clicking remove", %{conn: conn, account: account, user: user} do
      recipe = create_recipe(account, user, %{name: "Removable Meal"})
      today = Date.utc_today()

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: today,
          meal_type: :dinner,
          servings: 4
        })

      {:ok, view, _html} = live(conn, "/meal-planner")

      html = render(view)
      assert html =~ "Removable Meal"

      render_click(view, "remove_meal", %{"id" => meal_plan.id})

      html = render(view)
      refute html =~ "Removable Meal"
      assert html =~ "Add dinner"
    end
  end

  describe "mark complete" do
    test "marks meal as completed", %{conn: conn, account: account, user: user} do
      recipe = create_recipe(account, user, %{name: "Completable Meal"})
      today = Date.utc_today()

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: today,
          meal_type: :dinner,
          servings: 4
        })

      {:ok, view, _html} = live(conn, "/meal-planner")

      html = render_click(view, "mark_complete", %{"id" => meal_plan.id})

      assert html =~ "Meal marked as completed"
    end
  end

  describe "week navigation" do
    test "navigating to next week and back preserves focus mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      render_click(view, "next_week", %{})
      html = render_click(view, "prev_week", %{})

      assert has_element?(view, "#focus-mode")
      assert html =~ "Planning"
    end
  end
end
