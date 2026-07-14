defmodule GroceryPlanner.Recipes.RecipeBrowseTest do
  @moduledoc """
  Boundary tests for the deep `Recipes.browse_recipes/2` read action — the single
  filtered/sorted/paginated recipe query that replaces the in-memory filtering
  previously duplicated across the recipe LiveViews. One test per argument so a
  failing Ash expression isolates to exactly one filter.
  """
  use GroceryPlanner.DataCase, async: true

  import GroceryPlanner.InventoryTestHelpers

  alias GroceryPlanner.Recipes

  setup do
    {account, user} = create_account_and_user()
    %{account: account, user: user}
  end

  defp mk(account, user, attrs) do
    {:ok, recipe} =
      Recipes.create_recipe(
        account.id,
        Map.merge(%{name: "R#{System.unique_integer([:positive])}"}, attrs),
        actor: user,
        tenant: account.id
      )

    recipe
  end

  defp browse(account, user, input, opts \\ []) do
    Recipes.browse_recipes!(input, [actor: user, tenant: account.id] ++ opts)
  end

  defp names(recipes), do: recipes |> Enum.map(& &1.name) |> Enum.sort()

  describe "search (name, case-insensitive)" do
    test "matches a substring of the name regardless of case", %{account: a, user: u} do
      mk(a, u, %{name: "Chicken Curry"})
      mk(a, u, %{name: "Beef Stew"})

      assert names(browse(a, u, %{search: "chick"})) == ["Chicken Curry"]
      assert names(browse(a, u, %{search: "STEW"})) == ["Beef Stew"]
    end

    test "blank/nil search returns everything", %{account: a, user: u} do
      mk(a, u, %{name: "Chicken Curry"})
      mk(a, u, %{name: "Beef Stew"})

      assert length(browse(a, u, %{search: ""})) == 2
      assert length(browse(a, u, %{})) == 2
    end
  end

  describe "difficulty" do
    test "filters to the exact difficulty", %{account: a, user: u} do
      mk(a, u, %{name: "Easy", difficulty: :easy})
      mk(a, u, %{name: "Hard", difficulty: :hard})

      assert names(browse(a, u, %{difficulty: :easy})) == ["Easy"]
    end
  end

  describe "prep_time buckets (nil treated as 0)" do
    setup %{account: a, user: u} do
      mk(a, u, %{name: "Quick", prep_time_minutes: 10, cook_time_minutes: 15})
      mk(a, u, %{name: "NilTimes", prep_time_minutes: nil, cook_time_minutes: nil})
      mk(a, u, %{name: "Medium", prep_time_minutes: 20, cook_time_minutes: 25})
      mk(a, u, %{name: "Long", prep_time_minutes: 60, cook_time_minutes: 40})
      :ok
    end

    test "quick is total <= 30, counting nil as 0", %{account: a, user: u} do
      assert names(browse(a, u, %{prep_time: :quick})) == ["NilTimes", "Quick"]
    end

    test "medium is 31..60", %{account: a, user: u} do
      assert names(browse(a, u, %{prep_time: :medium})) == ["Medium"]
    end

    test "long is > 60", %{account: a, user: u} do
      assert names(browse(a, u, %{prep_time: :long})) == ["Long"]
    end
  end

  describe "favorites" do
    test "true returns only favorites; false/nil returns all", %{account: a, user: u} do
      mk(a, u, %{name: "Fav", is_favorite: true})
      mk(a, u, %{name: "Plain", is_favorite: false})

      assert names(browse(a, u, %{favorites: true})) == ["Fav"]
      assert length(browse(a, u, %{favorites: false})) == 2
    end
  end

  describe "chains" do
    test "true returns base or follow-up recipes only", %{account: a, user: u} do
      mk(a, u, %{name: "Base", is_base_recipe: true})
      mk(a, u, %{name: "FollowUp", is_follow_up: true})
      mk(a, u, %{name: "Plain"})

      assert names(browse(a, u, %{chains: true})) == ["Base", "FollowUp"]
    end
  end

  describe "cuisine (case-insensitive)" do
    test "matches a substring of the cuisine", %{account: a, user: u} do
      mk(a, u, %{name: "Pasta", cuisine: "Italian"})
      mk(a, u, %{name: "PadThai", cuisine: "Thai"})

      assert names(browse(a, u, %{cuisine: "ital"})) == ["Pasta"]
    end
  end

  describe "dietary_needs (must satisfy ALL selected)" do
    test "contains-all semantics", %{account: a, user: u} do
      mk(a, u, %{name: "VeganGF", dietary_needs: [:vegan, :gluten_free]})
      mk(a, u, %{name: "VeganOnly", dietary_needs: [:vegan]})
      mk(a, u, %{name: "None", dietary_needs: []})

      # one need -> every recipe that has it
      assert names(browse(a, u, %{dietary_needs: [:vegan]})) == ["VeganGF", "VeganOnly"]
      # two needs -> only the recipe that has both
      assert names(browse(a, u, %{dietary_needs: [:vegan, :gluten_free]})) == ["VeganGF"]
    end
  end

  describe "sort_by" do
    test "name sorts alphabetically (default)", %{account: a, user: u} do
      mk(a, u, %{name: "Banana"})
      mk(a, u, %{name: "Apple"})

      assert Enum.map(browse(a, u, %{sort_by: "name"}), & &1.name) == ["Apple", "Banana"]
      # default (no sort_by) is also name-ascending
      assert Enum.map(browse(a, u, %{}), & &1.name) == ["Apple", "Banana"]
    end

    test "difficulty sorts easy < medium < hard", %{account: a, user: u} do
      mk(a, u, %{name: "H", difficulty: :hard})
      mk(a, u, %{name: "E", difficulty: :easy})
      mk(a, u, %{name: "M", difficulty: :medium})

      assert Enum.map(browse(a, u, %{sort_by: "difficulty"}), & &1.name) == ["E", "M", "H"]
    end

    test "prep_time sorts by ascending total time", %{account: a, user: u} do
      mk(a, u, %{name: "Slow", prep_time_minutes: 60, cook_time_minutes: 30})
      mk(a, u, %{name: "Fast", prep_time_minutes: 5, cook_time_minutes: 5})

      assert Enum.map(browse(a, u, %{sort_by: "prep_time"}), & &1.name) == ["Fast", "Slow"]
    end
  end

  describe "pagination (optional offset)" do
    test "no page: option returns a plain list", %{account: a, user: u} do
      for _ <- 1..3, do: mk(a, u, %{})
      assert is_list(browse(a, u, %{}))
    end

    test "page: returns a page with results and total count", %{account: a, user: u} do
      for i <- 1..5, do: mk(a, u, %{name: "P#{i}"})

      page = browse(a, u, %{sort_by: "name"}, page: [limit: 2, offset: 2, count: true])

      assert %Ash.Page.Offset{results: results, count: 5} = page
      assert length(results) == 2
    end

    test "paging through a non-unique sort key drops or dupes nothing (id tiebreaker)",
         %{account: a, user: u} do
      # All identical difficulty -> the sort key ties across every row; without a
      # stable tiebreaker offset paging would skip/repeat rows at page boundaries.
      for i <- 1..5, do: mk(a, u, %{name: "T#{i}", difficulty: :medium})

      p1 = browse(a, u, %{sort_by: "difficulty"}, page: [limit: 2, offset: 0])
      p2 = browse(a, u, %{sort_by: "difficulty"}, page: [limit: 2, offset: 2])
      p3 = browse(a, u, %{sort_by: "difficulty"}, page: [limit: 2, offset: 4])

      seen = Enum.map(p1.results ++ p2.results ++ p3.results, & &1.id)
      assert length(seen) == 5
      assert length(Enum.uniq(seen)) == 5
    end
  end

  describe "tenant isolation" do
    test "only returns recipes from the actor's account", %{account: a, user: u} do
      mk(a, u, %{name: "Mine"})

      {other_account, other_user} = create_account_and_user()
      mk(other_account, other_user, %{name: "Theirs"})

      assert names(browse(a, u, %{})) == ["Mine"]
    end
  end
end
