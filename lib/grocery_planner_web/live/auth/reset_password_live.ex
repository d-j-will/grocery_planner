defmodule GroceryPlannerWeb.Auth.ResetPasswordLive do
  use GroceryPlannerWeb, :live_view
  require Logger

  alias GroceryPlanner.Accounts

  @token_max_age_seconds 3600

  def mount(%{"token" => token}, _session, socket) do
    case validate_token(token) do
      {:ok, user} ->
        form = to_form(%{}, as: :user)
        {:ok, assign(socket, form: form, user: user, token: token, token_valid: true)}

      {:error, reason} ->
        {:ok,
         socket
         |> assign(token_valid: false, error_reason: reason)
         |> put_flash(:error, token_error_message(reason))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    {:noreply, assign(socket, form: to_form(user_params, as: :user))}
  end

  def handle_event("reset_password", %{"user" => user_params}, socket) do
    %{"password" => password, "password_confirmation" => password_confirmation} = user_params

    cond do
      password != password_confirmation ->
        {:noreply,
         socket
         |> put_flash(:error, "Passwords do not match")
         |> assign(form: to_form(user_params, as: :user))}

      String.length(password) < 8 ->
        {:noreply,
         socket
         |> put_flash(:error, "Password must be at least 8 characters")
         |> assign(form: to_form(user_params, as: :user))}

      true ->
        case Accounts.User.reset_password(socket.assigns.user, password, authorize?: false) do
          {:ok, _user} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Password reset successfully. Please sign in with your new password."
             )
             |> push_navigate(to: "/sign-in")}

          {:error, error} ->
            Logger.error("Failed to reset password: #{inspect(error)}")

            {:noreply,
             socket
             |> put_flash(:error, "Failed to reset password. Please try again.")
             |> assign(form: to_form(user_params, as: :user))}
        end
    end
  end

  defp validate_token(token) do
    case Accounts.User.by_reset_token(token, authorize?: false) do
      {:ok, user} when not is_nil(user) ->
        if token_expired?(user.reset_password_sent_at) do
          {:error, :expired}
        else
          {:ok, user}
        end

      _ ->
        {:error, :invalid}
    end
  end

  defp token_expired?(nil), do: true

  defp token_expired?(sent_at) do
    DateTime.diff(DateTime.utc_now(), sent_at, :second) > @token_max_age_seconds
  end

  defp token_error_message(:expired),
    do: "This password reset link has expired. Please request a new one."

  defp token_error_message(:invalid),
    do: "This password reset link is invalid. Please request a new one."
end
