# Research: production Postgres image (pgvector pg16 vs the "PostgreSQL 18+" claim)

**Ticket:** grocery_planner-tdu.1
**Date:** 2026-07-13
**Question:** Dev docker-compose runs `pgvector/pgvector:pg16`, but CLAUDE.md claims PostgreSQL 18+ is required. Which is true, and what image should `docker-compose.prod.yml` use on the Debian x86 homelab Docker host?

## Recommendation

**Use `pgvector/pgvector:pg18` (multi-arch, includes linux/amd64) in `docker-compose.prod.yml`.**

- The "PG18+ required" claim is **not a real requirement** — it is installer drift (see below). The app verifiably runs on PG16 (CI runs the full suite on it).
- But since this is a **fresh database with no upgrade path to worry about**, and the repo already *declares* `min_pg_version` 18, the newest stable PG that pgvector images support is the right pick. PG18 is stable GA (details in "External facts" below).
- Fallback if pg18 shows any problem on the homelab host: `pgvector/pgvector:pg17`, and as a last resort `pg16` (the CI-proven floor). If falling back below 18, nothing needs to change in the app — `min_pg_version` 18 only enables `any_value` aggregation, a PG16+ feature (evidence below), so PG16/17 both work with the code as-is.

Pin by digest per the homelab convention (containerised tooling pinned by SHA256): resolve the digest at deploy time with `docker pull pgvector/pgvector:pg18 && docker inspect --format='{{index .RepoDigests 0}}' pgvector/pgvector:pg18`.

## 1. What the app actually requires from Postgres

### Extensions (all four are real, none needs PG18)

`lib/grocery_planner/repo.ex` declares:

```elixir
def installed_extensions do
  ["ash-functions", "citext", "vector", AshMoney.AshPostgresExtension]
end
```

- **ash-functions** — plain PL/pgSQL functions created by migration `priv/repo/migrations/20251113195849_initialize_and_install_ash_money_extensions_1.exs` (`ash_functions_version: 5` in `priv/resource_snapshots/repo/extensions.json`). Includes a `uuid_generate_v7()` **polyfill** — the migration ships its own implementation rather than relying on PG18's native `uuidv7()`, so no PG18 dependency.
- **citext** — bundled contrib extension, available in every supported PG version (`priv/repo/migrations/20251113205710_enable_citext.exs`).
- **vector (pgvector)** — genuinely used at runtime, not vestigial:
  - `priv/repo/migrations/20260202174114_add_embeddings_and_oban_support.exs` adds `recipes.embedding vector(384)` plus an HNSW cosine index.
  - `lib/grocery_planner/ai/embeddings.ex` writes `Pgvector.new(...)` values and runs cosine-distance similarity SQL.
  - `lib/grocery_planner/workers/embedding_worker.ex` / `embedding_backfill_worker.ex` populate embeddings; `lib/grocery_planner_web/live/meal_planner_live.ex` consumes semantic search.
  - **The prod image must therefore ship pgvector** — a plain `postgres:*` image will not work.
- **AshMoney.AshPostgresExtension** — `money_with_currency` composite type + PL/pgSQL operator functions, created by the same 20251113195849 migration. Plain SQL, no version-specific features.

### The only `min_pg_version`-gated SQL is a PG16 feature

In ash_postgres 2.6.25 (the locked version — `mix.lock`), the *sole* runtime consumer of `min_pg_version` is `deps/ash_postgres/lib/sql_implementation.ex:265`:

```elixir
def list_aggregate(resource) do
  if AshPostgres.DataLayer.Info.pg_version_matches?(resource, ">= 16.0.0") do
    "any_value"
  else
    "array_agg"
  end
end
```

`any_value()` is a PostgreSQL **16** feature. Declaring `min_pg_version` = 18 therefore commits the app to a **PG16+ floor**, nothing higher. There is no PG17- or PG18-only SQL anywhere in generated migrations or resource snapshots (checked `priv/repo/migrations/` and `priv/resource_snapshots/`; UUID v7 uses the polyfill above; all PK defaults use `gen_random_uuid()`, PG13+).

AshPostgres itself documents official support for **PostgreSQL 14+** (`deps/ash_postgres/documentation/topics/development/upgrading-to-2.0.md`).

### Proof the app runs on PG16

`.github/workflows/ci.yml` runs the **entire test suite against `pgvector/pgvector:pg16`** (service image at lines 21 and 113) and passes. Note ash_postgres does not verify the declared `min_pg_version` against the actual server at startup — it is a promise used for SQL generation, not an enforced check — which is why the mismatch never surfaced.

## 2. Where the "PostgreSQL 18.0+" claim comes from

`CLAUDE.md:53` ("PostgreSQL 18+ required") and `CLAUDE.md:131` ("Requires PostgreSQL 18.0+") are **documentation drift from the installer**, not a real requirement:

- `lib/grocery_planner/repo.ex` has `min_pg_version` returning `%Version{major: 18, minor: 0, patch: 0}` — present since the initial commit (`git log -S "min_pg_version"` → `32fe6e3 Initial commit`).
- The `mix ash_postgres.install` igniter task **auto-detects this value by running `postgres -V` on the developer's machine** (`deps/ash_postgres/lib/mix/tasks/ash_postgres.install.ex`, `min_pg_version_and_notice/1`: "This was based on running `postgres -V`."). The dev Mac evidently had a local PostgreSQL 18 when the project was generated; the installer wrote 18.0.0, and CLAUDE.md echoed it as a hard requirement.
- The installer's own notice says to set it to *"the lowest version that your application [will run on]"* — i.e. it should describe the deployment floor, not the dev machine.

**Verdict: the PG18+ claim is aspirational drift.** The verifiable floor for the current codebase is PG16 (CI-proven; also the `any_value` gate). CLAUDE.md should be corrected as follow-up.

## 3. External facts (Docker Hub / postgresql.org / pgvector upstream)

*(Researched against primary sources on 2026-07-13; see per-claim sources.)*

<!-- WEB-FINDINGS -->

## 4. Consequences for docker-compose.prod.yml (feeds ticket grocery_planner-tdu.4)

```yaml
  postgres:
    image: pgvector/pgvector:pg18   # pin by digest at deploy time
```

- Fresh database → no `pg_upgrade`/dump-restore concern; just start on 18.
- Keeping `min_pg_version` at 18 in `repo.ex` is then *accurate* for prod. Dev/CI on pg16 remain compatible because the only gated feature (`any_value`) needs only PG16.
- Optional hygiene follow-ups (not required for the prod compose work):
  1. Bump dev `docker-compose.yml` and CI from `pg16` to `pg18` so all environments match the declared `min_pg_version`.
  2. Fix CLAUDE.md wording: PG18 is the *chosen prod version*, not a framework requirement; the app's actual floor is PG16 (ash_postgres supports 14+, this codebase's generated SQL needs 16+ only because of `any_value`).

## Evidence index

| Claim | Source |
|---|---|
| Dev uses pgvector pg16 | `docker-compose.yml` (`pgvector/pgvector:pg16`) |
| CI proves app works on PG16 | `.github/workflows/ci.yml:21,113` |
| PG18+ claim location | `CLAUDE.md:53,131` |
| min_pg_version = 18 | `lib/grocery_planner/repo.ex` |
| min_pg_version auto-detected via `postgres -V` | `deps/ash_postgres/lib/mix/tasks/ash_postgres.install.ex` |
| Only version-gated SQL is `any_value` (PG16+) | `deps/ash_postgres/lib/sql_implementation.ex:265` |
| AshPostgres supports PG 14+ | `deps/ash_postgres/documentation/topics/development/upgrading-to-2.0.md` |
| pgvector used at runtime | `priv/repo/migrations/20260202174114_add_embeddings_and_oban_support.exs`, `lib/grocery_planner/ai/embeddings.ex`, `lib/grocery_planner/workers/embedding_worker.ex` |
| uuid v7 polyfill (no native uuidv7 dependency) | `priv/repo/migrations/20251113195849_initialize_and_install_ash_money_extensions_1.exs:104` |
| Extensions installed | `lib/grocery_planner/repo.ex`, `priv/resource_snapshots/repo/extensions.json` |
