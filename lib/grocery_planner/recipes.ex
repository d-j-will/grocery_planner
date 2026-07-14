defmodule GroceryPlanner.Recipes do
  @moduledoc false
  use Ash.Domain,
    extensions: [AshJsonApi.Domain]

  json_api do
    prefix "/api/json"
  end

  resources do
    resource GroceryPlanner.Recipes.RecipeTag do
      define :create_recipe_tag, action: :create, args: [:account_id]
      define :list_recipe_tags, action: :read
      define :get_recipe_tag, action: :read, get_by: [:id]
      define :update_recipe_tag, action: :update
      define :destroy_recipe_tag, action: :destroy
    end

    resource GroceryPlanner.Recipes.Recipe do
      define :create_recipe, action: :create, args: [:account_id]
      define :list_recipes, action: :read
      define :list_favorite_recipes, action: :favorites
      define :list_recipes_sorted, action: :list_all_sorted
      define :list_recipes_for_meal_planner, action: :meal_planner_recipes
      define :browse_recipes, action: :browse
      define :get_recipe, action: :read, get_by: [:id]
      define :update_recipe, action: :update
      define :destroy_recipe, action: :destroy
      define :toggle_base_recipe, action: :toggle_base_recipe
      define :toggle_favorite, action: :toggle_favorite
      define :link_as_follow_up, action: :link_as_follow_up, args: [:parent_recipe_id]
      define :unlink_from_parent, action: :unlink_from_parent
      define :sync_recipes, action: :sync, args: [:since]
      define :pull_recipes, action: :sync, args: [:since, :limit]
    end

    resource GroceryPlanner.Recipes.RecipeIngredient do
      define :create_recipe_ingredient, action: :create, args: [:account_id]
      define :list_recipe_ingredients, action: :read
      define :get_recipe_ingredient, action: :read, get_by: [:id]
      define :update_recipe_ingredient, action: :update
      define :destroy_recipe_ingredient, action: :destroy
      define :sync_recipe_ingredients, action: :sync, args: [:since]
      define :pull_recipe_ingredients, action: :sync, args: [:since, :limit]
    end

    resource GroceryPlanner.Recipes.RecipeTagging do
      define :create_recipe_tagging, action: :create
      define :list_recipe_taggings, action: :read
      define :destroy_recipe_tagging, action: :destroy
    end

    resource GroceryPlanner.Recipes.FilterPreset do
      define :create_filter_preset, action: :create, args: [:user_id]
      define :list_filter_presets, action: :read
      define :get_filter_preset, action: :read, get_by: [:id]
      define :update_filter_preset, action: :update
      define :destroy_filter_preset, action: :destroy
    end
  end

  @doc """
  Case-insensitive, nil-safe recipe-name substring match.

  The shared in-memory search predicate for the meal-planner and family pickers,
  which deliberately filter a cached, association-loaded recipe list rather than
  re-querying per keystroke. (DB-side browsing lives in `browse_recipes/2`.)
  A blank query matches everything.
  """
  def name_matches?(_recipe, query) when query in [nil, ""], do: true

  def name_matches?(recipe, query) do
    String.contains?(String.downcase(recipe.name || ""), String.downcase(query))
  end
end
