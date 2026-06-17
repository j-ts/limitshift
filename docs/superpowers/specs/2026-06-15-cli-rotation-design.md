# CLI rotation on usage limits — design spec

- **Date:** 2026-06-15
- **Status:** Draft for review (revision 2, after adversarial review)
- **Component:** LimitShift runner (`limitshift.ps1`, `limitshift.sh`), queue schema, docs
- **Related:** existing **model rotation** feature (the direct analog)

## 0. What changed in revision 2

An adversarial review against the actual code found three blockers and several back-compat hazards.
The notable decisions made in response:

- **"Soonest reset" is kept** (it was explicitly requested), but reformulated as a simple in-memory
  "skip any runner whose reset hasn't passed yet; wait for the soonest one within 24h" loop — this
  delivers the same behavior without fragile per-runner re-dispatch machinery (§5.5, §5.6).
- **Limited vs set aside** are now two distinct, non-overlapping concepts (§5.2, glossary).
- **The >24h ("weekly") reset** becomes per-runner and non-fatal instead of throwing and killing the
  run (§5.6).
- **The Claude pre-check and Ollama detection key off the current runner, not the task** (§8, §11).
- **Back-compat is pinned**: an empty/absent `fallbacks` produces a byte-identical fingerprint and
  creates no new state files, so existing queues are untouched (§9, §12).
- **Switch semantics key off "runner change", not "tool change"** (so same-cli/different-model
  fallbacks behave correctly) (§6, §7).

## 1. Summary

Let a queue task list **backup tools**. When the tool currently running a task can't continue —
it hits a usage limit, or it keeps failing for a non-limit reason — LimitShift hands the **same
task** to the next tool in the list. Each tool starts a fresh conversation and picks up from what's
already in the project's files (discovered via `git`). LimitShift only *waits* for a usage reset
when every listed tool is currently capped, and then it waits for the **soonest** reset.

This is the cross-tool version of model rotation: model rotation switches **models** within one tool
and keeps the same conversation; CLI rotation switches **tools** and starts the new tool fresh.

## 2. Motivation

Today, when the only tool on a task hits its cap, the task waits for a reset — and for a reset more
than 24h out (a weekly cap) LimitShift **refuses to wait and aborts the run** (`Invoke-UiRestWithSummary`,
limitshift.ps1:392). If the user has access to other tools (`codex`, `gemini`, …), those tools sit
idle. CLI rotation keeps the work moving on a different tool instead of waiting or aborting — the core
promise of LimitShift, extended across tools.

## 3. Glossary (used precisely throughout)

- **Runner** — one tool configuration in a task's ordered list. **Runner 0** is the existing flat task
  (`cli`/`model`/`effort`/`extraArgs`); **runners 1..N** are the `fallbacks` entries. Each runner is
  `{ Cli, Models (ordered list), Effort, ExtraArgs }`.
- **Limited (capped)** — a runner temporarily blocked by a usage limit. It is recorded with a
  **reset time** and **stays in the rotation** — it will become usable again after its reset.
- **Set aside** — a runner **permanently removed from this task's rotation** because it failed
  persistently (an error past `maxRetriesOnError`, or a stall past `maxStalls`). It is **never retried
  again within this task run**. (Distinct from "limited" — set-aside runners never come back; limited
  runners do.)
- **Runner switch / runner change** — moving execution from one runner to a different runner (by index).
  A runner switch **always starts a fresh conversation**, even if the next runner uses the same `cli`.

## 4. Goals / non-goals

**Goals**

- Add an optional, per-task list of fallback tools, each with its own model/effort/permission flags.
- Switch tools automatically on a usage limit, and on persistent (retry-proof) failures.
- Never sit idle while another listed tool is available; when all are capped, wait for the **soonest**
  reset; survive weekly (>24h) caps by using another tool instead of aborting.
- Preserve all existing behavior **byte-for-byte** when a task has no fallbacks.
- Keep `limitshift.ps1` and `limitshift.sh` behavior identical, with tests in both suites.

**Non-goals (v1)**

- Carrying conversation memory across tools (the working tree is the handoff — see §6).
- Building usage **pre-checks** for non-Claude tools (reactive limit detection already covers
  rotation; see §10 and Appendix A).
- Per-tool `prompt` / `projectPath` / `completionCheck` overrides (the task's goal is tool-agnostic).
- A `runners`-style rewrite of the queue format (we use the additive `fallbacks` form only).
- LimitShift managing the user's git (no auto-commit, no clean-tree enforcement; see §6).
- Persisting the set-aside set / reset times across a Ctrl-C restart (only the runner index and its
  model index persist; see §7).

## 5. Queue schema and rotation behavior

### 5.1 The `fallbacks` field

The existing flat task is unchanged and acts as **runner 0**. A new optional `fallbacks` array lists
backup runners in preference order. Each is a self-contained bundle with its own `cli` plus optional
`model` / `effort` / `extraArgs`.

```json
{
  "name": "Fix the bugs",
  "cli": "claude",
  "model": ["opus", "sonnet"],
  "projectPath": "C:/Users/me/project",
  "prompt": "Fix the failing tests until they pass.",
  "extraArgs": ["--permission-mode", "acceptEdits"],

  "fallbacks": [
    { "cli": "codex",  "model": "gpt-5.5",
      "extraArgs": ["--sandbox", "workspace-write"] },
    { "cli": "gemini", "model": ["gemini-3-flash-preview", "gemini-2.5-pro"],
      "extraArgs": ["--approval-mode", "auto_edit"] }
  ]
}
```

Rules:

- `name`, `projectPath`, `prompt`, `completionCheck` stay at the task level — they describe the goal,
  which every runner shares.
- Each fallback object: `cli` is **required**; `model`, `effort`, `extraArgs` are optional and follow
  the *same* shapes and rules as the top-level fields (`model` may be a single string **or** an ordered
  array for model rotation within that runner; `extraArgs` is a string or array). Each fallback carries
  its **own** permission flag, because the flag differs per tool.
- `fallbacks` is optional. **Absent or empty ⇒ the task behaves exactly as today** (see §9, §12).

**Internal normalization.** Both scripts normalize a task into one ordered **runner list**: runner 0 =
the flat fields, runners 1..N = the `fallbacks` entries. A single-string `model` becomes a one-element
list, exactly like today. The loop then iterates runners uniformly.

### 5.2 The five outcomes of a run

At the end of any single run, exactly one of these applies. ("Switch to the next runner" always means:
pick the next runner per the selection rule in §5.5, start it fresh, and prepend the handoff note §6.1.)

| # | Outcome | Detection | Action |
|---|---------|-----------|--------|
| 1 | **Complete** | last non-empty line contains `[[TASK_COMPLETE]]` (completion-check mode) | Task done. ✅ |
| 2 | **Blocked** | last non-empty line contains `[[TASK_BLOCKED]] <reason>` | **Stop the task without switching runners.** Then apply `stopOnError` as for any failure: `true` → stop the queue; `false` → mark this task failed and continue. (Rationale in §5.4.) 🛑 |
| 3 | **Limit** | the runner's limit regex matches (`IsLimit`) | Rotate to the runner's **next model** in the same conversation, no wait. **Only when this runner's models are all limit-exhausted**, mark the runner **limited** (record its reset time, §5.6) and switch to the next runner. ⏳ |
| 4 | **Error** | non-zero exit / failure, not a limit | Retry the **same** runner up to `maxRetriesOnError` (a fresh budget per runner). If it still fails, **set this runner aside** (permanent for the task) and switch to the next runner. 🔁→➡️ |
| 5 | **Stall** | OK run, no marker, text identical to the previous no-marker run of **this runner+model conversation** | After `maxStalls` repeats, **set the runner aside** and switch to the next runner. **If there is no next runner (no fallbacks, or all others already set aside/limited with no one runnable), fall through to today's behavior unchanged: the task fails.** (Simple mode has no stall guard — outcome 5 never occurs there.) ➡️ |

A run that is **making progress** (OK, no marker, text *differs* from last time) resumes the same
runner in the same session, exactly as today.

### 5.3 Why retry-then-switch (no error classification)

We do **not** try to tell a transient error (network/API/proxy blip) from a permanent one (bad model
name, real permission failure). Retrying `maxRetriesOnError` times absorbs transient failures; if
failures **persist** past the budget, that's the signal the runner can't do the job → set it aside and
switch. A misspelled model fails every retry → switch (and is usually caught even earlier by model-name
validation during `--validate-only` for tools that publish a model list). A 2-second outage recovers →
no switch.

> **Note (same-cli fallbacks):** the "a different tool may succeed" intuition only holds when runners
> differ in `cli`/`extraArgs`. If several runners share the same `cli` **and** `extraArgs`, a
> tool-level failure (bad sandbox flag, missing PATH) is re-paid once per runner. Guidance
> (AGENTS.md / STRATEGIES.md): express *same-tool* variation as a **model array on one runner** (shared
> conversation, one error/stall budget); reserve `fallbacks` for genuinely different tools.

### 5.4 Why `[[TASK_BLOCKED]]` does not switch

A `[[TASK_BLOCKED]]` means the agent ran and concluded the task cannot be done (missing key,
contradictory requirement, etc.). We treat the agent's self-assessment as authoritative: trying the
same task on N more tools risks N tools all doing wrong or destructive work. This is a deliberate
asymmetry vs. a markerless crash (which *does* try fallbacks, because we have no signal at all).
**Guidance:** if a stop is really a fixable permission problem, fix the permission flags rather than
having the agent emit `[[TASK_BLOCKED]]` — a block is for genuine dead-ends.

### 5.5 Choosing the next runner (the selection rule)

Each runner carries two in-memory flags for the duration of the task: `setAside` (bool) and
`limitedUntil` (a reset `DateTime`, or null). To pick what to run next, scan runners **in order**
starting from the current index and choose the first runner that is **not set aside** and whose
`limitedUntil` is **null or already in the past**.

- If such a runner is found → run it. (If it differs from the runner that just ran, this is a runner
  switch: fresh session + handoff note.)
- If **no** runner is currently runnable, go to §5.6.

A **local-Ollama runner** (its own `extraArgs` carry `--oss --local-provider ollama`) can never hit a
cloud usage limit: it is always runnable (its `limitedUntil` is never set) and is a valid switch target
even when every cloud runner is capped.

### 5.6 When no runner is runnable (waiting and giving up)

When the selection rule finds nothing runnable:

- Consider the **live** runners: those **not set aside**. (By construction each live runner is
  currently **limited** with a `limitedUntil` in the future.)
- Among live runners, consider only those whose `limitedUntil` is **≤ 24h away**.
  - If at least one qualifies → **wait for the soonest** such `limitedUntil` (plus `resetBufferMinutes`),
    then re-run the selection rule (§5.5). The reset that just passed makes that runner runnable; other
    still-future runners are simply skipped (no wasted calls).
  - If none qualify (every live runner is >24h out — e.g. all on weekly caps): the task fails per
    `stopOnError`, with the existing "reset is more than 24 hours away" message. A >24h runner is **not**
    set aside — on a later cycle, if its reset has since fallen within 24h, it becomes waitable again.
- If there are **no** live runners at all (every runner set aside): the task fails per `stopOnError`.

**Reset-time sources for `limitedUntil`:**

- **Non-Claude tools:** parse the limit error via `Get-ResetTimeFromErrorText` (handles "try again at X",
  "try again in Xh Ym", "reset after…", `retryDelay: "Ns"`). When nothing parses, fall back to
  `now + settings.limitWaitMinutes` (a *guessed* reset).
- **Claude:** read `SessionReset` / `WeekReset` from `Get-ClaudeUsage` (limitshift.ps1:1266-1275), which
  already returns them. This is a small addition — reading the reset value for the comparison — and does
  **not** require changing the blocking `Wait-UntilClaudeUsageReady`, which stays as-is for the
  no-fallbacks path (§8).
- A *guessed* reset (`limitWaitMinutes`) must not starve a runner with a real, sooner reset: §5.6 already
  picks the soonest `limitedUntil`, so a real 20-min reset is chosen over a guessed 30-min one. A runner
  that is re-probed and still capped simply re-applies its guess (bounded by `maxRunsPerTask`).

### 5.7 Failure reason on full exhaustion

When a task fails because every runner is set aside (or every live runner is >24h-capped), the recorded
failure reason and final message **aggregate** the per-runner terminal outcomes, e.g.:

> all runners failed — claude/opus: error (xyz); codex/gpt-5.5: stalled; gemini/…: weekly cap (>24h)

so the user can see that every tool was tried and why each stopped. (`runs.csv` rows carry the runner's
cli+model, §12, so the full history is reconstructable.)

### 5.8 `maxRunsPerTask` interaction

`maxRunsPerTask` (default 20) counts **actual CLI invocations** (including limit-only and error runs);
**waits do not count**. A rotating task legitimately uses more runs (runners × models × retries × stalls
× progress-resumes), so:

- The backstop, when hit by a task that **has fallbacks**, marks the task failed and respects
  `stopOnError` (rather than the current hard `throw` that aborts the whole queue — limitshift.ps1:2550),
  so one over-budget rotating task can't kill an overnight queue. (No-fallbacks tasks keep today's
  behavior.)
- STRATEGIES.md documents a rough budget (`runs ≈ Σ over runners [models + retries + stalls +
  progress-resumes]`) and recommends raising `maxRunsPerTask` (e.g. ≥ 10 × runner count) for rotation
  tasks.

## 6. Continuity and the git requirement

When runners switch, the new conversation inherits **nothing** from the old one. The only reliable
record of partial progress is **what's on disk** — a usage limit can cut a tool off mid-edit before it
writes any "handoff log," so we never depend on the agent reporting its own progress.

### 6.1 Handoff note

On **every run that starts because the runner changed** (a runner switch — the runner index advanced, or
we resumed after a wait into a different runner), LimitShift **prepends an exact, canonical note** to that
run's prompt. The note is prepended on a runner change **even when the new runner shares the previous
runner's `cli`** (it's a fresh session with no memory regardless). It is **not** prepended on runner 0's
first run, nor on same-runner continuations (model rotation within a runner, error retry, no-marker
resume).

The note text is a single shared constant emitted **verbatim** by both scripts (tested for exact text,
§13). Two variants:

- **Completion-check mode** (canonical wording):
  > A previous AI tool started this task and was interrupted (usage limit or failure). Partial work may
  > already exist in the working tree. Before doing anything, inspect both `git status` (for new/untracked
  > files) and `git diff` (for changes to tracked files) to see what has already been done. Continue from
  > there; do not redo finished work. End your final response with `[[TASK_COMPLETE]]` when the task is
  > fully done, or `[[TASK_BLOCKED]] <reason>` if it genuinely cannot be completed.
- **Simple mode:** identical, minus the final `[[TASK_COMPLETE]]`/`[[TASK_BLOCKED]]` sentence.

The note instructs inspecting **both** `git status` and `git diff` on purpose: with no baseline commit,
`git diff` shows nothing for brand-new untracked files (see §6.2).

### 6.2 Git is required for rotation — but LimitShift never touches it

- A task with a **non-empty** `fallbacks` **requires** its `projectPath` to be a git working tree.
  `--validate-only` and the runner check that a `.git` is present and **fail with a clear message** if
  not. This check **only** fires when `fallbacks` is non-empty, so no existing single-CLI queue can
  newly fail validation.
- LimitShift does **not** enforce a clean tree, does **not** commit, and does **not** stash. The git
  requirement exists only so the handoff (`git status`/`git diff`) is *possible*.
- **Degraded handoff without a baseline commit:** if the repo has no commits yet (no `HEAD`), `git diff`
  is empty for untracked files; the handoff still works via `git status` (which the note covers), but is
  less precise. Validation emits a **non-fatal warning** when a fallbacks task's `projectPath` has no
  commits, pointing at the commit-baseline guidance.
- Documentation tells users to have their prompt **commit a baseline before starting** rotation work, so
  the diff cleanly reflects the task's partial progress.

## 7. Session and per-task state

- **Fresh on every runner switch:** a runner switch always drops the active session id so the next run is
  a `New` run and receives the handoff note — **including when the next runner shares the cli** (a
  different model/effort/permission set is a different runner). This applies to all session shapes:
  Claude/agy/copilot's up-front-minted id, codex's stdout-captured thread id, and gemini's reported
  session id are **all** discarded on a switch so no stale id leaks across a runner boundary. (For
  `agy`, whose only resume is "continue most recent conversation", a switch starts a **new** agy
  conversation rather than `agy -c`; its reply is recovered from that new conversation's transcript.)
- **Session shapes (for reference):** Claude/agy/copilot receive an up-front minted id; codex **and**
  gemini report their own id (captured post-run); gemini may additionally reject `--resume`, in which
  case the saved id is dropped and it retries with a continuation prompt (existing behavior,
  limitshift.ps1:2615-2621).
- **Counter resets on switch:** `errorRetryCount`, `stallCount`, and `previousNoMarkerText` all reset
  when the runner changes (comparing one runner's output to another's is meaningless). They **also**
  reset on a model rotation **within** a runner (a different model produces different output).
- **In-memory flags:** the `setAside` set and per-runner `limitedUntil` reset times live in memory for
  the task's duration only.
- **Persisted across Ctrl-C / restart:** the **current runner index** and the **model index within that
  runner** (the existing per-task model-index file, limitshift.ps1:1074-1079, becomes scoped to the
  current runner). The `setAside` set and `limitedUntil` times are **not** persisted; on restart they
  start empty, so a previously set-aside runner gets one fresh chance and limited runners are re-probed
  (at most one wasted limit-discovery call per runner). The restored runner resumes at its persisted
  model index; other runners begin at model 0 when first entered.
- These state files (runner index, per-runner model index) are **created only when `fallbacks` is
  non-empty**, so existing single-CLI state directories are untouched.

## 8. Claude pre-check interaction (current runner, not task)

Today, before each `claude` run, `Wait-UntilClaudeUsageReady` may **block/wait** if Claude is already
capped, and the Ollama-skip and this pre-check are gated on the **task's** cli/extraArgs
(limitshift.ps1:2556). Both gates must move to the **current runner**:

- The pre-check runs only when the **current runner** is cloud `claude` (its own `extraArgs` are **not**
  local-Ollama). A local-Ollama claude runner must **not** trigger a cloud `/usage` query (it would
  consume the very account it exists to avoid).
- **With fallbacks present:** if the pre-check shows the current `claude` runner is capped, record it as
  **limited** with its `SessionReset`/`WeekReset` time, then use the §5.5 selection rule to **switch to
  the next runnable runner instead of waiting**. Prepend the handoff note. The pre-check applies to **any**
  `claude` runner about to run (not only runner 0) and advances **forward** only.
- If no runner is currently runnable, fall through to §5.6 (which now includes the recorded Claude reset
  in the soonest-reset comparison).
- **No-fallbacks back-compat:** when a task has no fallbacks, the pre-check path is **literally
  unchanged** — it calls `Wait-UntilClaudeUsageReady` exactly as today and blocks in place.

## 9. Re-run detection (fingerprint)

The task fingerprint decides whether an already-"done" task is skipped or re-run when its definition
changes. Today it is `Name | Cli | ProjectPath | Model | Effort | Prompt | ExtraArgs`, joined with the
`U+001F` field separator, with the model list space-joined (limitshift.ps1:1034-1042; limitshift.sh
mirrors the field set/order/separator). The two scripts intentionally produce **different hash values**
(PowerShell normalizes `ProjectPath` to an absolute native path; bash hashes the raw JSON — see the
in-code note at limitshift.ps1:1000-1002), so each is only **self-consistent**: it agrees with *itself*
on whether a task changed. That property must be preserved.

Changes:

- **Back-compat invariant:** when `fallbacks` is absent or empty, the fingerprint is **byte-identical to
  today's**. The fallbacks contribution is appended **only when non-empty** (or defined so an empty
  fallbacks contributes the empty string strictly after the existing seven fields). A test asserts a
  no-fallbacks task's hash equals a known pre-upgrade value.
- **Canonical fallback serialization (both scripts identical):** the fingerprint is computed over the
  **normalized runner list** (so a single-string model and its one-element-array form are equivalent and
  do **not** trigger a re-run). Each fallback bundle contributes its fields in the order
  `cli, model-list-space-joined, effort, extraArgs-space-joined`; bundles are separated by a **distinct**
  record separator (`U+001E`) to avoid colliding with the `U+001F` field separator; an omitted optional
  field contributes the empty string. Adding, removing, reordering, or editing any fallback changes the
  hash.
- **On re-run of a changed task**, drop the persisted runner index and per-runner model index along with
  the done marker and session id (the current code already drops session/done/model-index at
  limitshift.ps1:2530-2533).

## 10. Usage pre-checks for other tools — out of scope (v1)

Rotation works by **reacting** to the limit error: run the tool, and if its limit regex matches, rotate.
This reactive detection already exists for all five tools; the only cost is one fast failed call to
discover a cap. A pre-check is only an optimization, and verified research (Appendix A) shows Claude is
the only tool with a clean, scriptable, non-consuming usage command today. Therefore:

- **v1:** no new pre-checks. Keep Claude's existing pre-check (plus the §8 current-runner change).
  Everything else relies on reactive limit detection.
- **Future (optional, separate effort):** `copilot` via the GitHub REST billing API is the cleanest
  candidate; `gemini` `/stats model` is worth a spike to confirm it runs **non-interactively** (slash
  commands are historically sent to the model as text, not intercepted); `codex` (brittle session-file
  parsing) and `agy` (no scriptable path) are not worth it.

## 11. Validation

- Each fallback validates like a task's execution fields: `cli` ∈ the allowed set; `effort` allowed
  values depend on **that fallback's** `cli`; `model` is a string or non-empty string array.
- **JSON Schema cannot recurse the existing top-level `allOf` into fallback objects.** The `fallbacks`
  items subschema must carry its **own** copy (or `$ref`) of the per-cli `effort` rules **and** the
  haiku-no-effort rule. Enforcement is by **both** the schema and the runner's own validation pass, kept
  in parity. A test asserts an invalid `effort` on a **fallback** (not just runner 0) fails validation.
- Per-tool model-name validation (`modelValidation`, capability discovery/cache) runs for **each
  distinct runner's** tool.
- The local-Ollama rule (a local `claude` runner needs a `model`) is checked **per runner bundle**
  (`Test-IsOllamaTask` applied to the runner's own `extraArgs`, not the flat task).
- The git-working-tree requirement (§6.2) is checked for any task whose `fallbacks` is non-empty; a
  fallbacks task whose `projectPath` has no commits gets a non-fatal warning.

## 12. Logging and UX

- `runs.csv` today has exactly `timestamp,task,run,mode,exit,status` (limitshift.ps1:76; limitshift.sh:1955).
  CLI rotation **adds new `cli` and `model` columns** (a header/schema change both scripts make in
  lockstep) so each row shows which runner produced it and the rotation is reconstructable.
- A runner switch prints a clear one-line beat, mirroring the model-switch line
  (e.g. *"Task N: limit on claude/sonnet (models exhausted); switching to codex/gpt-5.5"*). The handoff
  is logged.
- Waiting prints which runner's reset is being waited for and the wake time.

## 13. Cross-runner parity and testing

Every behavior above is implemented identically in `limitshift.ps1` and `limitshift.sh`, with new tests
in both `tests/limitshift.Tests.ps1` and `tests/test-limitshift.sh` covering at least:

- **Parsing:** flat task, no fallbacks (unchanged); task with fallbacks; fallback with array `model`;
  fallback missing optional fields.
- **Back-compat:** a no-fallbacks task's fingerprint equals a known pre-upgrade value; a no-fallbacks
  task still **fails (not switches) on a stall**; the no-fallbacks Claude pre-check path is unchanged.
- **Validation:** invalid fallback `cli`; invalid `effort` for a **fallback's** `cli`; fallbacks task
  with a non-git `projectPath` (fails); fallbacks task in a git repo (passes); fallbacks task in a git
  repo with no commits (warns).
- **Rotation:** limit on the last model of runner 0 switches to runner 1 fresh + exact handoff note;
  persistent error switches after `maxRetriesOnError`; stall switches after `maxStalls` (with a next
  runner present); `[[TASK_BLOCKED]]` does **not** switch; all-limited waits for the **soonest** reset
  and resumes the runner whose reset passed; a runner whose reset is >24h is skipped, and the task fails
  only when every live runner is >24h/dead; all-set-aside fails per `stopOnError` with an aggregate
  reason.
- **Ollama:** runner 0 cloud claude capped → switch to a local-Ollama claude fallback with **no**
  `/usage` query.
- **State:** runner index + per-runner model index persist across a simulated restart; fingerprint
  changes when a fallback is edited.

## 14. Documentation deliverables

- `README.md` / `README.uk.md`: a "CLI rotation" feature section next to "Model rotation"; mark the
  roadmap item done; note the git requirement.
- `AGENTS.md`: how to build a `fallbacks` list (per-tool permission flags, model arrays), the git
  requirement, when rotation is appropriate, and the same-cli-→-use-a-model-array guidance (§5.3).
- `REFERENCE.md`: the `fallbacks` field reference and rotation behavior.
- `limitshift-queue.schema.json`: the `fallbacks` field with descriptions and per-fallback validation.
- `limitshift-queue.example-advanced.json`: a realistic CLI-rotation example.
- **New `STRATEGIES.md`** (user-facing guide, linked from the README; explicitly in v1 scope per the
  user): writing high-quality prompts, the commit-before-rotation rule, choosing models/tools,
  completion-check vs simple mode, the `maxRunsPerTask` budget for rotation, and example workflows.
  Seeded partly from the existing "Prompt Quality Bar" guidance in `AGENTS.md`.

## 15. Risks / accepted trade-offs

- **Markerless real block:** a tool that crashes before emitting `[[TASK_BLOCKED]]` looks like an error,
  so fallbacks are tried before the task fails. Accepted: attempts are bounded, and a permission error on
  one tool may genuinely succeed on another (different permission flags). (Contrast with an *explicit*
  block, §5.4.)
- **Git repo, never committed:** the handoff degrades (untracked files don't show in `git diff`); the
  note covers this by also requiring `git status`, and validation warns. Accepted.
- **Same-cli fallbacks** re-pay tool-level failures once per runner; mitigated by guidance (§5.3) to use
  a model array instead.
- **Restart re-probing:** set-aside/limited state isn't persisted, so a restart re-probes (a few wasted
  discovery calls). Accepted to keep persistence minimal.
- **`agy` as a fallback:** weaker first runner (reply recovered from transcript, sequential, no real
  resume); fine as a fallback since switches always start it fresh. Documented.

## 16. Out of scope / YAGNI (restated)

Cross-tool memory bridging; per-tool prompt/projectPath/completionCheck overrides; the `runners` format;
LimitShift managing git; pre-checks for non-Claude tools; persisting set-aside/reset state across
restarts; "resume the exact capped runner with custom re-entry ordering" (the §5.5 selection rule
already resumes the right runner naturally).

---

## Appendix A — usage pre-check research (verified 2026-06-15)

Adversarially-verified findings on whether each tool exposes a non-consuming, scriptable usage check
like `claude -p "/usage"`:

| Tool | Non-consuming scriptable pre-check today? | Mechanism | v1 stance |
|------|-------------------------------------------|-----------|-----------|
| **claude** | ✅ Yes (already used) | `claude -p "/usage"` (session% + weekly% + reset) | Keep |
| **copilot** | ⚠️ Only outside the CLI | REST billing API `GET /users/{username}/settings/billing/premium_request/usage` — returns *consumed* only; compute remaining vs the plan limit | Defer (future) |
| **gemini** | ❓ Unproven non-interactively | `/stats model` shows % remaining + reset, non-consuming, but slash commands are historically sent to the model as text; needs a spike to confirm a non-interactive parseable call | Defer (spike later) |
| **codex** | ❌ No command | Only via parsing `~/.codex/sessions/**/rollout-*.jsonl` `rate_limits` — undocumented, fragile | Skip |
| **agy** | ❌ No | No scriptable path; `--output-format json` rejected; non-TTY stdout-drop bug | Skip |

Key sources: OpenAI Codex CLI reference & issues #3641/#14728/#15281; Gemini CLI `quota-and-pricing`
docs, PR #13843, issues #27363/#25616/#5435; GitHub Copilot CLI slash-command cheat sheet, programmatic
reference, REST billing API (apiVersion 2026-03-10), issues #2797/#1582/#2827; Antigravity CLI
CHANGELOG and issues #46/#76. (Full citations captured in the brainstorming research run.)
