defmodule GroceryPlannerWeb.AuthController do
  use GroceryPlannerWeb, :controller

  alias GroceryPlanner.Accounts

  def sign_in(conn, %{"user" => %{"email" => email, "password" => password}}) do
    case authenticate_user(email, password) do
      {:ok, user} ->
        conn
        |> GroceryPlannerWeb.Auth.log_in_user(user)
        |> put_flash(:info, "Welcome back!")
        |> redirect(to: "/dashboard")

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Invalid email or password")
        |> redirect(to: "/sign-in")
    end
  end

  def sign_out(conn, _params) do
    conn
    |> GroceryPlannerWeb.Auth.log_out_user()
    |> put_flash(:info, "Signed out successfully.")
    |> redirect(to: "/")
  end

  defp authenticate_user(email, password) do
    case Accounts.User.by_email(email, authorize?: false) do
      {:ok, user} when not is_nil(user) ->
        if Bcrypt.verify_pass(password, user.hashed_password) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end

      {:ok, nil} ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      _ ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end
end
