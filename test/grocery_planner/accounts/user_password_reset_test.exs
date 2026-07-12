defmodule GroceryPlanner.Accounts.UserPasswordResetTest do
  use GroceryPlanner.DataCase, async: true

  alias GroceryPlanner.Accounts.User

  describe "request_password_reset/1" do
    test "generates a reset token and timestamp" do
      {:ok, user} = create_test_user()

      assert user.reset_password_token == nil
      assert user.reset_password_sent_at == nil

      {:ok, updated_user} = User.request_password_reset(user, authorize?: false)

      assert updated_user.reset_password_token != nil
      assert updated_user.reset_password_sent_at != nil
      assert String.length(updated_user.reset_password_token) > 20
    end

    test "generates a new token on each request" do
      {:ok, user} = create_test_user()

      {:ok, first_update} = User.request_password_reset(user, authorize?: false)
      {:ok, second_update} = User.request_password_reset(first_update, authorize?: false)

      assert first_update.reset_password_token != second_update.reset_password_token
    end
  end

  describe "by_reset_token/1" do
    test "finds user by valid reset token" do
      {:ok, user} = create_test_user()
      {:ok, updated_user} = User.request_password_reset(user, authorize?: false)

      {:ok, found_user} =
        User.by_reset_token(updated_user.reset_password_token, authorize?: false)

      assert found_user.id == user.id
    end

    test "returns error for invalid token" do
      result = User.by_reset_token("invalid-token", authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = result
    end
  end

  describe "reset_password/2" do
    test "updates password and clears reset token" do
      {:ok, user} = create_test_user()
      {:ok, user_with_token} = User.request_password_reset(user, authorize?: false)

      new_password = "newpassword123"
      {:ok, reset_user} = User.reset_password(user_with_token, new_password, authorize?: false)

      assert reset_user.reset_password_token == nil
      assert reset_user.reset_password_sent_at == nil
      assert Bcrypt.verify_pass(new_password, reset_user.hashed_password)
    end

    test "old password no longer works after reset" do
      old_password = "oldpassword123"
      {:ok, user} = create_test_user(old_password)
      {:ok, user_with_token} = User.request_password_reset(user, authorize?: false)

      new_password = "newpassword456"
      {:ok, reset_user} = User.reset_password(user_with_token, new_password, authorize?: false)

      refute Bcrypt.verify_pass(old_password, reset_user.hashed_password)
      assert Bcrypt.verify_pass(new_password, reset_user.hashed_password)
    end
  end

  describe "token expiration" do
    test "token_expired? returns false for recent tokens" do
      {:ok, user} = create_test_user()
      {:ok, updated_user} = User.request_password_reset(user, authorize?: false)

      # Token should not be expired immediately after creation
      refute token_expired?(updated_user.reset_password_sent_at)
    end

    test "token_expired? returns true for old tokens" do
      # Simulate a token sent 2 hours ago
      old_time = DateTime.add(DateTime.utc_now(), -7200, :second)

      assert token_expired?(old_time)
    end
  end

  # Helper functions

  defp create_test_user(password \\ "password123") do
    email = "test-#{System.unique_integer([:positive])}@example.com"
    User.create(email, "Test User", password, authorize?: false)
  end

  # Mirror the token expiration logic from the LiveView
  defp token_expired?(nil), do: true

  defp token_expired?(sent_at) do
    DateTime.diff(DateTime.utc_now(), sent_at, :second) > 3600
  end
end
