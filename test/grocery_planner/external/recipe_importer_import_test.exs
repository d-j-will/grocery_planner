defmodule GroceryPlanner.External.RecipeImporterImportTest do
  use GroceryPlanner.DataCase, async: true

  alias GroceryPlanner.Accounts
  alias GroceryPlanner.External.RecipeImporter
  alias GroceryPlanner.External.TheMealDB
  alias GroceryPlanner.Inventory

  @base_meal %{
    "idMeal" => "52940",
    "strMeal" => "Brown Stew Chicken",
    "strCategory" => "Chicken",
    "strArea" => "Jamaican",
    "strInstructions" => "Instructions...",
    "strMealThumb" => "https://example.com/image.jpg",
    "strYoutube" => "",
    "strSource" => "",
    "strTags" => "Stew",
    "strIngredient1" => "Chicken",
    "strMeasure1" => "1 whole",
    "strIngredient2" => "Tomato",
    "strMeasure2" => "2",
    "strIngredient3" => "Onions",
    "strMeasure3" => "2 chopped"
  }

  setup do
    {:ok, account} = Accounts.Account.create(%{name: "Import Test"}, authorize?: false)
    %{account: account}
  end

  defp stub_lookup(meal) do
    Req.Test.stub(TheMealDB, fn conn ->
      Req.Test.json(conn, %{"meals" => [meal]})
    end)
  end

  defp grocery_item_names(account) do
    {:ok, items} = Inventory.list_grocery_items(authorize?: false, tenant: account.id)
    items |> Enum.map(& &1.name) |> Enum.sort()
  end

  describe "import_recipe/2" do
    test "creates the recipe with its ingredients", %{account: account} do
      stub_lookup(@base_meal)

      assert {:ok, recipe} = RecipeImporter.import_recipe("52940", account.id)
      assert recipe.name == "Brown Stew Chicken"

      recipe = Ash.load!(recipe, [:recipe_ingredients], authorize?: false, tenant: account.id)
      assert length(recipe.recipe_ingredients) == 3
      assert grocery_item_names(account) == ["Chicken", "Onions", "Tomato"]
    end

    test "re-importing does not duplicate grocery items", %{account: account} do
      stub_lookup(@base_meal)

      assert {:ok, _recipe} = RecipeImporter.import_recipe("52940", account.id)
      names_after_first = grocery_item_names(account)

      assert {:ok, _recipe} = RecipeImporter.import_recipe("52940", account.id)

      assert grocery_item_names(account) == names_after_first
    end

    test "surfaces an ingredient creation failure as an error", %{account: account} do
      # A whitespace-only ingredient survives TheMealDB parsing as name: ""
      # and fails GroceryItem's allow_nil? false - previously this was
      # silently swallowed and the import reported success.
      stub_lookup(Map.merge(@base_meal, %{"strIngredient2" => "   ", "strMeasure2" => "2"}))

      assert {:error, _error} = RecipeImporter.import_recipe("52940", account.id)
    end
  end
end
