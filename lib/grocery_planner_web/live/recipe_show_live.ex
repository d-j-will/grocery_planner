defmodule GroceryPlannerWeb.RecipeShowLive do
  use GroceryPlannerWeb, :live_view
  import GroceryPlannerWeb.UIComponents

  on_mount {GroceryPlannerWeb.Auth, :require_authenticated_user}

  alias GroceryPlanner.MealPlanning.Voting

  def mount(%{"id" => id}, _session, socket) do
    case load_recipe(socket, id) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :not_found} ->
        socket =
          socket
          |> put_flash(:error, "Recipe not found")
          |> push_navigate(to: "/recipes")

        {:ok, socket}
    end
  end

  def handle_event("toggle_favorite", _, socket) do
    case GroceryPlanner.Recipes.update_recipe(
           socket.assigns.recipe,
           %{is_favorite: !socket.assigns.recipe.is_favorite},
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, _updated_recipe} ->
        case load_recipe(socket, socket.assigns.recipe.id) do
          {:ok, updated_socket} ->
            {:noreply, updated_socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to reload recipe")}
        end

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Failed to update favorite status")}
    end
  end

  def handle_event("edit_recipe", _, socket) do
    {:noreply, push_navigate(socket, to: "/recipes/#{socket.assigns.recipe.id}/edit")}
  end

  def handle_event("delete_recipe", _, socket) do
    result =
      GroceryPlanner.Recipes.destroy_recipe(
        socket.assigns.recipe,
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id
      )

    case result do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Recipe deleted successfully")
          |> push_navigate(to: "/recipes")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete recipe")}
    end
  end

  def handle_event("add_ingredient", _, socket) do
    {:noreply, push_navigate(socket, to: "/recipes/#{socket.assigns.recipe.id}/edit")}
  end

  # Chain management event handlers

  def handle_event("toggle_base_recipe", _, socket) do
    recipe = socket.assigns.recipe

    case GroceryPlanner.Recipes.toggle_base_recipe(
           recipe,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, _updated} ->
        {:ok, socket} = load_recipe(socket, recipe.id)
        {:noreply, put_flash(socket, :info, "Recipe updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update recipe")}
    end
  end

  def handle_event("open_link_modal", _, socket) do
    available = load_linkable_recipes(socket)
    {:noreply, assign(socket, show_link_modal: true, available_recipes_for_linking: available)}
  end

  def handle_event("close_link_modal", _, socket) do
    {:noreply, assign(socket, show_link_modal: false, link_search_query: "")}
  end

  def handle_event("search_linkable_recipes", %{"value" => query}, socket) do
    available = load_linkable_recipes(socket, query)
    {:noreply, assign(socket, link_search_query: query, available_recipes_for_linking: available)}
  end

  def handle_event("link_recipe", %{"id" => follow_up_id}, socket) do
    parent_recipe = socket.assigns.recipe

    case GroceryPlanner.Recipes.get_recipe(follow_up_id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, follow_up} ->
        case GroceryPlanner.Recipes.link_as_follow_up(
               follow_up,
               parent_recipe.id,
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_account.id
             ) do
          {:ok, _} ->
            {:ok, socket} = load_recipe(socket, parent_recipe.id)
            socket = assign(socket, show_link_modal: false, link_search_query: "")
            {:noreply, put_flash(socket, :info, "Recipe linked as follow-up")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to link recipe")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Recipe not found")}
    end
  end

  def handle_event("unlink_follow_up", %{"id" => follow_up_id}, socket) do
    case GroceryPlanner.Recipes.get_recipe(follow_up_id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, follow_up} ->
        case GroceryPlanner.Recipes.unlink_from_parent(
               follow_up,
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_account.id
             ) do
          {:ok, _} ->
            {:ok, socket} = load_recipe(socket, socket.assigns.recipe.id)
            {:noreply, put_flash(socket, :info, "Follow-up unlinked")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to unlink recipe")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Recipe not found")}
    end
  end

  def handle_event("create_follow_up", _, socket) do
    parent_id = socket.assigns.recipe.id
    {:noreply, push_navigate(socket, to: "/recipes/new?parent_recipe_id=#{parent_id}")}
  end

  def handle_event("unlink_from_parent", _, socket) do
    recipe = socket.assigns.recipe

    case GroceryPlanner.Recipes.unlink_from_parent(
           recipe,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, _} ->
        {:ok, socket} = load_recipe(socket, recipe.id)
        {:noreply, put_flash(socket, :info, "Unlinked from parent recipe")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unlink")}
    end
  end

  def handle_event("edit_ingredient_usage", %{"id" => ingredient_id}, socket) do
    ingredient = Enum.find(socket.assigns.ingredients, &(&1.id == ingredient_id))
    {:noreply, assign(socket, show_ingredient_modal: true, editing_ingredient: ingredient)}
  end

  def handle_event("close_ingredient_modal", _, socket) do
    {:noreply, assign(socket, show_ingredient_modal: false, editing_ingredient: nil)}
  end

  def handle_event("update_usage_type", %{"usage_type" => usage_type}, socket) do
    ingredient = socket.assigns.editing_ingredient
    usage_atom = String.to_existing_atom(usage_type)

    case GroceryPlanner.Recipes.update_recipe_ingredient(
           ingredient,
           %{usage_type: usage_atom},
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_account.id
         ) do
      {:ok, _} ->
        {:ok, socket} = load_recipe(socket, socket.assigns.recipe.id)
        socket = assign(socket, show_ingredient_modal: false, editing_ingredient: nil)
        {:noreply, put_flash(socket, :info, "Ingredient updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update ingredient")}
    end
  end

  def handle_event("prevent_close", _, socket) do
    {:noreply, socket}
  end

  defp load_linkable_recipes(socket, query \\ "") do
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user
    current_recipe_id = socket.assigns.recipe.id

    # Name search runs in the DB via browse_recipes; the linking-specific
    # exclusions stay here. take(20) is applied AFTER the rejects so the list
    # can't fall short of 20.
    GroceryPlanner.Recipes.browse_recipes!(%{search: query}, actor: user, tenant: account_id)
    # Exclude current recipe and already-linked follow-ups
    |> Enum.reject(fn r ->
      r.id == current_recipe_id || r.parent_recipe_id == current_recipe_id
    end)
    # Exclude recipes that are already follow-ups of other parents
    |> Enum.reject(fn r -> r.is_follow_up end)
    |> Enum.take(20)
  end

  defp load_recipe(socket, id) do
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user
    voting_active = Voting.voting_active?(account_id, user)

    case GroceryPlanner.Recipes.get_recipe(id, actor: user, tenant: account_id) do
      {:ok, recipe} ->
        recipe_with_ingredients =
          recipe
          |> Ash.load!([:recipe_ingredients, :parent_recipe, :follow_up_recipes],
            actor: user,
            tenant: account_id
          )

        ingredients =
          case recipe_with_ingredients.recipe_ingredients do
            %Ash.NotLoaded{} ->
              []

            ingredients when is_list(ingredients) ->
              ingredients
              |> Enum.map(fn ingredient ->
                Ash.load!(ingredient, :grocery_item, actor: user, tenant: account_id)
              end)
              |> Enum.sort_by(& &1.sort_order)

            _ ->
              []
          end

        socket =
          socket
          |> assign(:current_scope, socket.assigns.current_account)
          |> assign(:voting_active, voting_active)
          |> assign(:recipe, recipe_with_ingredients)
          |> assign(:ingredients, ingredients)
          |> assign(:show_link_modal, false)
          |> assign(:available_recipes_for_linking, [])
          |> assign(:link_search_query, "")
          |> assign(:show_ingredient_modal, false)
          |> assign(:editing_ingredient, nil)

        {:ok, socket}

      {:error, _} ->
        {:error, :not_found}
    end
  end
end
