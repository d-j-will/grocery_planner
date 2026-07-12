defmodule GroceryPlannerWeb.Auth do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, :fetch_current_user) do
    fetch_current_user(conn, [])
  end

  def call(conn, :require_authenticated_user) do
    require_authenticated_user(conn, [])
  end

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket =
      Phoenix.Component.assign_new(socket, :current_user, fn ->
        find_current_user(session)
      end)

    socket =
      Phoenix.Component.assign_new(socket, :current_account, fn ->
        find_current_account(socket.assigns.current_user)
      end)

    if socket.assigns.current_user && socket.assigns.current_account do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: "/sign-in")

      {:halt, socket}
    end
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    socket =
      Phoenix.Component.assign_new(socket, :current_user, fn ->
        find_current_user(session)
      end)

    socket =
      Phoenix.Component.assign_new(socket, :current_account, fn ->
        find_current_account(socket.assigns[:current_user])
      end)

    {:cont, socket}
  end

  defp find_current_user(session) do
    with user_id when not is_nil(user_id) <- session["user_id"],
         {:ok, user} <- GroceryPlanner.Accounts.User.by_id(user_id, authorize?: false) do
      user
    else
      _ -> nil
    end
  end

  defp find_current_account(nil), do: nil

  defp find_current_account(user) do
    user = Ash.load!(user, [memberships: :account], authorize?: false, actor: user)

    case user.memberships do
      [] -> nil
      [membership | _] -> membership.account
    end
  end

  def by_id!(user_id) do
    case GroceryPlanner.Accounts.User.by_id(user_id, authorize?: false) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  def log_in_user(conn, user) do
    conn
    |> put_session(:user_id, user.id)
    |> configure_session(renew: true)
  end

  def log_out_user(conn) do
    conn
    |> configure_session(drop: true)
  end

  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, :user_id)
    user = user_id && by_id!(user_id)
    account = user && find_current_account(user)

    conn
    |> assign(:current_user, user)
    |> assign(:current_account, account)
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(to: "/sign-in")
      |> halt()
    end
  end
end
