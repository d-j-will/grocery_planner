defmodule GroceryPlannerWeb.SettingsLive do
  use GroceryPlannerWeb, :live_view
  import GroceryPlannerWeb.UIComponents

  on_mount({GroceryPlannerWeb.Auth, :require_authenticated_user})

  alias GroceryPlanner.Accounts
  alias GroceryPlanner.MealPlanning.Voting

  def mount(_params, _session, socket) do
    voting_active =
      Voting.voting_active?(socket.assigns.current_account.id, socket.assigns.current_user)

    socket = assign(socket, :current_scope, socket.assigns.current_account)
    actor = socket.assigns.current_user
    account = Ash.load!(socket.assigns.current_account, [:memberships], actor: actor)
    memberships = Ash.load!(account.memberships, [:user], actor: actor)

    current_membership =
      Enum.find(memberships, fn m -> m.user_id == socket.assigns.current_user.id end)

    account_form =
      to_form(
        %{
          "name" => account.name,
          "timezone" => account.timezone,
          "currency" => account.currency
        },
        as: :account
      )

    user_form =
      to_form(
        %{
          "name" => socket.assigns.current_user.name,
          "email" => to_string(socket.assigns.current_user.email),
          "theme" => socket.assigns.current_user.theme,
          "meal_planner_layout" => socket.assigns.current_user.meal_planner_layout,
          "family_focus" => socket.assigns.current_user.family_focus
        },
        as: :user
      )

    invite_form = to_form(%{})

    # Load notification preferences
    user_id = socket.assigns.current_user.id

    notification_preference =
      case GroceryPlanner.Notifications.get_preference_for_user(
             user_id,
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_account.id
           ) do
        {:ok, pref} -> pref
        {:error, _} -> nil
      end

    notification_form =
      if notification_preference do
        to_form(
          %{
            "expiration_alerts_enabled" => notification_preference.expiration_alerts_enabled,
            "expiration_alert_days" => notification_preference.expiration_alert_days,
            "recipe_suggestions_enabled" => notification_preference.recipe_suggestions_enabled,
            "email_notifications_enabled" => notification_preference.email_notifications_enabled,
            "in_app_notifications_enabled" => notification_preference.in_app_notifications_enabled
          },
          as: :notification
        )
      else
        to_form(
          %{
            "expiration_alerts_enabled" => true,
            "expiration_alert_days" => 7,
            "recipe_suggestions_enabled" => true,
            "email_notifications_enabled" => false,
            "in_app_notifications_enabled" => true
          },
          as: :notification
        )
      end

    {:ok,
     socket
     |> assign(:voting_active, voting_active)
     |> assign(:account_form, account_form)
     |> assign(:user_form, user_form)
     |> assign(:invite_form, invite_form)
     |> assign(:notification_form, notification_form)
     |> assign(:notification_preference, notification_preference)
     |> assign(:memberships, memberships)
     |> assign(:current_role, current_membership.role)
     |> assign(:show_invite_form, false)}
  end

  def handle_event("validate_notification", params, socket) do
    # Just update the form to reflect changes (e.g. toggles)
    {:noreply,
     assign(socket, :notification_form, to_form(params["notification"], as: :notification))}
  end

  def handle_event("save_notification", %{"notification" => params}, socket) do
    user = socket.assigns.current_user
    account = socket.assigns.current_account

    result =
      if socket.assigns.notification_preference do
        GroceryPlanner.Notifications.update_notification_preference(
          socket.assigns.notification_preference,
          params,
          actor: user,
          tenant: account.id
        )
      else
        GroceryPlanner.Notifications.create_notification_preference(
          user.id,
          account.id,
          params,
          actor: user,
          tenant: account.id
        )
      end

    case result do
      {:ok, pref} ->
        {:noreply,
         socket
         |> put_flash(:info, "Notification preferences updated successfully")
         |> assign(:notification_preference, pref)
         |> assign(:notification_form, to_form(params, as: :notification))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update notification preferences")}
    end
  end

  def handle_event("validate_account", %{"account" => params}, socket) do
    account_form = to_form(params, as: :account)
    {:noreply, assign(socket, :account_form, account_form)}
  end

  def handle_event("update_account", %{"account" => params}, socket) do
    case Accounts.Account.update(
           socket.assigns.current_account,
           %{
             name: params["name"],
             timezone: params["timezone"],
             currency: params["currency"]
           },
           actor: socket.assigns.current_user
         ) do
      {:ok, account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account updated successfully")
         |> assign(:current_account, account)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update account")}
    end
  end

  def handle_event("validate_user", %{"user" => params}, socket) do
    user_form = to_form(params, as: :user)
    {:noreply, assign(socket, :user_form, user_form)}
  end

  def handle_event("update_user", %{"user" => params}, socket) do
    case Accounts.User.update(
           socket.assigns.current_user,
           %{
             name: params["name"],
             email: params["email"],
             theme: params["theme"],
             meal_planner_layout: params["meal_planner_layout"],
             family_focus: params["family_focus"] == "true"
           },
           actor: socket.assigns.current_user
         ) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Profile updated successfully")
         |> assign(:current_user, user)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update profile")}
    end
  end

  def handle_event("show_invite_form", _params, socket) do
    {:noreply, assign(socket, :show_invite_form, true)}
  end

  def handle_event("hide_invite_form", _params, socket) do
    {:noreply, assign(socket, :show_invite_form, false)}
  end

  def handle_event("validate_invitation", %{"email" => email, "role" => role}, socket) do
    invite_form = to_form(%{"email" => email, "role" => role})
    {:noreply, assign(socket, :invite_form, invite_form)}
  end

  def handle_event("send_invitation", %{"email" => email, "role" => role}, socket) do
    actor = socket.assigns.current_user

    if socket.assigns.current_role in [:owner, :admin] do
      # authorize?: false is safe here: this only resolves an email to a user id
      # for the membership create below, which is itself role-gated by policy.
      case Accounts.User.by_email(email, authorize?: false) do
        {:ok, user} ->
          role_atom = String.to_existing_atom(role)

          case Accounts.AccountMembership.create(
                 socket.assigns.current_account.id,
                 user.id,
                 %{role: role_atom},
                 actor: actor
               ) do
            {:ok, _membership} ->
              memberships =
                socket.assigns.current_account
                |> Ash.load!([:memberships], actor: actor)
                |> Map.get(:memberships)
                |> Ash.load!([:user], actor: actor)

              {:noreply,
               socket
               |> put_flash(:info, "Member added successfully")
               |> assign(:memberships, memberships)
               |> assign(:show_invite_form, false)
               |> assign(:invite_form, to_form(%{}))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to add member")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "User with that email not found")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to add members")}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    actor = socket.assigns.current_user
    membership = Enum.find(socket.assigns.memberships, fn m -> m.id == id end)

    cond do
      is_nil(membership) ->
        {:noreply, put_flash(socket, :error, "Failed to remove member")}

      socket.assigns.current_role not in [:owner, :admin] ->
        {:noreply, put_flash(socket, :error, "You do not have permission to remove members")}

      true ->
        case Accounts.AccountMembership.destroy(membership, actor: actor) do
          :ok ->
            memberships =
              socket.assigns.current_account
              |> Ash.load!([:memberships], actor: actor)
              |> Map.get(:memberships)
              |> Ash.load!([:user], actor: actor)

            {:noreply,
             socket
             |> put_flash(:info, "Member removed successfully")
             |> assign(:memberships, memberships)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to remove member")}
        end
    end
  end
end
