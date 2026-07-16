defmodule GroceryPlannerWeb.Plugs.RequireAdmin do
  @moduledoc """
  Gates operator-only routes (the Oban Web dashboard) to a configured
  allowlist of admin emails.

  The dashboard exposes job args across *every* tenant, so plain
  `:require_authenticated_user` is not enough — any household member would see
  every other household's receipts. There is no global admin flag on `User`
  (roles are per-account: owner/admin/member), so operator access is an
  out-of-band allowlist instead: `config :grocery_planner, :admin_emails`,
  populated from `ADMIN_EMAILS` in prod. Empty by default → deny.

  Non-admins get a bare 404 (not a redirect) so the route's existence is not
  advertised. This plug runs *after* `:require_authenticated_user`, so an
  unauthenticated request is already bounced to sign-in before it reaches here.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    user = conn.assigns[:current_user]

    if user && admin?(user.email) do
      conn
    else
      conn
      |> send_resp(404, "Not found")
      |> halt()
    end
  end

  defp admin?(email) do
    normalized = email |> to_string() |> String.downcase()
    normalized != "" and normalized in admin_emails()
  end

  defp admin_emails do
    :grocery_planner
    |> Application.get_env(:admin_emails, [])
    |> Enum.map(&(&1 |> to_string() |> String.downcase()))
  end
end
