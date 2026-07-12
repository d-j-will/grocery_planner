defmodule GroceryPlannerWeb.MealPlannerLiveTest do
  use GroceryPlannerWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import GroceryPlanner.MealPlanningTestHelpers

  setup do
    account = create_account()
    user = create_user(account)

    {:ok, user} =
      GroceryPlanner.Accounts.User.update(user, %{meal_planner_layout: "focus"}, actor: user)

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

  describe "mount and navigation" do
    test "requires authentication", %{conn: conn} do
      conn = delete_session(conn, :user_id)

      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/meal-planner")
    end

    test "renders meal planner page for authenticated user", %{conn: conn} do
      {:ok, view, html} = live(conn, "/meal-planner")

      assert html =~ "Meal Planner"
      refute html =~ "Plan your weekly meals with ease"
      assert html =~ "Layout"
      assert has_element?(view, "#meal-planner-layout-switcher")
      assert has_element?(view, "#meal-planner-layout-focus")
      assert has_element?(view, "#meal-planner-layout-explorer")
      assert has_element?(view, "#meal-planner-layout-power")
      assert has_element?(view, "a[href='/settings']", "Settings")
      assert has_element?(view, "button[phx-click='prev_week']")
      assert has_element?(view, "button[phx-click='today']", "Today")
      assert has_element?(view, "button[phx-click='next_week']")
    end

    test "displays current week by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/meal-planner")

      today = Date.utc_today()
      week_start = Date.add(today, -(Date.day_of_week(today) - 1))
      week_end = Date.add(week_start, 6)

      assert html =~ Calendar.strftime(week_start, "%B %d")
      assert html =~ Calendar.strftime(week_end, "%B %d, %Y")
    end
  end

  describe "layout switcher" do
    test "switching layout persists on the user and updates the UI", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      assert has_element?(view, "#meal-planner-layout-focus")

      view
      |> element("#meal-planner-layout-explorer")
      |> render_click()

      assert has_element?(view, "#explorer-timeline")
      assert has_element?(view, "#meal-planner-layout-explorer")

      {:ok, updated_user} = GroceryPlanner.Accounts.User.by_id(user.id, actor: user)
      assert updated_user.meal_planner_layout == "explorer"
    end
  end

  describe "viewing meals" do
    setup %{conn: conn, week_start: week_start} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      view
      |> element("#meal-planner-layout-focus")
      |> render_click()

      view
      |> element("#focus-day-#{week_start}")
      |> render_click()

      %{view: view}
    end

    test "displays meals for the week", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Test Meal"})

      tuesday = Date.add(week_start, 1)

      create_meal_plan(account, user, recipe, %{
        scheduled_date: tuesday,
        meal_type: :breakfast,
        servings: 4
      })

      # create meal plan after LV mount; force a data refresh by navigating weeks back/forward
      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      html = render(view)

      assert html =~ "Test Meal"
      assert has_element?(view, "#focus-day-#{tuesday}")
    end

    test "selecting a day shows meal details", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Breakfast Delight"})

      tuesday = Date.add(week_start, 1)

      create_meal_plan(account, user, recipe, %{
        scheduled_date: tuesday,
        meal_type: :breakfast,
        servings: 6
      })

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      html =
        view
        |> element("#focus-day-#{tuesday}")
        |> render_click()

      assert html =~ "Breakfast Delight"
      assert html =~ "6 servings"
      assert has_element?(view, "a[phx-click='edit_meal']")
      assert has_element?(view, "a[phx-click='remove_meal']")
    end
  end

  describe "editing meals" do
    setup %{conn: conn, week_start: week_start} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      view
      |> element("#meal-planner-layout-focus")
      |> render_click()

      view
      |> element("#focus-day-#{week_start}")
      |> render_click()

      %{view: view}
    end

    test "opens edit modal when clicking edit button", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Pasta Carbonara"})

      tuesday = Date.add(week_start, 1)

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: tuesday,
          meal_type: :dinner,
          servings: 4
        })

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      html =
        view
        |> element("a[phx-click='edit_meal'][phx-value-id='#{meal_plan.id}']")
        |> render_click()

      assert html =~ "Edit Meal"
      assert html =~ "Pasta Carbonara"
      assert has_element?(view, "#edit-meal-form")
      assert has_element?(view, "#edit-servings")
      assert has_element?(view, "#edit-notes")
      assert has_element?(view, "button[type='submit']", "Save Changes")
    end

    test "edit modal displays current servings value", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Chicken Curry"})

      tuesday = Date.add(week_start, 1)

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: tuesday,
          meal_type: :lunch,
          servings: 8
        })

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element("a[phx-click='edit_meal'][phx-value-id='#{meal_plan.id}']")
      |> render_click()

      assert has_element?(view, "#edit-servings[value='8']")
    end

    test "edit modal displays current notes value", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Vegetable Stir Fry"})

      tuesday = Date.add(week_start, 1)

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: tuesday,
          meal_type: :dinner,
          servings: 4,
          notes: "Extra spicy please"
        })

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      html =
        view
        |> element("a[phx-click='edit_meal'][phx-value-id='#{meal_plan.id}']")
        |> render_click()

      assert html =~ "Extra spicy please"
    end

    test "updates meal servings successfully", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Salmon Teriyaki"})

      tuesday = Date.add(week_start, 1)

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: tuesday,
          meal_type: :dinner,
          servings: 4
        })

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element("a[phx-click='edit_meal'][phx-value-id='#{meal_plan.id}']")
      |> render_click()

      html =
        view
        |> form("#edit-meal-form", %{servings: "8", notes: ""})
        |> render_submit()

      assert html =~ "Meal updated successfully"
      assert html =~ "8 servings"

      updated_meal_plan =
        Ash.get!(GroceryPlanner.MealPlanning.MealPlan, meal_plan.id,
          actor: user,
          tenant: account.id
        )

      assert updated_meal_plan.servings == 8
    end

    test "updates meal notes successfully", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Beef Tacos"})

      tuesday = Date.add(week_start, 1)

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: tuesday,
          meal_type: :dinner,
          servings: 4
        })

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element("a[phx-click='edit_meal'][phx-value-id='#{meal_plan.id}']")
      |> render_click()

      html =
        view
        |> form("#edit-meal-form", %{servings: "4", notes: "Add extra cheese"})
        |> render_submit()

      assert html =~ "Meal updated successfully"

      updated_meal_plan =
        Ash.get!(GroceryPlanner.MealPlanning.MealPlan, meal_plan.id,
          actor: user,
          tenant: account.id
        )

      assert updated_meal_plan.notes == "Add extra cheese"
    end

    test "updates both servings and notes together", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Greek Salad"})

      tuesday = Date.add(week_start, 1)

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: tuesday,
          meal_type: :lunch,
          servings: 2
        })

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element("a[phx-click='edit_meal'][phx-value-id='#{meal_plan.id}']")
      |> render_click()

      html =
        view
        |> form("#edit-meal-form", %{servings: "6", notes: "Make it large portions"})
        |> render_submit()

      assert html =~ "Meal updated successfully"
      assert html =~ "6 servings"

      updated_meal_plan =
        Ash.get!(GroceryPlanner.MealPlanning.MealPlan, meal_plan.id,
          actor: user,
          tenant: account.id
        )

      assert updated_meal_plan.servings == 6
      assert updated_meal_plan.notes == "Make it large portions"
    end

    test "closes modal after successful update", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Pizza Margherita"})

      tuesday = Date.add(week_start, 1)

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: tuesday,
          meal_type: :dinner,
          servings: 4
        })

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element("a[phx-click='edit_meal'][phx-value-id='#{meal_plan.id}']")
      |> render_click()

      assert has_element?(view, "#edit-meal-modal-backdrop")

      view
      |> form("#edit-meal-form", %{servings: "8", notes: ""})
      |> render_submit()

      refute has_element?(view, "#edit-meal-modal-backdrop")
    end

    test "closes modal when clicking cancel button", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Mushroom Risotto"})

      tuesday = Date.add(week_start, 1)

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: tuesday,
          meal_type: :dinner,
          servings: 4
        })

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element("a[phx-click='edit_meal'][phx-value-id='#{meal_plan.id}']")
      |> render_click()

      assert has_element?(view, "#edit-meal-modal-backdrop")

      view
      |> element("button[phx-click='close_edit_modal']", "Cancel")
      |> render_click()

      refute has_element?(view, "#edit-meal-modal-backdrop")
    end

    test "validates servings is a positive number", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Chocolate Cake"})

      tuesday = Date.add(week_start, 1)

      create_meal_plan(account, user, recipe, %{
        scheduled_date: tuesday,
        meal_type: :snack,
        servings: 4
      })

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element("a[phx-click='edit_meal']")
      |> render_click()

      assert has_element?(view, "#edit-servings[min='1']")
      assert has_element?(view, "#edit-servings[required]")
    end
  end

  describe "removing meals" do
    setup %{conn: conn, week_start: week_start} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      view
      |> element("#meal-planner-layout-focus")
      |> render_click()

      view
      |> element("#focus-day-#{week_start}")
      |> render_click()

      %{view: view}
    end

    test "removes meal when clicking remove button", %{
      view: view,
      account: account,
      user: user,
      week_start: week_start
    } do
      recipe = create_recipe(account, user, %{name: "Burger and Fries"})

      tuesday = Date.add(week_start, 1)

      meal_plan =
        create_meal_plan(account, user, recipe, %{
          scheduled_date: tuesday,
          meal_type: :lunch,
          servings: 2
        })

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      view
      |> element(".sm\\:flex button[phx-click='prev_week']")
      |> render_click()

      view
      |> element("#focus-day-#{tuesday}")
      |> render_click()

      html =
        view
        |> element("a[phx-click='remove_meal'][phx-value-id='#{meal_plan.id}']")
        |> render_click()

      assert html =~ "Meal removed"
      refute html =~ "Burger and Fries"
    end
  end

  describe "chain suggestion" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      view
      |> element("#meal-planner-layout-explorer")
      |> render_click()

      %{view: view}
    end

    test "shows chain suggestion modal after adding a base recipe", %{
      view: view,
      account: account,
      user: user
    } do
      base = create_recipe(account, user, %{name: "Roast Chicken", is_base_recipe: true})

      _follow_up =
        create_recipe(account, user, %{
          name: "Chicken Fried Rice",
          is_follow_up: true,
          parent_recipe_id: base.id
        })

      today = Date.utc_today()
      week_start = Date.add(today, -(Date.day_of_week(today) - 1))
      tuesday = Date.add(week_start, 1)

      # Target the desktop timeline version to avoid duplicate mobile button
      view
      |> element(
        "#explorer-timeline button[phx-click='explorer_open_recipe_picker'][phx-value-date='#{tuesday}'][phx-value-meal_type='lunch']"
      )
      |> render_click()

      html =
        view
        |> element("button[phx-click='select_recipe'][phx-value-id='#{base.id}']")
        |> render_click()

      assert html =~ "Use Those Leftovers!"
      assert html =~ "Roast Chicken"
      assert html =~ "Chicken Fried Rice"
      assert has_element?(view, "#chain-suggestion-modal-backdrop")
    end

    test "does not show chain suggestion modal if all candidate slots are occupied", %{
      view: view,
      account: account,
      user: user
    } do
      base = create_recipe(account, user, %{name: "Roast Chicken", is_base_recipe: true})

      _follow_up =
        create_recipe(account, user, %{
          name: "Chicken Soup",
          is_follow_up: true,
          parent_recipe_id: base.id
        })

      today = Date.utc_today()
      week_start = Date.add(today, -(Date.day_of_week(today) - 1))
      tuesday = Date.add(week_start, 1)

      occupy_recipe = create_recipe(account, user, %{name: "Other"})

      create_meal_plan(account, user, occupy_recipe, %{
        scheduled_date: tuesday,
        meal_type: :dinner,
        servings: 2
      })

      create_meal_plan(account, user, occupy_recipe, %{
        scheduled_date: Date.add(tuesday, 1),
        meal_type: :lunch,
        servings: 2
      })

      create_meal_plan(account, user, occupy_recipe, %{
        scheduled_date: Date.add(tuesday, 1),
        meal_type: :dinner,
        servings: 2
      })

      # Target the desktop timeline version to avoid duplicate mobile button
      view
      |> element(
        "#explorer-timeline button[phx-click='explorer_open_recipe_picker'][phx-value-date='#{tuesday}'][phx-value-meal_type='lunch']"
      )
      |> render_click()

      html =
        view
        |> element("button[phx-click='select_recipe'][phx-value-id='#{base.id}']")
        |> render_click()

      refute html =~ "Use Those Leftovers!"
      refute has_element?(view, "#chain-suggestion-modal-backdrop")
    end

    test "accepting chain suggestion creates follow-up meal plan", %{
      view: view,
      account: account,
      user: user
    } do
      base = create_recipe(account, user, %{name: "Roast Chicken", is_base_recipe: true})

      follow_up =
        create_recipe(account, user, %{
          name: "Chicken Soup",
          is_follow_up: true,
          parent_recipe_id: base.id
        })

      today = Date.utc_today()
      week_start = Date.add(today, -(Date.day_of_week(today) - 1))
      tuesday = Date.add(week_start, 1)

      # Target the desktop timeline version to avoid duplicate mobile button
      view
      |> element(
        "#explorer-timeline button[phx-click='explorer_open_recipe_picker'][phx-value-date='#{tuesday}'][phx-value-meal_type='lunch']"
      )
      |> render_click()

      view
      |> element("button[phx-click='select_recipe'][phx-value-id='#{base.id}']")
      |> render_click()

      view
      |> element("button[phx-click='accept_chain_suggestion']")
      |> render_click()

      {:ok, meal_plans} =
        GroceryPlanner.MealPlanning.list_meal_plans(
          actor: user,
          tenant: account.id,
          query: GroceryPlanner.MealPlanning.MealPlan |> Ash.Query.sort(scheduled_date: :asc)
        )

      assert Enum.any?(meal_plans, fn mp -> mp.recipe_id == follow_up.id end)
    end
  end

  describe "week navigation" do
    test "navigates to next week", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      today = Date.utc_today()
      week_start = Date.add(today, -(Date.day_of_week(today) - 1))
      next_week_start = Date.add(week_start, 7)

      html =
        view
        |> element(".sm\\:flex button[phx-click='next_week']")
        |> render_click()

      assert html =~ Calendar.strftime(next_week_start, "%B %d")
    end

    test "navigates to previous week", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      today = Date.utc_today()
      week_start = Date.add(today, -(Date.day_of_week(today) - 1))
      prev_week_start = Date.add(week_start, -7)

      html =
        view
        |> element(".sm\\:flex button[phx-click='prev_week']")
        |> render_click()

      assert html =~ Calendar.strftime(prev_week_start, "%B %d")
    end

    test "navigates back to current week with Today button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      today = Date.utc_today()
      week_start = Date.add(today, -(Date.day_of_week(today) - 1))

      view
      |> element(".sm\\:flex button[phx-click='next_week']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='today']")
        |> render_click()

      assert html =~ Calendar.strftime(week_start, "%B %d")
    end
  end
end
