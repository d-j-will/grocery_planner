# Domain Context — Grocery Planner

The ubiquitous language for the household grocery-planning domain. Add or sharpen
terms here as they're coined; keep names consistent with the Ash resources and
code interfaces.

## Recipes

### Recipe browsing
A filtered, sorted, and paginated view over the household's **own** recipe
library — narrowing by name search, difficulty, prep-time bucket, cuisine,
dietary needs, favorites, and recipe chains. Implemented as
`Recipes.browse_recipes/2` (the `:browse` read action), which runs entirely in
Postgres via the `Recipes.Preparations.BrowseRecipes` preparation. All arguments
are optional — a nil/blank value is a no-op — so one action serves every caller.

Distinct from two other same-shaped operations that must not be conflated:
- **Semantic search** — `Embeddings.search_recipes/2`, vector similarity over embeddings.
- **External search** — `External.search_recipes/1`, importing recipes from external sources.

### Recipe chain
A base recipe (`is_base_recipe`) and its follow-up recipes (`is_follow_up`,
linked via `parent_recipe`) — e.g. a roast and the soup made from its leftovers.
