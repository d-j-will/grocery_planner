defmodule GroceryPlanner.Repo.Migrations.RecipeEmbeddingVectorize do
  @moduledoc """
  Snapshot reconciliation for the recipe embedding vectorize fix (grocery_planner-z7h).

  `full_text_vector` was ash_ai's DEFAULT vector attribute name. It was recorded
  in the recipes resource snapshot but NEVER migrated into the database — the
  hand-written add_embeddings migration created an `embedding vector(384)` column
  instead, and the raw-SQL workaround workers wrote to it directly. The vectorize
  block now targets `:embedding` explicitly, so the phantom `full_text_vector`
  drops out of the snapshot.

  Because the column exists in no real database, this uses IF EXISTS / IF NOT
  EXISTS so it is a safe no-op everywhere rather than the destructive `remove`
  ash_postgres generated (which would fail: cannot drop a column that isn't there).
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE recipes DROP COLUMN IF EXISTS full_text_vector"
  end

  def down do
    execute "ALTER TABLE recipes ADD COLUMN IF NOT EXISTS full_text_vector vector(384)"
  end
end
