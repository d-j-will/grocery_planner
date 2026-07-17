defmodule GroceryPlanner.Repo.Migrations.UpdateObanToV14 do
  use Ecto.Migration

  # oban 2.23 (pulled in by the ash_oban 0.8 bump during the EEF/OSV CVE
  # remediation, grocery_planner-yg5) requires Oban schema v14. The initial
  # install (add_embeddings_and_oban_support) provisioned v12; this applies the
  # incremental v12 -> v14 delta.
  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 12)
end
