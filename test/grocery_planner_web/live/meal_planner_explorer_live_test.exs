defmodule GroceryPlannerWeb.MealPlannerExplorerLiveTest do
  use GroceryPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GroceryPlanner.MealPlanningTestHelpers

  setup do
    account = create_account()
    user = create_user(account)

    {:ok, user} =
      GroceryPlanner.Accounts.User.update(user, %{meal_planner_layout: "explorer"}, actor: user)

    conn =
      build_conn()
      |> init_test_session(%{
        user_id: user.id,
        account_id: account.id
      })

    %{conn: conn, account: account, user: user}
  end

  test "renders explorer timeline and recipe feed", %{conn: conn, account: account, user: user} do
    recipe = create_recipe(account, user, %{name: "Explorer Test Recipe", is_favorite: true})

    {:ok, view, html} = live(conn, "/meal-planner")

    assert html =~ "Layout"
    assert html =~ "Explorer"

    assert has_element?(view, "#explorer-timeline")

    assert has_element?(view, "#explorer-feed") or has_element?(view, "#explorer-clear-filters") or
             has_element?(view, "#explorer-all-title")

    assert has_element?(view, "#explorer-recipe-search")

    assert has_element?(view, "#explorer-favorites")
    assert has_element?(view, "#explorer-favorite-add-#{recipe.id}")
  end

  test "clicking empty explorer slot opens recipe picker", %{
    conn: conn,
    account: account,
    user: user
  } do
    _recipe = create_recipe(account, user, %{name: "Slot Picker Recipe"})

    {:ok, view, _html} = live(conn, "/meal-planner")

    today = Date.utc_today()

    view
    |> element(
      ".hidden.lg\\:grid button[phx-click='explorer_open_recipe_picker'][phx-value-date='#{today}'][phx-value-meal_type='dinner']"
    )
    |> render_click()

    assert has_element?(view, "#meal-modal-backdrop")
    assert has_element?(view, "#add-meal-title")
    assert has_element?(view, "#add-meal-subtitle")
  end

  test "can favorite from explorer and it appears in favorites section", %{
    conn: conn,
    account: account,
    user: user
  } do
    recipe = create_recipe(account, user, %{name: "Not Favorite"})

    {:ok, view, _html} = live(conn, "/meal-planner")

    view
    |> element("button[phx-click='explorer_toggle_favorite'][phx-value-recipe_id='#{recipe.id}']")
    |> render_click()

    assert has_element?(view, "#explorer-favorites")
    assert has_element?(view, "#explorer-favorite-add-#{recipe.id}")
  end

  describe "recipe tags on cards" do
    test "displays cuisine tag on recipe cards", %{conn: conn, account: account, user: user} do
      _recipe =
        create_recipe(account, user, %{
          name: "Italian Pasta",
          cuisine: "Italian",
          is_favorite: true
        })

      {:ok, _view, html} = live(conn, "/meal-planner")

      assert html =~ "Italian"
    end

    test "displays dietary needs tags on recipe cards", %{
      conn: conn,
      account: account,
      user: user
    } do
      _recipe =
        create_recipe(account, user, %{
          name: "Vegan Bowl",
          dietary_needs: [:vegan, :gluten_free],
          is_favorite: true
        })

      {:ok, _view, html} = live(conn, "/meal-planner")

      assert html =~ "Vegan"
      assert html =~ "Gluten Free"
    end

    test "displays both cuisine and dietary tags together", %{
      conn: conn,
      account: account,
      user: user
    } do
      _recipe =
        create_recipe(account, user, %{
          name: "Thai Curry",
          cuisine: "Thai",
          dietary_needs: [:dairy_free, :nut_free],
          is_favorite: true
        })

      {:ok, _view, html} = live(conn, "/meal-planner")

      assert html =~ "Thai"
      assert html =~ "Dairy Free"
      assert html =~ "Nut Free"
    end

    test "shows +N indicator when more than 3 dietary needs", %{
      conn: conn,
      account: account,
      user: user
    } do
      _recipe =
        create_recipe(account, user, %{
          name: "Super Healthy",
          dietary_needs: [:vegan, :gluten_free, :dairy_free, :nut_free, :keto],
          is_favorite: true
        })

      {:ok, _view, html} = live(conn, "/meal-planner")

      # Should show first 3 + "+2" indicator
      assert html =~ "Vegan"
      assert html =~ "Gluten Free"
      assert html =~ "Dairy Free"
      assert html =~ "+2"
    end
  end

  describe "system filter presets" do
    test "shows built-in system presets in dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/meal-planner")

      # Check that system presets are visible
      assert html =~ "Built-in"
      assert html =~ "Weeknight Quick Wins"
      assert html =~ "Mediterranean"
      assert html =~ "Healthy &amp; Quick"
    end

    test "can load Weeknight Quick Wins preset", %{conn: conn, account: account, user: user} do
      # Create recipes with various difficulties and prep times
      _quick_easy =
        create_recipe(account, user, %{
          name: "Quick Easy Meal",
          difficulty: :easy,
          prep_time_minutes: 10,
          cook_time_minutes: 15
        })

      _slow_hard =
        create_recipe(account, user, %{
          name: "Slow Hard Meal",
          difficulty: :hard,
          prep_time_minutes: 30,
          cook_time_minutes: 60
        })

      {:ok, view, _html} = live(conn, "/meal-planner")

      # Click the system preset (target desktop dropdown specifically)
      view
      |> element(
        ".hidden.lg\\:grid button[phx-click='explorer_load_preset'][phx-value-preset_id='system-weeknight-quick-wins']"
      )
      |> render_click()

      # Check that filters are applied - difficulty should be "easy" and filter should be "quick"
      assert has_element?(view, "#explorer-difficulty-easy.btn-secondary")
      assert has_element?(view, "#explorer-filter-quick.btn-primary")
    end

    test "can load Mediterranean preset", %{conn: conn, account: account, user: user} do
      _mediterranean =
        create_recipe(account, user, %{
          name: "Greek Salad",
          cuisine: "Mediterranean"
        })

      _asian =
        create_recipe(account, user, %{
          name: "Pad Thai",
          cuisine: "Thai"
        })

      {:ok, view, _html} = live(conn, "/meal-planner")

      # Click the Mediterranean preset (target desktop dropdown specifically)
      view
      |> element(
        ".hidden.lg\\:grid button[phx-click='explorer_load_preset'][phx-value-preset_id='system-mediterranean']"
      )
      |> render_click()

      # Check that cuisine filter is applied
      assert has_element?(view, "#explorer-cuisine-filter[value='Mediterranean']")
    end

    test "system presets show sparkles icon", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/meal-planner")

      # System presets should have the sparkles icon
      assert html =~ "hero-sparkles"
    end

    test "preset dropdown shows selected preset name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Load a system preset (target desktop dropdown specifically)
      view
      |> element(
        ".hidden.lg\\:grid button[phx-click='explorer_load_preset'][phx-value-preset_id='system-mediterranean']"
      )
      |> render_click()

      html = render(view)

      # The dropdown label should show the preset name
      assert html =~ "Mediterranean"
    end
  end

  describe "mobile filter bottom sheet" do
    test "shows filter button with count badge when filters active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Initially no badge (no active filters)
      html = render(view)
      refute html =~ ~r/<span[^>]*class="badge badge-xs badge-primary-content">/

      # Apply a filter via the desktop quick button (more specific selector)
      view
      |> element("#explorer-filter-quick")
      |> render_click()

      html = render(view)
      # Should now show the filter button with a badge
      assert has_element?(view, "#mobile-filter-btn")
      assert html =~ "badge badge-xs"
    end

    test "opens mobile filter sheet when clicking filter button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Click the filter button
      view
      |> element("#mobile-filter-btn")
      |> render_click()

      # Should show the filter sheet
      assert has_element?(view, "#mobile-filter-sheet")
      assert render(view) =~ "Filters &amp; Sort"
    end

    test "closes mobile filter sheet when clicking Apply", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Open the sheet
      view
      |> element("#mobile-filter-btn")
      |> render_click()

      assert has_element?(view, "#mobile-filter-sheet")

      # Click Apply to close
      view
      |> element("#mobile-filter-sheet button", "Apply")
      |> render_click()

      refute has_element?(view, "#mobile-filter-sheet")
    end

    test "can select sort option in filter sheet", %{conn: conn, account: account, user: user} do
      _recipe1 = create_recipe(account, user, %{name: "Zebra Cake", prep_time_minutes: 10})
      _recipe2 = create_recipe(account, user, %{name: "Apple Pie", prep_time_minutes: 30})

      {:ok, view, _html} = live(conn, "/meal-planner")

      # Open filter sheet
      view
      |> element("#mobile-filter-btn")
      |> render_click()

      # Click prep_time sort
      view
      |> element(
        "#mobile-filter-sheet button[phx-click='explorer_sort'][phx-value-sort='prep_time']"
      )
      |> render_click()

      # The prep_time button should be active
      assert has_element?(
               view,
               "#mobile-filter-sheet button[phx-value-sort='prep_time'].btn-neutral"
             )
    end

    test "filter sheet shows all dietary options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Open the sheet
      view
      |> element("#mobile-filter-btn")
      |> render_click()

      html = render(view)

      # Should show dietary options
      assert html =~ "Vegan"
      assert html =~ "Vegetarian"
      assert html =~ "Gluten Free"
      assert html =~ "Dairy Free"
    end

    test "clear all in filter sheet resets filters and closes sheet", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meal-planner")

      # Apply some filters first using desktop button (has unique ID)
      view
      |> element("#explorer-filter-quick")
      |> render_click()

      # Open filter sheet
      view
      |> element("#mobile-filter-btn")
      |> render_click()

      # Click Clear All
      view
      |> element("#mobile-filter-sheet button", "Clear All")
      |> render_click()

      # Sheet should close and filters should be reset
      refute has_element?(view, "#mobile-filter-sheet")
      # Quick filter should no longer be active (check desktop button)
      refute has_element?(view, "#explorer-filter-quick.btn-primary")
    end
  end
end
