defmodule GroceryPlannerWeb.Auth.ForgotPasswordLiveTest do
  use GroceryPlannerWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias GroceryPlanner.Accounts.User

  test "renders forgot password page", %{conn: conn} do
    {:ok, view, html} = live(conn, "/forgot-password")

    assert html =~ "Forgot Password"
    assert html =~ "Remember your password?"
    assert has_element?(view, "form#forgot-password-form")
  end

  test "shows success message after submitting email", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/forgot-password")

    view
    |> form("#forgot-password-form", user: %{email: "test@example.com"})
    |> render_submit()

    assert has_element?(view, "div", "If an account exists")
  end

  test "shows success message even for non-existent email (prevents enumeration)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/forgot-password")

    view
    |> form("#forgot-password-form", user: %{email: "nonexistent@example.com"})
    |> render_submit()

    # Should still show success message to prevent email enumeration
    assert has_element?(view, "div", "If an account exists")
  end

  test "generates reset token for existing user", %{conn: conn} do
    # Create a user
    {:ok, user} =
      User.create(
        "resettest@example.com",
        "Reset Test User",
        "password123",
        authorize?: false
      )

    assert user.reset_password_token == nil

    {:ok, view, _html} = live(conn, "/forgot-password")

    view
    |> form("#forgot-password-form", user: %{email: "resettest@example.com"})
    |> render_submit()

    # Verify the user now has a reset token
    {:ok, updated_user} = User.by_email("resettest@example.com", authorize?: false)
    assert updated_user.reset_password_token != nil
    assert updated_user.reset_password_sent_at != nil
  end

  test "has link back to sign in", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/forgot-password")

    assert has_element?(view, "a[href='/sign-in']")
  end
end
