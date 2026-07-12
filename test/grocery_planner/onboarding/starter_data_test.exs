defmodule GroceryPlanner.Onboarding.StarterDataTest do
  # async: false — the cwd-independence test changes the VM-global working
  # directory, which would race with concurrently running tests.
  use ExUnit.Case, async: false

  alias GroceryPlanner.Onboarding.StarterData

  describe "recipe catalog loading" do
    test "loads the catalog via the app dir, independent of cwd" do
      # In a release the process cwd is not the project root and priv/ lives
      # under the app's lib dir, so a cwd-relative "priv/..." read crashes
      # onboarding. Simulate that by leaving the project root entirely.
      {:ok, original_cwd} = File.cwd()

      try do
        File.cd!(System.tmp_dir!())

        recipes = StarterData.recipes(:omnivore)

        assert recipes != []
        assert Enum.all?(recipes, &is_binary(&1.name))
      after
        File.cd!(original_cwd)
      end
    end

    test "every kit resolves to a non-empty recipe list" do
      for kit <- StarterData.kits() do
        assert StarterData.recipes(kit) != [], "kit #{kit} produced no recipes"
      end
    end
  end
end
