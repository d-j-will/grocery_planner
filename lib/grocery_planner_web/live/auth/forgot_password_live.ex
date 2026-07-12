defmodule GroceryPlannerWeb.Auth.ForgotPasswordLive do
  use GroceryPlannerWeb, :live_view
  require Logger

  alias GroceryPlanner.Accounts
  alias GroceryPlanner.Accounts.UserEmail

  def mount(_params, _session, socket) do
    form = to_form(%{}, as: :user)
    {:ok, assign(socket, form: form, submitted: false)}
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    {:noreply, assign(socket, form: to_form(user_params, as: :user))}
  end

  def handle_event("request_reset", %{"user" => %{"email" => email}}, socket) do
    # Always show success to prevent email enumeration
    send_reset_email_if_user_exists(email)

    {:noreply,
     socket
     |> assign(submitted: true)
     |> put_flash(
       :info,
       "If an account exists with that email, you will receive password reset instructions shortly."
     )}
  end

  defp send_reset_email_if_user_exists(email) do
    case Accounts.User.by_email(email, authorize?: false) do
      {:ok, user} when not is_nil(user) ->
        case Accounts.User.request_password_reset(user, authorize?: false) do
          {:ok, updated_user} ->
            reset_url = build_reset_url(updated_user.reset_password_token)

            case UserEmail.send_password_reset_email(updated_user, reset_url) do
              {:ok, _} ->
                Logger.info("Password reset email sent to #{email}")

              {:error, reason} ->
                Logger.error("Failed to send password reset email: #{inspect(reason)}")
            end

          {:error, reason} ->
            Logger.error("Failed to generate reset token: #{inspect(reason)}")
        end

      _ ->
        # Don't reveal that the user doesn't exist
        :ok
    end
  end

  defp build_reset_url(token) do
    GroceryPlannerWeb.Endpoint.url() <> "/reset-password/#{token}"
  end
end
