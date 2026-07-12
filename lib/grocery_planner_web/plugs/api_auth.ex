defmodule GroceryPlannerWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug for authenticating API requests using bearer tokens.
  """
  import Plug.Conn
  alias GroceryPlanner.Accounts.User

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.request_path == "/api/json/open_api" do
      conn
    else
      with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
           {:ok, user_id} <-
             Phoenix.Token.verify(GroceryPlannerWeb.Endpoint, "user auth", token, max_age: 86_400),
           {:ok, user} <- User.by_id(user_id, authorize?: false),
           {:ok, user} <- Ash.load(user, :accounts, authorize?: false) do
        account = List.first(user.accounts)

        conn
        |> assign(:current_user, user)
        |> Ash.PlugHelpers.set_actor(user)
        |> Ash.PlugHelpers.set_tenant(account.id)
      else
        _ ->
          conn
          |> put_resp_content_type("application/vnd.api+json")
          |> send_resp(
            :unauthorized,
            Jason.encode!(%{
              errors: [
                %{
                  id: Ash.UUID.generate(),
                  status: "401",
                  code: "unauthorized",
                  title: "Unauthorized",
                  detail:
                    "Authentication required. Provide a valid Bearer token in the Authorization header."
                }
              ],
              jsonapi: %{version: "1.0"}
            })
          )
          |> halt()
      end
    end
  end
end
