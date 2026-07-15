# Issue tracker: beads (`bd`)

Issues and PRDs for this repo live in **beads**, a local Dolt database synced via
`refs/dolt/data` on the git remote. Use the `bd` CLI for all operations.

**GitHub Issues are not used and are not a source of truth.** Don't create, read, or
sync them. Likewise don't use TodoWrite/TaskCreate or markdown TODO lists — `bd` is the
only tracker. Run `bd prime` for the full command reference and session protocol.

## Conventions

- **Create an issue**: `bd create --title="..." --description="..." --type=task|bug|feature --priority=2`
  - Priority is `0`-`4` (or `P0`-`P4`), where 0 is critical — **not** "high"/"medium"/"low".
  - Add labels with `-l/--labels` (comma-separated).
  - `--acceptance="..."`, `--design="..."`, `--notes="..."` populate the structured fields; `--validate` checks required sections.
- **Read an issue**: `bd show <id>` — includes dependencies, labels, and blocking relationships.
- **List issues**: `bd list --status=open`. Filter labels with `--label` (AND), `--label-any` (OR), `--exclude-label`.
- **Find work**: `bd ready` shows issues with no active blockers. `bd blocked` shows what's stuck.
- **Claim / assign**: `bd update <id> --claim` or `bd update <id> --assignee=<name>`.
- **Edit fields**: `bd update <id> --title/--description/--notes/--design`. Labels: `--add-label`, `--remove-label`, `--set-labels`.
- **Close**: `bd close <id> --reason="..."`. Close several at once: `bd close <id1> <id2> ...`.
- **Search**: `bd search <query>`.
- **Dependencies**: `bd dep add <issue> <depends-on>`.

**Never run `bd edit`** — it opens `$EDITOR` and will block a non-interactive agent.

Issue IDs are prefixed per repo (e.g. `grocery_planner-t7j`); `bd` infers the workspace
from the clone.

## Sync

Beads auto-commits to Dolt; `git push` carries it. `bd dolt push` / `bd dolt pull` sync
explicitly. A fresh clone must hydrate before it can see the team's issues — see the
org-brain card `beads-fresh-clone-hydrate-before-sharing-dolt`.

## When a skill says "publish to the issue tracker"

Run `bd create`.

## When a skill says "fetch the relevant ticket"

Run `bd show <id>`.
