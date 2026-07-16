defmodule GroceryPlannerWeb.ObservabilityTest do
  @moduledoc """
  Boundary tests for the Arc 3 observability surface: the /metrics scrape
  endpoint and the admin-gated Oban dashboard.
  """
  # async: false — PromEx/Peep is a global metric store, and these tests read the
  # scrape output, so they must not race other tests emitting metrics.
  use GroceryPlannerWeb.ConnCase, async: false

  alias GroceryPlanner.PromEx.ReceiptPlugin

  defp create_user_with_email(email) do
    {:ok, user} =
      GroceryPlanner.Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        name: "Op #{System.unique_integer()}",
        email: email,
        password: "password123456"
      })
      |> Ash.create(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user.id)
  end

  describe "GET /metrics" do
    test "exposes Prometheus metrics including the receipt outage gauge", %{conn: conn} do
      # Emit the domain metric once so the polled gauge has a sample to scrape.
      ReceiptPlugin.execute_receipt_metrics()

      body = conn |> get("/metrics") |> response(200)

      assert body =~ "grocery_planner_prom_ex_receipt_condition_count"
      assert body =~ ~s(condition="awaiting_ai")
    end
  end

  describe "GET /admin/oban" do
    test "bounces unauthenticated users to sign-in", %{conn: conn} do
      conn = get(conn, "/admin/oban")
      assert redirected_to(conn) == "/sign-in"
    end

    test "404s an authenticated non-admin (dashboard existence is not advertised)", %{conn: conn} do
      user = create_user_with_email("member#{System.unique_integer()}@example.com")

      conn = conn |> log_in(user) |> get("/admin/oban")

      assert conn.status == 404
    end

    # The allow case is asserted at the gate (the plug) rather than by rendering
    # the full dashboard: Oban Web's mount needs Oban.Met running, which Oban's
    # `testing: :manual` mode strips. The gate is the boundary this change owns;
    # the dashboard render is exercised manually in dev where Oban runs fully.
    test "lets an allowlisted admin through the gate" do
      # config/test.exs allowlists admin@example.com
      admin = create_user_with_email("admin@example.com")

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:current_user, admin)
        |> GroceryPlannerWeb.Plugs.RequireAdmin.call([])

      refute conn.halted
    end

    test "the gate halts a non-admin even with a current_user assigned" do
      member = create_user_with_email("member#{System.unique_integer()}@example.com")

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:current_user, member)
        |> GroceryPlannerWeb.Plugs.RequireAdmin.call([])

      assert conn.halted
      assert conn.status == 404
    end
  end
end
