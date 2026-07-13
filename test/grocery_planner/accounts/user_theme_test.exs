defmodule GroceryPlanner.Accounts.UserThemeTest do
  use GroceryPlanner.DataCase, async: true

  alias GroceryPlanner.Accounts.User

  describe "theme validation" do
    test "accepts all valid Skillet themes" do
      valid_themes = ~w[fairway orchard marble dark]

      for theme <- valid_themes do
        {:ok, user} =
          User.create(
            "test-#{theme}@example.com",
            "Test User",
            "password123password123"
          )

        assert {:ok, updated} = User.update(user, %{theme: theme}, actor: user)
        assert updated.theme == theme
      end
    end

    test "rejects invalid themes" do
      {:ok, user} =
        User.create(
          "test@example.com",
          "Test User",
          "password123password123"
        )

      # Retired stock daisyUI themes are no longer valid
      assert {:error, error} = User.update(user, %{theme: "synthwave"}, actor: user)
      assert error.errors |> Enum.any?(fn e -> e.field == :theme end)

      assert {:error, error} = User.update(user, %{theme: "light"}, actor: user)
      assert error.errors |> Enum.any?(fn e -> e.field == :theme end)

      # Test with random invalid theme
      assert {:error, error} = User.update(user, %{theme: "invalid_theme"}, actor: user)
      assert error.errors |> Enum.any?(fn e -> e.field == :theme end)
    end

    test "defaults to fairway theme for new users" do
      {:ok, user} =
        User.create(
          "newuser@example.com",
          "New User",
          "password123password123"
        )

      assert user.theme == "fairway"
    end

    test "allows updating theme after user creation" do
      {:ok, user} =
        User.create(
          "themed@example.com",
          "Themed User",
          "password123password123"
        )

      assert user.theme == "fairway"

      {:ok, updated} = User.update(user, %{theme: "marble"}, actor: user)
      assert updated.theme == "marble"
    end
  end
end
