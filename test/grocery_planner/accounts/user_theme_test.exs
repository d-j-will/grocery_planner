defmodule GroceryPlanner.Accounts.UserThemeTest do
  use GroceryPlanner.DataCase, async: true

  alias GroceryPlanner.Accounts.User

  describe "theme validation" do
    test "accepts all valid daisyUI themes" do
      valid_themes = ~w[
        light dark cupcake bumblebee synthwave retro
        cyberpunk dracula nord sunset business luxury
      ]

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

      # Test with old "progressive" theme (should be invalid now)
      assert {:error, error} = User.update(user, %{theme: "progressive"}, actor: user)
      assert error.errors |> Enum.any?(fn e -> e.field == :theme end)

      # Test with random invalid theme
      assert {:error, error} = User.update(user, %{theme: "invalid_theme"}, actor: user)
      assert error.errors |> Enum.any?(fn e -> e.field == :theme end)
    end

    test "defaults to light theme for new users" do
      {:ok, user} =
        User.create(
          "newuser@example.com",
          "New User",
          "password123password123"
        )

      assert user.theme == "light"
    end

    test "allows updating theme after user creation" do
      {:ok, user} =
        User.create(
          "themed@example.com",
          "Themed User",
          "password123password123"
        )

      assert user.theme == "light"

      {:ok, updated} = User.update(user, %{theme: "cyberpunk"}, actor: user)
      assert updated.theme == "cyberpunk"
    end
  end
end
