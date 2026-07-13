# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Commands

### Development Setup
- `mix setup` - Install dependencies, setup database, build assets, and run seeds
- `mix phx.server` - Start Phoenix server at http://localhost:4000
- `iex -S mix phx.server` - Start Phoenix server with IEx interactive shell

### Testing and Quality
- `mix test` - Run all tests (automatically runs `ash.setup --quiet` first)
- `mix test test/path/to/test.exs` - Run a specific test file
- `mix test --failed` - Run only previously failed tests
- `mix precommit` - Full pre-commit check: compile with warnings as errors, clean unused deps, format code, and run tests

### Git Workflow (MANDATORY)
After every `git push`, you MUST:
1. Wait for CI to start: `sleep 10`
2. Watch CI until completion: `gh run watch --exit-status`
3. If CI fails:
   - View failed logs: `gh run view --log-failed`
   - Fix the issues
   - Run `mix precommit` locally to verify
   - Commit and push the fix
   - Repeat until CI passes
4. Do NOT consider a task complete until CI passes

### Database Management
- `mix ash.setup` - Create database, run migrations (uses Ash's database setup)
- `mix ash.reset` - Drop and recreate database
- `mix ash.migrate` - Run pending migrations
- `mix ash.rollback` - Rollback the last migration

### Asset Management
- `mix assets.setup` - Install Tailwind and esbuild if missing
- `mix assets.build` - Compile and build all assets (Tailwind + esbuild)
- `mix assets.deploy` - Build minified assets for production

## Architecture Overview

### Ash Framework
This application uses the **Ash Framework** (v3.0) as its core data layer and business logic engine. Ash provides declarative resource definitions with built-in validation, authorization, code interfaces, and database operations.

**Key Concepts:**
- **Resources**: Define data structures, actions, validations, and policies (e.g., `GroceryPlanner.Accounts.User`)
- **Domains**: Group related resources together (e.g., `GroceryPlanner.Accounts`, `GroceryPlanner.Inventory`)
- **Actions**: Declarative CRUD operations with custom logic via changes and validations
- **Policies**: Authorization rules defined directly in resources
- **Code Interfaces**: Automatically generated functions for interacting with resources

**Database Layer**: Uses `AshPostgres` data layer with PostgreSQL 18+ required. The repo is `GroceryPlanner.Repo` which extends `AshPostgres.Repo`.

### Domain Organization

**Accounts Domain** (`GroceryPlanner.Accounts`)
- Multi-tenancy support via Account/User/AccountMembership pattern
- Resources: `User`, `Account`, `AccountMembership`
- User authentication with bcrypt password hashing
- Email confirmation workflow

**Inventory Domain** (`GroceryPlanner.Inventory`)
- Resources: `Category`, `StorageLocation`, `GroceryItem`, `InventoryEntry`
- Supports tracking grocery items across storage locations with quantities and expiration

### Web Layer (Phoenix LiveView)

**Authentication**
- Custom authentication plug: `GroceryPlannerWeb.Auth`
- Pipelines: `:browser`, `:require_authenticated_user`
- Public routes: sign-up, sign-in
- Protected routes: dashboard, settings, inventory

**LiveViews**
- `Auth.SignUpLive` / `Auth.SignInLive` - User registration and login
- `DashboardLive` - Main authenticated dashboard
- `SettingsLive` - User settings
- `InventoryLive` - Inventory management

**Component Architecture**
- Core components in `GroceryPlannerWeb.CoreComponents`
- Layouts in `GroceryPlannerWeb.Layouts` module
- Hero icons via `<.icon>` component

### Working with Ash Resources

**Creating Resources:**
```elixir
use Ash.Resource,
  domain: GroceryPlanner.DomainName,
  data_layer: AshPostgres.DataLayer,
  authorizers: [Ash.Policy.Authorizer]

postgres do
  table "table_name"
  repo GroceryPlanner.Repo
end
```

**Defining Actions:**
- Use `defaults [:read, :update, :destroy]` for standard CRUD
- Custom actions require explicit definition
- Use `code_interface` to generate helper functions

**Querying Resources:**
```elixir
# Via code interface
GroceryPlanner.Accounts.User.by_email!("user@example.com")

# Via Ash.Query
User
|> Ash.Query.filter(email == "user@example.com")
|> Ash.read_one!()
```

**Changes and Validations:**
- Use `change` callbacks in actions to modify data
- Define custom validations in the `validations` section
- Leverage built-in Ash validations

### Configuration Notes

**Ash Configuration** (`config/config.exs`)
- Domains registered: `GroceryPlanner.Accounts`, `GroceryPlanner.Inventory`
- Custom type support for `AshMoney.Types.Money`
- Formatter settings for Ash resources in `.formatter.exs`

**Extensions Installed:**
- PostgreSQL extensions: `ash-functions`, `citext`, `AshMoney.AshPostgresExtension`
- Requires PostgreSQL 18.0+

**Phoenix Configuration:**
- Uses Bandit adapter (not Cowboy)
- Tailwind CSS v4 (no tailwind.config.js needed)
- esbuild for JavaScript bundling

### Important Development Patterns

**Multi-Tenancy (CRITICAL - read carefully):**
- Account-based multi-tenancy is implemented via `multitenancy strategy: :attribute, attribute: :account_id`
- Users belong to multiple Accounts via AccountMembership
- All domain resources are scoped to Accounts

**Tenant context rules - these cause SILENT FAILURES if wrong:**
1. **NEVER use `actor: nil`** for system-level operations (Oban workers, PubSub handlers, background tasks). Use `authorize?: false` instead. `actor: nil` triggers policy authorization with a nil actor, which silently returns empty results for `relates_to_actor_via` policies instead of raising errors.
2. **AshOban triggers on multi-tenant resources MUST set `use_tenant_from_record?(true)`** in the trigger config. Without this, the worker reads the record globally but then fails to update it because no tenant context is set. The worker_read action needs `multitenancy :allow_global`, AND the trigger needs `use_tenant_from_record?(true)` so the update action gets the tenant from the record's `account_id`.
3. **`multitenancy :allow_global` is only valid on read actions**, not on create/update/destroy. For non-read actions in background workers, tenant must be set via `use_tenant_from_record?` (AshOban) or `Ash.Changeset.set_tenant/2`.
4. **LiveView `handle_info` callbacks** that query Ash resources need `authorize?: false` since there's no actor in the socket's handle_info context.

**AshOban trigger checklist for multi-tenant resources:**
```elixir
trigger :my_trigger do
  queue(:my_queue)
  action :my_action
  read_action :scheduler_read       # needs: multitenancy :allow_global
  worker_read_action(:worker_read)  # needs: multitenancy :allow_global
  use_tenant_from_record?(true)     # REQUIRED for update/create actions
  on_error(:on_error_action)
end
```

**Authentication Flow:**
- Password hashing with bcrypt happens in User resource action changes
- Sensitive attributes (`:hashed_password`) marked with `sensitive?: true`
- Email confirmation via `:confirm` action

**Asset Pipeline:**
- CSS in `assets/css/app.css` with Tailwind v4 import syntax
- JavaScript in `assets/js/app.js`
- No inline scripts in templates - use JS hooks instead

**Theming (Skillet design system):**
- 4 custom daisyUI themes defined in `assets/css/app.css` via the `daisyui-theme` plugin: fairway (default, forest green · cream · terracotta), orchard, marble, dark (`prefersdark`)
- Design source of truth: the "Grocery Planner" design-system project on claude.ai/design, mirrored in `design/` (see `design/README.md` for the round-trip workflow)
- Skillet extension tokens available in every theme: `--color-ink-soft`, `--color-ink-muted`, `--color-line`, `--color-accent-soft`, `--color-tag`
- Type system: Inter (UI, `--font-ui`) + Instrument Serif (display, `.font-display` — page titles 5xl, section titles 3xl, card headings 2xl); self-hosted woff2 in `priv/static/fonts`
- Helper classes: `.font-display`, `.sk-tag` (chips), `.sk-card` (hairline cards)
- Theme selection in user settings (Settings page), persisted per user (`users.theme` column), applied via `data-theme` attribute on the HTML element
- Validated on User resource to only accept valid theme names

For detailed Phoenix and LiveView guidelines, see the comprehensive rules in AGENTS.md.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
