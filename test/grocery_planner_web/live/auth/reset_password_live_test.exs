defmodule GroceryPlannerWeb.Auth.ResetPasswordLiveTest do
  use GroceryPlannerWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias GroceryPlanner.Accounts.User

  describe "with valid token" do
    setup do
      {:ok, user} =
        User.create(
          "reset-valid-#{System.unique_integer([:positive])}@example.com",
          "Reset User",
          "oldpassword123",
          authorize?: false
        )

      {:ok, user_with_token} = User.request_password_reset(user, authorize?: false)

      %{user: user_with_token, token: user_with_token.reset_password_token}
    end

    test "renders reset password page", %{conn: conn, token: token} do
      {:ok, view, html} = live(conn, "/reset-password/#{token}")

      assert html =~ "Reset Password"
      assert html =~ "Enter your new password"
      assert has_element?(view, "form#reset-password-form")
    end

    test "resets password successfully", %{conn: conn, token: token, user: user} do
      {:ok, view, _html} = live(conn, "/reset-password/#{token}")

      view
      |> form("#reset-password-form",
        user: %{password: "newpassword123", password_confirmation: "newpassword123"}
      )
      |> render_submit()

      # Should redirect to sign-in
      assert_redirect(view, "/sign-in")

      # Verify password was changed
      {:ok, updated_user} = User.by_id(user.id, authorize?: false)
      assert Bcrypt.verify_pass("newpassword123", updated_user.hashed_password)
      assert updated_user.reset_password_token == nil
    end

    test "shows error when passwords don't match", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, "/reset-password/#{token}")

      view
      |> form("#reset-password-form",
        user: %{password: "newpassword123", password_confirmation: "differentpassword"}
      )
      |> render_submit()

      assert render(view) =~ "Passwords do not match"
    end

    test "shows error when password is too short", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, "/reset-password/#{token}")

      view
      |> form("#reset-password-form",
        user: %{password: "short", password_confirmation: "short"}
      )
      |> render_submit()

      assert render(view) =~ "Password must be at least 8 characters"
    end
  end

  describe "with invalid token" do
    test "shows error for invalid token", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/reset-password/invalid-token")

      assert html =~ "Invalid Reset Link"
      assert html =~ "invalid or has already been used"
    end

    test "shows link to request new reset", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/reset-password/invalid-token")

      assert has_element?(view, "a[href='/forgot-password']")
    end
  end

  describe "with expired token" do
    test "shows error for expired token", %{conn: conn} do
      # Create a user with an expired token
      {:ok, user} =
        User.create(
          "expired-#{System.unique_integer([:positive])}@example.com",
          "Expired User",
          "password123",
          authorize?: false
        )

      # Request password reset
      {:ok, user_with_token} = User.request_password_reset(user, authorize?: false)

      # Manually set the sent_at to 2 hours ago (expired)
      old_time = DateTime.add(DateTime.utc_now(), -7200, :second)

      {:ok, _} =
        user_with_token
        |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:reset_password_sent_at, old_time)
        |> Ash.update(authorize?: false)

      {:ok, _view, html} = live(conn, "/reset-password/#{user_with_token.reset_password_token}")

      assert html =~ "Invalid Reset Link"
      assert html =~ "expired"
    end
  end
end
