# Architecture Review — Status

_Review: [`architecture-review-2026-07-14.html`](architecture-review-2026-07-14.html) (2026-07-14, read-only, six deepening candidates)_
_Status verified against code: 2026-07-15_

**Read this before the HTML.** Two of the review's six candidates have been overtaken
by events, and in both cases the shipped code is *right* and the review is *wrong*.
Following the HTML as written would make the codebase worse in two places.

Also stale: the HTML footer says "no CONTEXT.md or ADRs present in repo". `CONTEXT.md`
now exists. `docs/adr/` does **not** exist, despite CLAUDE.md and `docs/agents/domain.md`
both pointing there — the ADRs lived in `specs/architecture.md` and were removed
2026-07-15 as stale (ADR 1 and ADR 3 were false statements about the system; see git
history for the originals).

## Summary

| # | Candidate | Status |
|---|-----------|--------|
| 1 | Deepen the AI seam | Premise dissolved — residual needs re-scoping |
| 2 | `Recipes.search_recipes/2` | Essentially done (shipped as `browse_recipes/2`) |
| 3 | `MealPlanning.Scheduler` | Bug fixed; consolidation not done |
| 4 | `RecipeChain` / `NotLoaded` leak | Untouched — latent bug still live |
| 5 | `Shopping` transfer interface | Untouched |
| 6 | AI degradation policy | Untouched |

## 1 · AI seam — the review's fix no longer exists

The review said: a complete anti-corruption layer sits dead in `contracts.ex`, wire it up.

`afb24d7` did the opposite and **deleted** `contracts.ex` and `ai/schema.ex`, for a
reason the review missed: `Contracts.atomize/1` ran `String.to_existing_atom` over
every server-supplied key. Wiring it up would have *introduced* a crash vector. The
never-raise normalizers that commit added landed on the categorizer path instead.

**Residual (narrower than the review's):** the extraction path still hand-parses raw
sidecar JSON. `AiClient.extract_receipt` returns a raw map (`handle_response`,
`ai_client.ex:186`, passes `body` straight through) and `receipt_processor.ex:280-304`
matches dual shapes — `%{"merchant" => %{"name" => n}}` or `%{"merchant" => n}`, same
for `total`. Fixing this means a *fresh* extraction-path normalizer. Do not resurrect
the ACL.

**Not tracked in beads.**

## 2 · `browse_recipes/2` — done; the review over-reached

Shipped: `:browse` read action (`recipe.ex:283`) + `Preparations.BrowseRecipes`,
offset pagination, all-optional args. The `try/rescue` rule violation the review
flagged at `recipes_live.ex:53` is gone. Migrated: `recipes_live.ex:220`,
`recipe_show_live.ex:223`. Covered by `test/grocery_planner/recipes/recipe_browse_test.exs`.

**The review's "collapse 7 call sites into 1" is wrong for 5 of them.** The
meal-planner layouts (explorer/power/focus), `family_live`, and `recipe_picker`
filter a cached, association-loaded list per keystroke *deliberately* — see the
`Recipes.name_matches?/2` moduledoc. Pushing those to the DB means a round-trip per
keystroke. **Do not "finish" this by migrating them.**

**Residual:** two implementations of "does this name match" with divergent semantics —
`apply_search` uses DB `ilike(name, "%term%")` (so `%`/`_` are wildcards),
`name_matches?` uses `String.contains?` (literal). Searching `50%` behaves differently
in each. Either escape `%`/`_` in `apply_search` or document the difference. Low
severity.

Verified not a problem: `recipes_live.ex:95-101` maps form strings to atoms via an
explicit whitelist `case` before they reach the action, so the preparation's
atom-matching clauses can't silently no-op on uncast strings.

Do not second-guess: the `id: :asc` sort tiebreaker (correct for offset pagination
over non-unique keys, and tested), and the typed-fragment workaround for AshMoney
operator overloads mis-resolving numeric comparisons to `money_with_currency`.

## 3 · `MealPlanning.Scheduler` — half

The divergence the review flagged (copy didn't skip occupied slots, repeat did) was
fixed under `grocery_planner-vzc`: one meal per slot enforced, replace/skip on
occupied, `copy_last_week` skip test.

**Residual:** no `Scheduler` module. Four variants still live in the LiveViews —
`meal_planner_live.ex:789` (`copy_last_week`), `:856` (`auto_fill_week`),
`focus_layout.ex:913` (`repeat_last_week`), `:958` (`auto_fill_day`). The review's
`copy_range(on_conflict:)` + `fill_empty_slots(strategy:)` shape still stands.

**Not tracked in beads.**

## 4 · `RecipeChain` / `NotLoaded` leak — untouched

Latent bug still live: `is_map(recipe.parent_recipe)` at `meal_planner_live.ex:1619`.
`is_map(%Ash.NotLoaded{})` is `true`, so the guard doesn't guard. Four
`chain_follow_up_candidates` clauses at `:1581-1631`.

Adjacent beads issue: `yst` (LiveView hard-matches on client events).

## 5 · `Shopping` transfer — untouched

`handle_event("transfer_to_inventory")` at `shopping_live.ex:322` still owns the
cross-domain write, including the `authorize?: false` call at `:350`. No
`transfer_checked_items_to_inventory/3`, no `get_list_with_progress/2`.

Partly covered by beads `3ko` (push filtering/pagination into Ash queries).

## 6 · AI degradation policy — untouched

No `AiClient.available?/0`, no `:awaiting_ai` state. `enabled?()` gating exists only
in `categorizer.ex` and `embeddings.ex`, so extraction still hard-fails and burns Oban
attempts rather than degrading.

Covered by beads `c29` (treat optional AI sidecar as degraded, not fatal).

## Note for the next review

Twice here the review was confidently wrong in the same way: it read the code
statically and applied a sound principle ("one home for the rule", "wire up the ACL")
without weighing a constraint it couldn't see — per-keystroke latency, and
`to_existing_atom` crash vectors on untrusted input. The document reads as
authoritative because it is specific and well-presented. Specificity is not
correctness. Verify each candidate against the code before acting on it.
