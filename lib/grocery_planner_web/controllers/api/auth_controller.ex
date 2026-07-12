defmodule GroceryPlannerWeb.Api.AuthController do
  use GroceryPlannerWeb, :controller

  alias GroceryPlanner.Accounts.User

  def sign_in(conn, %{"email" => email, "password" => password}) do
    with {:ok, user} <- User.by_email(email, authorize?: false),
         true <- Bcrypt.verify_pass(password, user.hashed_password) do
      token = Phoenix.Token.sign(GroceryPlannerWeb.Endpoint, "user auth", user.id)

      json(conn, %{
        data: %{
          token: token,
          user_id: user.id,
          email: user.email,
          name: user.name
        }
      })
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid email or password"})
    end
  end
end
