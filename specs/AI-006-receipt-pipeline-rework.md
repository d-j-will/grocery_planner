# AI-006: Receipt Pipeline Rework — staged workers, honest contract

**Status:** design complete — all sections firm. Field names settled (`stage` +
`condition`); prod data confirmed disposable. Ready for per-arc implementation.
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
  the message and `receipt.stage` is still true; the LiveView catches up on reconnect.
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

**Two fields.** The existing `status` column is renamed to **`stage`** and records the
furthest durable milestone; a new **`condition`** column records how the receipt is
faring. `status` is retired — a word so overloaded it invited exactly the "what does
this mean" confusion the split exists to remove.

```
stage:      :pending → :extracted → :items_created → :ready_for_review → :confirmed
condition:  :ok (default) │ :awaiting_ai │ :failed
```

Today's `:processing` is the bug in miniature: it means "something started and we don't
know what", which is exactly why stuck is indistinguishable from working. `stage`
deliberately does **not** mirror "extracting…"/"matching…" — Oban already knows what is
executing; duplicating that into the receipt would be a second source of truth, the
failure this whole spec exists to remove.

### 2a. Stage vs condition — SETTLED: two fields

`:failed` and `:awaiting_ai` are **not stages**. A receipt "awaiting AI" has still only
reached `:pending`; one that failed did so *at* some stage. One enum meaning two things
is exactly what `:processing` does wrong. So they split onto two orthogonal axes —
**where it got** and **how it's doing**:

| Field | Values | Behaviour |
|---|---|---|
| `stage` | `:pending → :extracted → :items_created → :ready_for_review → :confirmed` | **Monotonic.** Only ever advances. |
| `condition` | `:ok` (default) / `:awaiting_ai` / `:failed` | Orthogonal, resettable. |
| `failure_reason` | string | `nil` unless `condition == :failed`. |

No value appears in both axes — a check worth stating, because it's what proves they're
genuinely orthogonal rather than one field wearing two hats. A fresh receipt is
`stage: :pending, condition: :ok` ("at the start, and fine"), never "pending pending".

Invariants (Ash validations): `condition == :failed` requires a `failure_reason`, and
implies `stage != :confirmed`.

**Why this is strictly better than today.** A failed receipt becomes
`stage: :extracted, condition: :failed` — it tells you it got as far as extraction and
then failed *there*. Today's flat `:failed` throws that away.

**Retry falls out for free:** set `condition: :ok` and re-enqueue. The milestone is
preserved, so idempotent stages resume exactly where they stopped — no bespoke
resume logic.

**Migration (prod data is disposable — confirmed 2026-07-16).** `status` → `stage` is
not a clean rename: today's `:failed` leaves the position axis for `condition`, and old
rows never recorded *where* they failed. Because prod receipts on `food.davewil.dev` are
throwaway, the mapping can be lossy: `:pending → :pending`, `:processing → :pending`,
`:completed → :ready_for_review`, `:failed → stage: :pending, condition: :failed`. No
data-driven backfill needed. If that ever stops being true (real receipts before Arc 2
ships), the `:completed` split must instead be decided per-row by what exists (items?
inventory entries?).

> **Honest caveat, stated so it doesn't rot into a bug.** `:awaiting_ai` *is* a
> denormalised projection of Oban state (the extract job is snoozing). We accept the
> duplication deliberately: single-writer (the extract stage), for two reads Oban can't
> serve well — the LiveView, which shouldn't query the jobs table per receipt, and the
> operator metric in §4c.
>
> **The rule that keeps it honest: nothing may read `condition` to make a scheduling
> decision.** Oban remains authoritative for whether and when to retry. `condition` is
> display and alerting only. The moment a worker branches on it, it's a second source of
> truth and we've rebuilt the bug this spec exists to remove.

### 2b. Where `categorise` fits — SETTLED: side-branch, no milestone

`match` sets `:ready_for_review` **and** enqueues `categorise`. Categorise enriches items
in place and broadcasts so the LiveView updates live. It has **no milestone**, and its
failure sets **no condition** on the receipt — a receipt with no AI-suggested categories
is still perfectly reviewable, which is exactly what happens today when the sidecar is
off (`receipt_processor.ex:138` already gates on `Categorizer.enabled?()`).

This removes the separate `:matched` milestone.

This stage is also `c29`'s fix for the categorisation path, and it's mostly subtraction:
`Task.start` (unsupervised, silently lost on crash, invisible) becomes an Oban job
(supervised, retryable, observable). The degradation behaviour it already has is
preserved; only the execution model improves.

**Reconciler `where`** follows from the above:
`stage in [:pending, :extracted, :items_created] and condition != :failed and
updated_at < ago(5, :minute)`.

A receipt at `:ready_for_review` whose categorise never ran is **not** stranded — it's
reviewable. Don't reconcile it.

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

- **Premature completion** — impossible; `stage` advances *inside* the transaction that
  writes the items. `Ash.bulk_create` with `transaction: :all`.
- **Duplicates on retry** — impossible; one transaction means partial writes don't
  exist. Commit-then-crash retries, sees the milestone reached, no-ops.
- **Stuck** — a receipt sits at a *named* milestone, so "stranded at `:extracted` for 10
  minutes" is a query.

### Belt-and-braces: `line_no` + a unique index — SETTLED

**Add `receipt_item.line_no` (integer, position in the extraction) and a unique index on
`(receipt_id, line_no)`.**

The obvious cheaper key is wrong: **a real receipt can legitimately have two identical
lines** — buy two milks rung up separately and you get `MILK / 1 / 3.99` twice. Any
uniqueness over `(receipt_id, raw_name, …)` would reject valid data. Position is the
only honest key, and it needs a column: `receipt_item` has **no** ordering attribute
today (no `line_no`, no `sort_order`).

**`line_no` earns its place on domain grounds regardless of idempotency.** Neither
`list_for_receipt` nor the `has_many :receipt_items` applies a sort, so items come back
in arbitrary Postgres order — the review screen doesn't match the paper receipt in the
user's hand. That's a latent UX bug that `line_no` fixes; the duplicate-proofing is a
free side-benefit rather than the justification.

**Re-extraction semantics.** Retry can never re-extract: once `stage == :extracted` the
extract stage's postcondition check no-ops, so items are created exactly once, at
`:items_created`. There is no conflict to resolve on the retry path.

An explicit user **rescan** is a *different operation*, not a retry: it deletes existing
items and resets `stage` to `:pending` in one transaction. Distinct action, distinct
semantics, no index conflict. Do not model it as a retry.

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
`where status == :pending` (today's column name) on `scheduler_cron("* * * * *")`, so
every receipt already waits up to 60s before anything starts.

**Reconciler:** one trigger with a real `scheduler_cron` (~5 min) whose `where` matches
stranded records — non-terminal stage, not currently progressing:
`stage in [:pending, :extracted, :items_created] and condition != :failed and
updated_at < ago(5, :minute)`. Because `stage` is a durable milestone, the state *is* the
queue; no extra bookkeeping.

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

## 5. Contract fix — FIRM (Arc 1, prerequisite)

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

## 6. Sidecar collapse — FIRM (Arc 4)

Oban owns job state, so the sidecar becomes a stateless synchronous function over
base64: rebuildable from its Dockerfile, with nothing to back up and nothing to lose.

**The original question was "why SQLite when Postgres is right there?" The answer turns
out to be better than either option: the sidecar doesn't need a database.**

All DB use is the three tables and nothing else. Every feature endpoint takes
`db: Session = Depends(get_db)` **solely to write an artifact**; the only other consumer
is the readiness check, checking the database's own existence. Remove the tables and the
database has no users.

Ordered, because the last steps depend on the first:

1. **Retire `ai_artifacts`** (needs Arc 2's `raw_extraction`). Not "fix its retention" —
   retire it. It is write-only (no Elixir client fn; no ingress per ADR 4, so readable
   only via `docker exec`), unbounded (the promised prune was never written), and stores
   the full base64 image into `Column(Text)` on every scan. Input and output both remain
   recoverable without it: the image is already on disk, and the extraction lands in
   `receipt.raw_extraction` — tenant-scoped, backed up, joinable, prunable with the
   receipt.

   > **Decision (2026-07-16): delete, don't fix; the eval log is deferred to
   > `grocery_planner-k0g`.** Debugging a bad extraction is covered by `raw_extraction` +
   > `failure_reason` + the OTel span, so nothing needs an audit log today. A durable,
   > per-receipt, tenant-queryable **eval dataset** is the one thing telemetry can't
   > provide — but it's only justified by a real model-improvement need, which doesn't
   > exist yet. `k0g` captures what that resource would be (a Postgres `AiCall` Ash
   > resource: metadata + a `receipt_id` reference, **never the blob**, bounded by an Oban
   > prune) so it's built fresh when the need is real, not resurrected. Building a
   > reader-less audit log "just in case" is the exact pattern this arc deletes.
2. **Delete `ai_jobs` + `jobs.py` + `/api/v1/jobs` + the `receipt_extraction` handler.**
   The handler branches `USE_VLLM_OCR` → else **mock**; prod runs Tesseract, so this path
   would serve "Mock Supermarket" to real users.
3. **Delete `ai_feedback` + `/api/v1/feedback`.** Dead — feedback lives in Postgres
   (`ai_categorization_feedback`, `item_handlers.ex:296`), which is correct: a user
   correcting a category is a domain event, not ML telemetry. The system that owns the
   user relationship owns the labels.
4. **Delete `/api/v1/receipts/extract`** and its rich schemas. It needs `image_path` and
   `ai-service` doesn't mount `receipt-uploads`; it cannot work in this deployment.
5. **Delete `_executor`** — declared at `jobs.py:22`, never referenced.
6. **Then drop the datastore itself:** `database.py`, the SQLAlchemy dependency,
   `AI_DATABASE_URL`, and the `ai-data` volume. `hf-cache` stays — it's a model cache,
   i.e. files that are disposable by definition.

> **Dependency trap:** `/health/ready` (`main.py:170`) checks DB connectivity, and it is
> the endpoint the Elixir health check calls. Removing the database **without** removing
> that check turns readiness into a probe of something deleted. Step 6 must land with the
> health-check change, not after it. Interacts with `c29`.

The test applied throughout: *if this vanished on restart, would we lose anything we
care about?* For every remaining candidate the answer is no — which is what "stateless"
actually means.

## 7. Observability — FIRM (Arc 3)

**Smaller than it looks: the instrumentation is already wired and correct.** It is
producing spans and throwing them all away.

Already true — do not rebuild:

- `application.ex:47-52` calls `OpentelemetryPhoenix.setup()`,
  `OpentelemetryEcto.setup([:grocery_planner, :repo])` and `OpentelemetryOban.setup()`.
- `opentelemetry_oban` (1.1.1) propagates trace context **automatically** once set up —
  injects traceparent into job `meta` on insert, extracts it on execution. So a
  web-request trace continues into the worker, and the staged pipeline inherits this for
  free.
- **Elixir→Python propagation is already correct.** `ai_client.ex:178` passes
  `propagate_trace_ctx: true` — the right option name for the installed version — and
  `telemetry.py` already instruments FastAPI to extract it. (A research pass advised
  renaming this to `propagate_trace_headers`, citing current docs. That option does not
  exist in our version; `register_options` accepts only `[:span_name, :no_path_params,
  :propagate_trace_ctx]`, and Req raises on unknown options. **Do not "fix" this.**)

The work:

1. **`t7j`** — the whole reason none of the above is visible. `setup_opentelemetry()`
   runs unconditionally while the prod exporter falls back to `localhost:4317`: full
   instrumentation cost, every span silently dropped. Configure the endpoint in
   `runtime.exs` under prod and gate setup on `OTEL_ENABLED` so it no-ops without a
   collector. Note `docker-compose.yml:24` sets `OTEL_ENABLED` on the Python service
   only — the Elixir app reads nothing.
2. **Add `oban_web`** — not currently a dependency. Free and Apache-2.0 since
   2025-01-16 (it was previously commercial; the memory of it being paid is out of date).
   This is `discarded`-job visibility for the cost of one dep.
3. **Metrics that matter here**, in priority order:
   - `count(receipts where condition == :awaiting_ai)` — **the outage signal.** A domain
     metric, more meaningful than queue depth, and the thing that stops §4c's snooze from
     hiding an outage.
   - `discarded` / `cancelled` job counts — the dead-letter signal. Alert on non-zero.
   - Queue depth (`available` + `scheduled` + `retryable`) per queue.
   - Error rate **split by class** (`:unavailable` / `{:bad_input, _}` / `{:transient, _}`).
     The split is load-bearing, not cosmetic: it maps exactly onto §4b's decision table,
     so it tells you whether to fix the sidecar or the input.
   - Sidecar saturation — it is CPU-bound at `cpus: "2"` and will saturate long before
     Oban does. On a single homelab host, OOM-kill won't look like an application error.
4. **Dashboards** — INFRA-002 already specs the Grafana stack. Build on it; don't
   redesign it.

**Sequencing note:** landing this *before* Arc 2 makes the rework measurable rather than
asserted — a real before/after on stuck receipts and duplicate items. Not a dependency,
but the cheapest way to make the change legible afterwards.

## Testing — FIRM (per arc)

The existing suite is the cautionary tale, not the baseline. `receipt_processor_test.exs`
is 560 lines that exercise **only** the shape production never emits, and assert fields
production always leaves nil (`:252`). It is green. It has been green throughout. Green
tests are what let this survive six months.

**The rule for every arc: fixtures may only contain what the sidecar actually puts on
the wire.** Per CLAUDE.md's fixture-honesty rule — a helper that sets a field no
production path writes creates phantom data that masks the broken feature. That is
precisely what happened here, so the new tests carry the burden of proof.

Per arc:

- **Arc 1** — the seam. Assert the classification table (§4a) at the `AiClient`
  boundary: connection-refused → `{:error, :unavailable}`, 4xx → `{:error, {:bad_input,
  _}}`, 5xx → `{:error, {:transient, _}}`. Use `Req.Test` stubs returning **real**
  sidecar payloads. Rewrite `receipt_processor_test.exs` to the flat shape — deleting the
  nested fixtures is part of the deliverable, not cleanup for later.
  **Contract test:** one test that asserts the Elixir parser's expectations against the
  actual `ExtractionResponsePayload` fields. The whole defect class is the two sides
  disagreeing while both look correct; nothing currently fails when they diverge.
- **Arc 2** — the pipeline, at the **system boundary**: upload → eventually
  `:ready_for_review` with the right items, in the right order (`line_no`). Then the
  three `cxk` regressions, each stated as behaviour:
  - crash between `persist` committing and the job returning → re-run → **no duplicate
    items** (the postcondition no-op);
  - sidecar down → receipt shows `condition: :awaiting_ai` and the job snoozes → **no
    attempts burned**;
  - bad input → `condition: :failed` with a reason → **not retried**.
  These must drive the real flow, not call `save_extraction_results/2` directly — the
  current tests call the function, which is why they never noticed the app calls a
  different endpoint. Per `08u`, no `Process.sleep`.
- **Arc 3** — no unit tests for dashboards. One assertion worth having: with no collector
  configured, OTel setup no-ops without background export errors (that's `t7j`'s own
  acceptance criterion).
- **Arc 4** — deletion is the test: the suite must stay green with the three tables and
  the two dead endpoints gone. Anything that breaks was testing something no production
  path used. Plus a live `/health/ready` check after the datastore goes.

**Smell test before adding any test** (CLAUDE.md): *if I refactored the implementation
but kept behaviour identical, would this still pass?* If no, it's testing structure —
pull it to the boundary.

## Not doing

- Oban Pro ($150/mo/app) — no multi-node, no true rate limit.
- RabbitMQ/Broadway — no stream to ingest.
- Reactor — nothing to compensate yet; see the card.
- A generic workflow engine — one real workflow is not an abstraction.
