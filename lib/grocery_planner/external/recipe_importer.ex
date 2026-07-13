defmodule GroceryPlanner.External.RecipeImporter do
  @moduledoc """
  Imports recipes from TheMealDB into the local database.
  Handles recipe creation, ingredient parsing, and grocery item matching.
  """

  alias GroceryPlanner.External
  alias GroceryPlanner.External.TheMealDB

  @doc """
  Imports a recipe from TheMealDB by external ID.
  Creates the recipe, associated grocery items, and recipe ingredients.
  """
  def import_recipe(external_id, account_id) do
    with {:ok, meal} <- External.get_external_recipe(external_id),
         recipe_attrs <- TheMealDB.to_recipe_attrs(Map.from_struct(meal)),
         {:ok, recipe} <-
           GroceryPlanner.Recipes.create_recipe(
             account_id,
             recipe_attrs,
             authorize?: false,
             tenant: account_id
           ),
         :ok <- import_ingredients(meal.ingredients, recipe.id, account_id) do
      {:ok, recipe}
    end
  end

  @doc """
  Imports a list of ingredients for a recipe, creating grocery items as needed.

  Returns `:ok` when every ingredient was created, or `{:error, error}` for the
  first ingredient that failed.
  """
  def import_ingredients(ingredients, recipe_id, account_id) do
    ingredients
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {ingredient, index}, :ok ->
      {quantity, unit} = parse_measure(ingredient.measure)

      with {:ok, grocery_item} <- find_or_create_grocery_item(ingredient.name, account_id),
           {:ok, _recipe_ingredient} <-
             GroceryPlanner.Recipes.create_recipe_ingredient(
               account_id,
               %{
                 recipe_id: recipe_id,
                 grocery_item_id: grocery_item.id,
                 quantity: quantity,
                 unit: unit,
                 sort_order: index
               },
               authorize?: false,
               tenant: account_id
             ) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  Finds an existing grocery item by name (case-insensitive) or creates a new one.
  """
  def find_or_create_grocery_item(item_name, account_id) do
    # authorize?: false, not a nil actor: with no actor, relates_to_actor_via
    # policies silently return [] and every import duplicates grocery items
    # (see item_matcher.ex for the same convention).
    case GroceryPlanner.Inventory.list_grocery_items(authorize?: false, tenant: account_id) do
      {:ok, items} ->
        case Enum.find(items, fn item ->
               String.downcase(item.name) == String.downcase(item_name)
             end) do
          nil ->
            GroceryPlanner.Inventory.create_grocery_item(
              account_id,
              %{name: item_name},
              authorize?: false,
              tenant: account_id
            )

          item ->
            {:ok, item}
        end

      error ->
        error
    end
  end

  @doc """
  Parses a TheMealDB measure string into {quantity, unit}.

  ## Examples

      iex> parse_measure("1 cup")
      {1.0, "cup"}

      iex> parse_measure("1.5 kg")
      {1.5, "kg"}

      iex> parse_measure("pinch")
      {1.0, "pinch"}

      iex> parse_measure(nil)
      {1.0, ""}
  """
  def parse_measure(measure) when is_binary(measure) do
    case Regex.run(~r/^(\d+\.?\d*)\s*(.*)$/, String.trim(measure)) do
      [_, qty_str, unit] ->
        {String.to_float(qty_str <> if(String.contains?(qty_str, "."), do: "", else: ".0")),
         String.trim(unit)}

      _ ->
        {1.0, measure}
    end
  end

  def parse_measure(_), do: {1.0, ""}
end
