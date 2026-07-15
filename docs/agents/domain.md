# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root, or
- **`CONTEXT-MAP.md`** at the repo root if it exists — it points at one `CONTEXT.md` per context. Read each one relevant to the topic.
- **org-brain** — search the canon (`search_cards`) for decisions and heuristics touching the area you're about to work in. **Architectural decisions live in org-brain, not in this repo.** There is no `docs/adr/`.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The producer skill (`/grill-with-docs`) creates them lazily when terms actually get resolved.

## Where decisions live

Decisions are org-brain cards, not files. An in-repo ADR has no owner and no lifecycle: nothing checks it, nothing can mark it wrong, and it drifts from the code while still reading as authoritative. This repo carried four such ADRs for six months; two had become false statements about the system, and one described a code path that returned mock data in production.

Cards can be revised, flagged stale, and superseded, and they're visible to every repo that hits the same fork. Record decisions with `draft_card` (kind: `decision`), then promote.

In-repo docs remain right for things versioned with the code and true by construction — `CONTEXT.md` vocabulary, READMEs, runbooks. The test: **can this document silently become false while CI stays green?** If yes, it belongs in a card.

## File structure

Single-context repo (most repos):

```
/
├── CONTEXT.md
└── src/
```

Multi-context repo (presence of `CONTEXT-MAP.md` at the root):

```
/
├── CONTEXT-MAP.md
└── src/
    ├── ordering/
    │   └── CONTEXT.md
    └── billing/
        └── CONTEXT.md
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/grill-with-docs`).

## Flag decision conflicts

If your output contradicts an org-brain card, surface it explicitly rather than silently overriding:

> _Contradicts `single-instance-ship-ready-defer-liveness` — but worth reopening because…_

If a card turns out to be wrong rather than merely inconvenient, `flag_stale` it. Don't work around it silently — an unflagged wrong card will mislead the next reader exactly as a stale ADR would.
