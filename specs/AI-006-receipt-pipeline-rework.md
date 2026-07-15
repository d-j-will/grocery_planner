# AI-006: Receipt Pipeline Rework — staged workers, honest contract

**Status:** design in progress — §1–4 settled, §5 firm, §6–7 captured
**Date:** 2026-07-16
**Supersedes the pipeline built in:** AI-003 (`4a51ab8`)
**Related cards:** `reactor-is-not-durable-oban-owns-durability-defer-sagas-until-a-step-has-a-committed-side-effect`, `architectural-decisions-live-in-org-brain-not-in-repo-adr-files`

## Why this exists

The receipt pipeline has three live bugs (`cxk`): premature `completed` status,
duplicate items on retry, and receipts stranded in `processing` on failure. All three
have the same cause — `ReceiptProcessor.save_extraction_results/2` does the whole
pipeline in one `after_action` with no durable state machine. It sets
`status: :completed` **before** creating items, creates them with an unkeyed
`Enum.each`, and fires `Task.start` for categorisation (unsupervised, lost on crash).

Underneath that sits a contract mismatch that makes the pipeline lie about its own
data. See §5.

**This is not a throughput problem.** At 1000 users × ~5 receipts/week ≈ 5k jobs/week,
Oban is not breathing hard. It is a correctness and visibility problem, and the design
should be judged on that.

## Evidence base

Findings verified against the code on 2026-07-15/16. Recorded because several are
counter-intuitive and will otherwise be re-litigated:

- **Three receipt-extraction paths exist in the sidecar; each has exactly one fatal flaw.**
  `/api/v1/extract-receipt` (flat, base64) does real Tesseract OCR but drops data.
  `/api/v1/receipts/extract` (rich, nested) returns everything but takes `image_path` —
  and `ai-service` does not mount `receipt-uploads`, so it cannot work in prod.
  `/api/v1/jobs` (async, ADR-2's design) has the right transport but its handler
  branches on `USE_VLLM_OCR` → else **mock**, and prod runs Tesseract — it would return
  "Mock Supermarket" for every receipt.
- **AI-003 built the rich endpoint, its schemas, the Elixir parser (+242) and its tests
  (+560) — and never touched `ai_client.ex`.** The feature was built at both ends and
  the wire was never connected. `7b0585a` then bolted Tesseract onto the *old* scaffold
  endpoint rather than repointing the client, and flattens `ExtractionResult` on the way
  out, discarding `raw_ocr_text`, `overall_confidence` and `MoneyInfo.currency`.
- **Consequence:** on the wired path `raw_ocr_text`, `extraction_confidence`,
  `model_version` and `processing_time_ms` are **always nil** — all four have columns on
  Receipt (`receipt.ex:164-184`). `parse_flat_money` hardcodes `:USD` because the flat
  contract carries no currency. That is `83o`'s root cause; it cannot be fixed in Elixir.
- **The fixtures test the endpoint the app doesn't call.** `receipt_processor_test.exs`
  uses `"extraction"` envelopes, nested `merchant.name`, `total.amount`+`currency`,
  `raw_ocr_text`, `line_items` — every one a shape prod never emits. Line 252 asserts
  `raw_ocr_text` equals a value production always leaves nil.
- **The sidecar's SQLite holds nothing load-bearing.** `ai_jobs` is written only by the
  orphaned async path; `ai_feedback` is dead (feedback lives in Postgres,
  `ai_categorization_feedback`, from `item_handlers.ex:296`); `ai_artifacts` is
  write-only — no Elixir client function, and ADR 4 gives the service no ingress, so it
  is readable only via `docker exec`. `_executor = ThreadPoolExecutor(max_workers=4)`
  is declared and never referenced.
- **ADR 3's 30-day prune was never implemented**, and `create_artifact` stores
  `input_payload` — which for extract-receipt is `{"image_base64": ...}` — into
  `Column(Text)`. Every scan writes the full receipt image to SQLite, forever.

The recurring shape: **built completely, never wired, then worked around.** Five
instances. The design below is judged partly on whether it adds a sixth.

## Arcs

This ships as **separate arcs**, not one change. Each is independently reviewable,
revertable, and valuable on its own. One big-bang change to a P1 path is the shape that
produced the five abandoned paths above.

| Arc | Contains | Depends on | Ships alone? |
|---|---|---|---|
| **1 — Honest seam** | §4a (classify errors), §5 (contract fix), fixtures | — | Yes. Unblocks `83o` on its own. |
| **2 — Staged pipeline** | §1, §2, §3, §4b–d | Arc 1 | Fixes `cxk`, `c29`, `eeg` |
| **3 — Observability** | §7 (`t7j`, Oban Web, Oban telemetry) | — (`t7j` is standalone) | Yes |
| **4 — Sidecar collapse** | §6 (delete the dead paths) | Arcs 1 + 2 | Yes, once they land |

**Arc 1 goes first.** §1–3 are designed *around* the payload, and we already know the
payload lies — restaging on it would mean rebuilding `extract` twice. Arc 1 is also the
smallest and the only one that delivers value (`83o`, currency) without touching the
pipeline.

**Arc 3 can go first or in parallel** — `t7j` has no dependency on any of this, and
landing it early means the rework is measurable rather than asserted. Worth doing if
before/after evidence matters.

**Arc 4 is subtraction only** and must go last: §6 retires `ai_artifacts`, which only
becomes redundant once §2's `raw_extraction` exists.

## 1. Pipeline shape — SETTLED

```
upload ──▶ [extract] ──▶ [persist] ──▶ [match] ──▶ [categorise] ──▶ review
             │             │             │             │
          own job       own job       own job       own job
          ai_jobs       default       matching      ai_jobs (optional)
```

Each stage is its own Oban job, enqueued directly by the previous stage.

- **Staged, not one job.** Extraction is a ~60s CPU-bound OCR call against a 2-CPU
  sidecar. Staging persists it once so a later failure in `match` never re-pays for it.
- **`match` gets its own queue.** It is `eeg` — ~30 full-catalog scans per receipt,
  currently synchronous in `handle_info`. CPU-bound on *our* side, so it wants a
  different limit from `ai_jobs`.
- **Concurrency.** `ai_jobs: 5` today against a sidecar capped at `cpus: "2"`. Single
  node means a per-queue `limit` **is** a global cap (`local_limit`/`global_limit` do not
  exist in free Oban). Config fix, free.
- **PubSub stays as-is** (`receipt:<id>`), with one rule made explicit: **it is a UI
  hint, never load-bearing.** Each stage writes durable state, *then* broadcasts. Lose
  the message and `receipt.status` is still true; the LiveView catches up on reconnect.
- **No message broker.** RabbitMQ/Broadway was evaluated and rejected: there is no
  stream, Oban already provides durability on a datastore we already operate and back
  up, and a broker would add a failure domain and a third queue to a system whose
  defining problem is having two of everything.
- **No Oban Pro.** Not needed: unique jobs are free (the pricing page misleadingly lists
  them under Pro), Oban Web has been free/Apache-2.0 since 2025-01-16, and a single-node
  queue limit gives the backpressure. Revisit only for multi-node or true rate limiting.
- **Reactor deferred.** No stage has a committed effect a DB rollback cannot undo, so a
  saga has nothing to compensate. Atomicity and post-commit notifications are properties
  of a transaction, not of Reactor. See the card for the trigger to revisit.

## 2. State model — SETTLED

**`receipt.status` records the furthest durable milestone, never in-flight activity.**

```
:pending → :extracted → :items_created → :ready_for_review → :confirmed
```

Today's `:processing` is the bug in miniature: it means "something started and we don't
know what", which is exactly why stuck is indistinguishable from working.

These states deliberately do **not** mirror "extracting…"/"matching…". Oban already
knows what is executing; duplicating that into the receipt would be a second source of
truth — the failure this whole spec exists to remove.

> **OPEN — milestone vs condition.** `:failed` and `:awaiting_ai` are **not milestones**
> — they're conditions orthogonal to progress. A receipt "awaiting AI" has still only
> reached `:pending`; one that failed did so *at* some milestone. Cramming both meanings
> into one enum is exactly what `:processing` does wrong, and it would reproduce the bug
> in a new coat. Options: (a) `status` = milestone + a separate `condition`
> (`:ok | :awaiting_ai | :failed`) with `failure_reason`; (b) keep one enum and accept
> that failure loses the progress information. Leaning (a). Settle before implementing.

> **OPEN — where `categorise` fits.** It is *degradable* (the sidecar may be off), so
> `:ready_for_review` must **not** depend on it. Proposal: `match` sets
> `:ready_for_review` and enqueues `categorise`, which enriches items in place and
> broadcasts; its failure never blocks the user. That removes a separate `:matched`
> milestone — which in turn changes the reconciler's `where`. Confirm before building.

**Inter-stage handoff:** add **`receipt.raw_extraction` (jsonb)**. `extract` writes it
plus the milestone; `persist` reads it. Oban `args` carry only `receipt_id` — a large
JSON blob defaulting into `oban_jobs.args` is how base64 ended up in SQLite. This column
also **replaces `ai_artifacts` outright**: tenant-scoped, backed up, joinable to the
receipt, prunable with it, readable without `docker exec`.

## 3. Idempotency — SETTLED

Every stage:

1. Check precondition (input milestone reached?) and postcondition (output milestone
   **already** reached? → `:ok`, no-op).
2. Do the work.
3. Write results **and advance the milestone in the same transaction**.
4. Enqueue the next stage.

This kills all three `cxk` bugs mechanically rather than by care:

- **Premature status** — impossible; status advances *inside* the transaction that
  writes the items. `Ash.bulk_create` with `transaction: :all`.
- **Duplicates on retry** — impossible; one transaction means partial writes don't
  exist. Commit-then-crash retries, sees the milestone reached, no-ops.
- **Stuck** — a receipt sits at a *named* milestone, so "stranded at `:extracted` for 10
  minutes" is a query.

**Belt-and-braces:** a unique index on `(receipt_id, line_no)` makes duplicates
impossible at the DB level even if the logic later regresses. Needs a decision on
re-extraction semantics (does a retried extract replace existing items, or conflict?) —
settle explicitly rather than discover. **OPEN.**

**Lifeline:** free `Oban.Plugins.Lifeline` rescues jobs stuck `executing` after a
container restart — directly `cxk`'s stuck symptom. Its documented duplicate-execution
risk is neutralised by the above, so **idempotency is the prerequisite for enabling it**,
not an optional extra.

### AshOban throughout — SETTLED

Every stage is an **AshOban trigger with `scheduler_cron: false`**, enqueued by the
previous stage via `AshOban.run_trigger(receipt, :persist)` (`ash_oban.ex:725` — builds a
job for one record and `Oban.insert!`s it). `scheduler_cron` accepts
`{:or, [:string, {:literal, false}]}`; `false` disables the scanner entirely.

This buys AshOban's tenancy handling — `use_tenant_from_record?(true)`, actor handling,
`on_error`, `worker_read_action` — with **zero cron latency**. Hand-rolled tenancy in a
background worker fails *silently* (see CLAUDE.md), which is the one failure mode not
worth trading for convenience.

This is also faster than today: the current `:process` trigger scans
`where status == :pending` on `scheduler_cron("* * * * *")`, so every receipt already
waits up to 60s before anything starts.

**Reconciler:** one trigger with a real `scheduler_cron` (~5 min) whose `where` matches
stranded records — non-terminal milestone, not currently progressing, e.g.
`status in [:pending, :extracted, :items_created] and updated_at < ago(5, :minute)`.
Because status is a durable milestone, the state *is* the queue; no extra bookkeeping.
(Exact `where` depends on resolving milestone-vs-condition above.)

> **Gotcha:** the reconciler's `where` depends on time, so it needs
> `stream_with: :full_read`. The AshOban docs are explicit — `:keyset` (the default) is
> wrong when *"the `where` clause may change between batches (e.g. if it depends on
> time)"*. This would fail intermittently under load rather than loudly.

## 4. Failure taxonomy — SETTLED (blocked on 4a)

### 4a. Prerequisite: the seam must classify errors

**The taxonomy is not implementable on the current seam.** `AiClient.handle_response/1`
collapses everything into `{:error, term}` — HTTP non-200 returns `{:error, body}` (a
decoded map), transport failures return `{:error, reason}` (an exception struct). A
caller cannot tell "sidecar is down" from "this image is garbage", and
`process_receipt.ex:30-33` treats all of them identically.

`AiClient` must return classified errors:

| Condition | Return |
|---|---|
| 200 | `{:ok, payload}` |
| Transport error (`:econnrefused`, timeout), 502, 503 | `{:error, :unavailable}` |
| 4xx | `{:error, {:bad_input, detail}}` |
| Other 5xx | `{:error, {:transient, detail}}` |

> This is what an anti-corruption layer at this seam is actually *for*. The 2026-07-14
> review argued for one on aesthetic grounds ("typed structs", "wire up the dead
> `contracts.ex`") and that justification did not survive scrutiny — the ACL it named
> was rightly deleted in `afb24d7` because `atomize/1` ran `String.to_existing_atom`
> over server-supplied keys. The load-bearing reason is this table: **without
> classification there is no taxonomy.** Belongs to Arc 1.

### 4b. The mapping

| Classification | Oban return | Receipt condition |
|---|---|---|
| `:unavailable` | `{:snooze, n}` | `:awaiting_ai` |
| `{:bad_input, _}` | `{:cancel, reason}` | `:failed` + reason |
| `{:transient, _}` | `{:error, reason}` | unchanged → retries → `discarded` |

**`{:discard, reason}` is deprecated** → `{:cancel, reason}`. Grep before writing new
returns.

### 4c. The snooze-hides-the-outage tension — resolved

Snoozing forever means a job never reaches `discarded`, so nothing alerts and the
sidecar can be down for a week in silence. **Resolution: make the outage visible in the
product, not only in Grafana.**

A snoozing extract sets the receipt's condition to `:awaiting_ai`, which the UI shows
("waiting for the AI service"). The outage is then visible to the person who cares most,
without any observability stack existing yet. Operators alert on
`count(receipts where condition == :awaiting_ai)` — a *domain* metric, more meaningful
than queue depth and not dependent on Arc 3 landing first.

**Belt-and-braces:** bound cumulative snoozing (~2h) and then convert to `{:error, _}`
so nothing waits forever. Track the snooze count in job `meta`.

### 4d. Custom `backoff/1` is required, not optional

Snooze increments `max_attempts` in lockstep (so it does **not** burn the retry budget)
**but still increments `attempt`** — and the default exponential backoff keys off
`attempt`. After a run of snoozes, a subsequent *real* error backs off enormously; the
Oban docs cite ~6 days between attempts 19 and 20. Pro's Smart Engine rolls `attempt`
back; on free Oban we discount snoozes ourselves — key `backoff/1` off
`attempt - snooze_count` (from `meta`), or cap the backoff outright.

Without this, a receipt that snoozed through a deploy and then hit one genuine error
would sit un-retried for days, looking exactly like the stuck-in-processing bug we're
here to remove.

## 5. Contract fix — OPEN (prerequisite)

Producer-first. The pipeline cannot be honest on a payload that lies.

1. **`python_service`** — add `raw_ocr_text`, `overall_confidence` and currency to
   `ExtractionResponsePayload`; surface `model_version`/`processing_time_ms` (already
   computed for the artifact DB, just not returned). The Tesseract branch already holds
   all of it and throws it away at `main.py:531-565`.
2. **`receipt_processor.ex`** — parse the flat shape only; delete the nested clauses and
   the `extraction["extraction"]` envelope.
3. **Fixtures** — rewrite to the real wire shape.
4. **Delete `/api/v1/receipts/extract`** and its schemas, or refactor to base64. Don't
   leave two contracts.
5. **`83o`** unblocks once currency crosses the wire.

## 6. Sidecar collapse — OPEN

Oban owns job state, so the sidecar becomes a stateless synchronous function over
base64, rebuildable from its Dockerfile with nothing to lose. Delete `jobs.py`,
`ai_jobs`, `/api/v1/jobs` and its handler, `ai_feedback`/`/api/v1/feedback`, and
`_executor`. With `raw_extraction` on the receipt, `ai_artifacts` has no remaining
purpose — which retires the unbounded base64 store rather than fixing its retention.

Open: does anything need SQLite afterwards? If the answer is only ephemeral model
cache, it's files on a volume, and `AI_DATABASE_URL` goes away. The test: *if this
vanished on restart, would we lose anything we care about?*

## 7. Observability — OPEN

- `t7j` is a prerequisite: `setup_opentelemetry()` runs unconditionally while the prod
  exporter falls back to `localhost:4317` — full instrumentation cost, every span
  dropped.
- `opentelemetry_oban` (1.1.1, already in deps) propagates trace context automatically:
  injects traceparent into job meta on insert, extracts on execution. Just needs setup.
- Elixir→Python propagation is **already correct** — `ai_client.ex:178` passes
  `propagate_trace_ctx: true` (the right option name for the installed version), and
  `telemetry.py` already instruments FastAPI to extract it.
- Oban Web (free) for `discarded` visibility. Queue-depth alerting is mandatory if §4
  chooses snooze.
- INFRA-002 already specs the Grafana stack — build on it, don't redesign it.

## Testing — OPEN

Drive the **real wire shape** at the boundary: upload → eventually `:ready_for_review`
with correct items, on **flat**-contract fixtures. Nested fixtures on a shape prod never
sends is the exact bug this spec exists to remove; the new tests must not reintroduce
it. Per CLAUDE.md: test at the system boundary, and fixtures may only set fields the
application actually sets.

## Not doing

- Oban Pro ($150/mo/app) — no multi-node, no true rate limit.
- RabbitMQ/Broadway — no stream to ingest.
- Reactor — nothing to compensate yet; see the card.
- A generic workflow engine — one real workflow is not an abstraction.
