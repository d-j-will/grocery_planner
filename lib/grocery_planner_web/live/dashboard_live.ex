defmodule GroceryPlannerWeb.DashboardLive do
  use GroceryPlannerWeb, :live_view
  import GroceryPlannerWeb.UIComponents

  on_mount {GroceryPlannerWeb.Auth, :require_authenticated_user}

  alias GroceryPlanner.AI.MealOptimizer
  alias GroceryPlanner.MealPlanning
  alias GroceryPlanner.MealPlanning.Voting
  alias GroceryPlanner.Notifications.ExpirationAlerts
  alias GroceryPlanner.Notifications.RecipeSuggestions

  def mount(_params, _session, socket) do
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user
    voting_active = Voting.voting_active?(account_id, user)

    # Load expiration alerts
    {:ok, expiring_summary} =
      ExpirationAlerts.get_expiring_summary(account_id, user, days_threshold: 7)

    {:ok, expiring_items} =
      ExpirationAlerts.get_expiring_items(account_id, user, days_threshold: 7)

    # Load recipe suggestions based on expiring items
    {:ok, recipe_suggestions} =
      RecipeSuggestions.get_suggestions_for_expiring_items(account_id, user,
        days_threshold: 7,
        limit: 5
      )

    socket =
      socket
      |> assign(:current_scope, socket.assigns.current_account)
      |> assign(:voting_active, voting_active)
      |> assign(:expiring_summary, expiring_summary)
      |> assign(:expiring_items, expiring_items)
      |> assign(:recipe_suggestions, recipe_suggestions)
      |> assign(:rescue_suggestions, nil)
      |> assign(:rescue_loading, false)

    {:ok, socket}
  end

  def handle_event("get_rescue_plan", _params, socket) do
    account_id = socket.assigns.current_account.id
    user = socket.assigns.current_user

    socket = assign(socket, :rescue_loading, true)

    case MealOptimizer.suggest_for_expiring(account_id, user, limit: 5) do
      {:ok, suggestions} ->
        {:noreply,
         socket
         |> assign(:rescue_suggestions, suggestions)
         |> assign(:rescue_loading, false)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:rescue_loading, false)
         |> put_flash(:error, "Couldn't generate rescue plan. Please try again.")}
    end
  end

  def handle_event("add_rescue_to_plan", %{"recipe-id" => recipe_id}, socket) do
    account_id = socket.assigns.current_account.id

    case MealPlanning.place_meal(
           %{
             recipe_id: recipe_id,
             scheduled_date: Date.utc_today(),
             meal_type: :dinner,
             servings: 2
           },
           authorize?: false,
           tenant: account_id
         ) do
      {:ok, _meal_plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Added to today's meal plan!")}

      {:error, _error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't add to meal plan.")}
    end
  end
end
