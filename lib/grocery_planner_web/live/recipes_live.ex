defmodule GroceryPlannerWeb.RecipesLive do
  use GroceryPlannerWeb, :live_view
  import GroceryPlannerWeb.UIComponents

  on_mount {GroceryPlannerWeb.Auth, :require_authenticated_user}

  alias GroceryPlanner.Family
  alias GroceryPlanner.Family.MealTimeSolution
  alias GroceryPlanner.MealPlanning.Voting

  @per_page 12

  def mount(_params, _session, socket) do
    voting_active =
      Voting.voting_active?(socket.assigns.current_account.id, socket.assigns.current_user)

    has_family_members? =
      Family.list_family_members!(
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_account.id
      ) != []

    socket =
      socket
      |> assign(:current_scope, socket.assigns.current_account)
      |> assign(:voting_active, voting_active)
      |> assign(:search_query, "")
      |> assign(:show_favorites, false)
      |> assign(:show_chains, false)
      |> assign(:difficulty_filter, nil)
      |> assign(:sort_by, "name")
      |> assign(:prep_time_filter, nil)
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:has_family_members, has_family_members?)
      |> assign(:meal_solution, nil)
      |> assign(:meal_solution_recipe_id, nil)
      |> assign(:excluded_member_ids, MapSet.new())
      |> load_recipes()

    {:ok, socket}
  end

  def handle_event("new_recipe", _, socket) do
    {:noreply, push_navigate(socket, to: "/recipes/new")}
  end

  def handle_event("view_recipe", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/recipes/#{id}")}
  end

  def handle_event("toggle_favorite", %{"id" => id}, socket) do
    actor = socket.assigns.current_user
    tenant = socket.assigns.current_account.id

    with {:ok, recipe} <- GroceryPlanner.Recipes.get_recipe(id, actor: actor, tenant: tenant),
         {:ok, _updated} <-
           GroceryPlanner.Recipes.toggle_favorite(recipe, actor: actor, tenant: tenant) do
      {:noreply, load_recipes(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to update favorite status")}
    end
  end

  def handle_event("toggle_favorites", _, socket) do
    socket =
      socket
      |> assign(:show_favorites, !socket.assigns.show_favorites)
      |> assign(:page, 1)
      |> load_recipes()

    {:noreply, socket}
  end

  def handle_event("toggle_chains", _, socket) do
    socket =
      socket
      |> assign(:show_chains, !socket.assigns.show_chains)
      |> assign(:page, 1)
      |> load_recipes()

    {:noreply, socket}
  end

  def handle_event("search", %{"query" => query}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> assign(:page, 1)
      |> load_recipes()

    {:noreply, socket}
  end

  def handle_event("filter_difficulty", %{"value" => difficulty}, socket) do
    difficulty_atom =
      case difficulty do
        "" -> nil
        "easy" -> :easy
        "medium" -> :medium
        "hard" -> :hard
        _ -> nil
      end

    socket =
      socket
      |> assign(:difficulty_filter, difficulty_atom)
      |> assign(:page, 1)
      |> load_recipes()

    {:noreply, socket}
  end

  def handle_event("sort_by", %{"value" => sort_by}, socket) do
    socket =
      socket
      |> assign(:sort_by, sort_by)
      |> assign(:page, 1)
      |> load_recipes()

    {:noreply, socket}
  end

  def handle_event("filter_prep_time", %{"value" => prep_time}, socket) do
    prep_time_filter =
      case prep_time do
        "" -> nil
        "quick" -> :quick
        "medium" -> :medium
        "long" -> :long
        _ -> nil
      end

    socket =
      socket
      |> assign(:prep_time_filter, prep_time_filter)
      |> assign(:page, 1)
      |> load_recipes()

    {:noreply, socket}
  end

  def handle_event("page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    socket =
      socket
      |> assign(:page, page)
      |> load_recipes()

    {:noreply, socket}
  end

  def handle_event("plan_family_meal", %{"id" => recipe_id}, socket) do
    socket = assign(socket, :excluded_member_ids, MapSet.new())
    {:noreply, recompute_meal_solution(socket, recipe_id)}
  end

  def handle_event("exclude_member", %{"id" => member_id}, socket) do
    excluded = MapSet.put(socket.assigns.excluded_member_ids, member_id)
    socket = assign(socket, :excluded_member_ids, excluded)
    {:noreply, recompute_meal_solution(socket, socket.assigns.meal_solution_recipe_id)}
  end

  def handle_event("include_member", %{"id" => member_id}, socket) do
    excluded = MapSet.delete(socket.assigns.excluded_member_ids, member_id)
    socket = assign(socket, :excluded_member_ids, excluded)
    {:noreply, recompute_meal_solution(socket, socket.assigns.meal_solution_recipe_id)}
  end

  def handle_event("dismiss_meal_solution", _, socket) do
    {:noreply,
     assign(socket,
       meal_solution: nil,
       meal_solution_recipe_id: nil,
       excluded_member_ids: MapSet.new()
     )}
  end

  defp recompute_meal_solution(socket, recipe_id) do
    user = socket.assigns.current_user
    account = socket.assigns.current_account
    excluded = socket.assigns.excluded_member_ids
    opts = [actor: user, tenant: account.id, exclude_member_ids: excluded]

    case GroceryPlanner.Recipes.get_recipe(recipe_id, actor: user, tenant: account.id) do
      {:ok, recipe} ->
        case MealTimeSolution.compute(recipe, opts) do
          {:ok, solution} ->
            assign(socket,
              meal_solution: solution,
              meal_solution_recipe_id: recipe_id
            )

          {:error, :no_family_members} ->
            put_flash(socket, :error, "No family members found")
        end

      _ ->
        put_flash(socket, :error, "Recipe not found")
    end
  end

  defp load_recipes(socket) do
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user
    page = socket.assigns.page
    per_page = socket.assigns.per_page

    input = %{
      search: socket.assigns.search_query,
      favorites: socket.assigns.show_favorites,
      chains: socket.assigns.show_chains,
      difficulty: socket.assigns.difficulty_filter,
      prep_time: socket.assigns.prep_time_filter,
      sort_by: socket.assigns.sort_by
    }

    %Ash.Page.Offset{results: recipes, count: total_count} =
      GroceryPlanner.Recipes.browse_recipes!(
        input,
        actor: user,
        tenant: account_id,
        page: [limit: per_page, offset: (page - 1) * per_page, count: true]
      )

    total_pages = max(1, ceil(total_count / per_page))

    socket
    |> assign(:recipes, recipes)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
  end
end
