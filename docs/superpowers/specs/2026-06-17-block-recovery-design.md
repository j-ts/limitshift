# Block recovery (universal recovery prompt) — design spec

- **Date:** 2026-06-17
- **Status:** Draft for review
- **Component:** LimitShift runner (`limitshift.ps1`, `limitshift.sh`), queue schema, docs
- **Related:** existing **CLI rotation / handoff note** feature (`2026-06-15-cli-rotation-design.md`) — this
  reuses its handoff machinery and the `[[TASK_BLOCKED]]` protocol.

## 1. Summary

Add an opt-in **block-recovery** behaviour. Today, when a completion-checking agent ends with
`[[TASK_BLOCKED]] <reason>`, LimitShift treats it as an authoritative dead-end and stops the task. With
recovery enabled, a block becomes a springboard: LimitShift feeds the failure back to the agent and asks
it to *find another way to finish — unless a human is genuinely needed*.

The recovery prompt has **two forms**, chosen by whether context carries over:

- **Variant A — same-session nudge (short).** The block happened in a session that is about to be
  *resumed*. The agent already has the task and its own output in context, so it gets a brief "reconsider
  and finish, or say you need a human" follow-up.
- **Variant B — fresh-session handoff (complete).** A *different* runner is taking over (a CLI switch on a
  usage limit / persistent error / stall). The new runner knows nothing, so it gets the full prompt:
  *this was the task; this is why the previous attempt failed (its output); find a way to fix it, unless a
  human is needed.* Variant B **augments the existing handoff note** ([limitshift.ps1:1594](../../../limitshift.ps1)) with the one piece it
  lacks today — the previous runner's failure output.

Everything is gated by a single integer, **`recoveryAttempts`**. When it is `0` (the default), behaviour is
**unchanged**: a block still stops the task, and the handoff note stays exactly as it is today.

## 2. Motivation

A `[[TASK_BLOCKED]]` is sometimes a true dead-end (missing credential, contradictory requirement) and
sometimes just the agent giving up early on something it could solve from a different angle, or with the
context of *why* its first approach failed. Today LimitShift cannot tell the user "the agent tried again
with the failure in hand and got it" — it just stops. Recovery lets a task push past a soft block while
preserving a clean, explicit escape hatch (`HUMAN:`) for the cases that genuinely require a person, so the
user is interrupted only when they actually need to be.

## 3. Glossary (used precisely throughout)

- **Recovery round** — one extra CLI run triggered by a (non-`HUMAN:`) block when recovery is enabled. The
  number of rounds is bounded by `recoveryAttempts`.
- **Variant A (nudge)** — the short, same-session recovery prompt (§6.1). Used when the block is handled by
  *continuing the same session*.
- **Variant B (complete handoff)** — the existing handoff note plus a failure-context section (§6.2). Used
  when a *runner switch* starts a fresh session and recovery is enabled.
- **`HUMAN:` short-circuit** — a block whose reason, trimmed, begins (case-insensitively) with `HUMAN:`.
  It stops recovery immediately and flags the task for a human, regardless of rounds remaining (§7, step 3).
- **needs-human** — the terminal state when recovery cannot finish a task: a normal failure, plus a
  distinct marker/log so the user can tell "waiting on me" apart from "genuinely errored" (§9).

## 4. Goals / non-goals

**Goals**

- An opt-in, per-queue **or** per-task integer that turns a `[[TASK_BLOCKED]]` into up to N same-session
  recovery rounds before giving up.
- A clean human escape hatch (`[[TASK_BLOCKED]] HUMAN: <reason>`) that short-circuits recovery.
- When recovery is enabled, enrich the existing CLI-switch handoff (Variant B) with the previous runner's
  failure output, so a fresh runner inherits *why* the last attempt failed.
- Preserve all existing behaviour **byte-for-byte** when `recoveryAttempts` is `0`/absent.
- Identical behaviour in `limitshift.ps1` and `limitshift.sh`, with tests in both suites.

**Non-goals (v1)**

- Switching tools on a block. Block recovery is **same-session only**; it never advances the runner. When
  recovery is exhausted, the task stops — it does **not** cascade into `fallbacks` (§8).
- A new marker. The human signal reuses `[[TASK_BLOCKED]]` with a `HUMAN:` reason convention (§7).
- `settings`-and-`tasks` override semantics. Placement is strictly either/or (§5.2).
- Recovering a *simple-mode* (no completion-check) task — there is no block marker to react to (§5.3).

## 5. Configuration

### 5.1 The `recoveryAttempts` field

A single new field, integer **≥ 0**, default **`0`** (off). When `> 0`, a `[[TASK_BLOCKED]]` (without the
`HUMAN:` prefix) triggers up to that many same-session recovery rounds before the task is flagged
needs-human.

```json
{
  "settings": { "recoveryAttempts": 0 },
  "tasks": [
    {
      "name": "Make the build pass",
      "cli": "claude",
      "projectPath": "C:/Users/me/project",
      "completionCheck": true,
      "recoveryAttempts": 3,
      "extraArgs": ["--permission-mode", "acceptEdits"],
      "prompt": "Make `npm run build` pass."
    }
  ]
}
```

One integer carries both meanings (enable + count); `0` is unambiguously "off". This mirrors
LimitShift's existing `maxStalls` / `maxRetriesOnError` style and avoids an "enabled but zero rounds"
contradiction. (Rejected alternative: a separate boolean `recoverOnBlock` plus a count.)

### 5.2 Placement is *either/or*, not inherit-and-override

`recoveryAttempts` may appear in **`settings`** *or* on **individual `tasks`**, but **never both**:

- **In `settings` only** → applies to every task in the queue.
- **On specific `tasks` only** → applies to just those tasks; tasks without it stay at `0` (off).
- **In `settings` AND on any task** → `--validate-only` **fails** with a clear message, e.g.
  *"recoveryAttempts may be set in settings OR on individual tasks, not both — found in settings and on
  task 2."*

This is deliberately *unlike* `completionCheck`'s override model (which silently lets a per-task value win):
one source of truth per queue, nothing to reason about.

### 5.3 Requires completion checking

Recovery keys off the `[[TASK_BLOCKED]]` marker, which only exists when completion checking is on.
`completionCheck` defaults to `true`, so this only bites when someone explicitly disables it:

- If `recoveryAttempts > 0` applies to a task whose **effective** `completionCheck` is `false`,
  `--validate-only` **fails** with a clear message naming the task.

### 5.4 Not part of the task fingerprint

`recoveryAttempts` is an operational knob (like `maxRetriesOnError`/`stopOnError`), not a description of
*what* the task does. It is **excluded from the task fingerprint** ([limitshift.ps1:1034](../../../limitshift.ps1) and the bash
mirror): editing it does **not** invalidate a `.done` marker, and a queue that never sets it produces a
byte-identical fingerprint to today's. (This makes the back-compat invariant in §10 trivial — the
fingerprint code is untouched.)

## 6. The two recovery prompts

Both are produced **only when `recoveryAttempts > 0`**. Each is a single shared constant emitted
**verbatim** by both scripts and asserted for exact text in tests (matching how the handoff note is tested
in the CLI-rotation work).

### 6.1 Variant A — same-session nudge (short)

Prepended to the resume prompt for a recovery round (the agent already has full context):

```
You ended with [[TASK_BLOCKED]]: <reason>.
Recovery is enabled — do not stop yet. Reconsider and find another way to finish this task.
Inspect `git status` and `git diff` first so you do not redo work already done.

- If you finish, end your final response with [[TASK_COMPLETE]].
- If you genuinely need a human (secrets/credentials you cannot access, an irreversible
  or destructive action, a product/design decision, or something you cannot verify
  yourself), end with [[TASK_BLOCKED]] HUMAN: <one-line reason> and stop.
- If you are still stuck but it is not a human-only blocker, end with [[TASK_BLOCKED]] <reason>.
```

`<reason>` is the newest block reason (re-fed each round). The rest of the resume prompt (the original task,
per `Get-ResumePrompt` at [limitshift.ps1:1633](../../../limitshift.ps1)) is unchanged.

### 6.2 Variant B — fresh-session complete handoff

When recovery is enabled and a **runner switch** starts a fresh session, the existing handoff
(`Get-TaskPromptWithHandoff`, [limitshift.ps1:1596](../../../limitshift.ps1)) gains one **failure-context section**. The note already
re-appends the original task, so the only new ingredient is *why the previous attempt failed*:

```
A previous AI tool worked on this task and could not continue (<usage limit / repeated
errors / stalls>). Partial work may already exist — inspect `git status` and `git diff`
first; continue from there, do not redo finished work.

This is why the previous attempt did not finish:
<failure reason + tail of the previous runner's output>

[ ...existing handoff note continues: original task + completion-marker instructions... ]
```

- **`<failure reason>`** comes from the runner's recorded terminal reason (`runnerReasons[...]`, e.g.
  `error: …`, the stall reason, or "usage limit").
- **`<output tail>`** is the tail of that run's stored raw output (`outputs/`), capped (~last 40 lines /
  ~2 KB) so the prompt stays sane.
- When `recoveryAttempts == 0`, the handoff is emitted **exactly as today** (no failure-context section).

## 7. Control flow (the block outcome, extended)

Block detection is unchanged (`Get-MarkerStatus`, [limitshift.ps1:1941](../../../limitshift.ps1) — returns
`@{ Status='Blocked'; Reason=<text after marker> }`). The two sites that handle a block today —
single-runner ([limitshift.ps1:3076](../../../limitshift.ps1)) and rotation ([limitshift.ps1:3320](../../../limitshift.ps1)), each currently
`Save-TaskFailedMarker` then `break` — get the recovery hook. The bash runner mirrors both.

When a run ends and `recoveryAttempts > 0` (and completion checking is on):

1. `[[TASK_COMPLETE]]` → task done (unchanged).
2. `[[TASK_BLOCKED]] HUMAN: <reason>` (reason trimmed, case-insensitive `HUMAN:` prefix) → **stop now**,
   flag needs-human (§9), skip any remaining rounds.
3. `[[TASK_BLOCKED]] <reason>` (no `HUMAN:`):
   - **rounds remain** (`usedRounds < recoveryAttempts`): increment the recovery counter (§8), **continue
     the same session** with Variant A re-feeding `<reason>`, and re-run. Back to step 1.
   - **rounds exhausted**: **stop**, flag needs-human with the last reason (§9). Do **not** cascade into
     `fallbacks` (§8).

Limit/error/stall rotation is untouched **except** that a fresh runner started by a switch now receives
Variant B (§6.2). A block still **never** triggers a runner switch — recovery stays in-session.

## 8. Counting, exhaustion, and the fallbacks boundary

- **`maxRunsPerTask`:** each recovery round is a real CLI invocation and counts toward `maxRunsPerTask`
  (exactly as resumes do). The effective ceiling is whichever of `recoveryAttempts` and the remaining
  `maxRunsPerTask` budget is hit first; hitting `maxRunsPerTask` during recovery flags needs-human (it
  does not hard-`throw` for a task that is otherwise progressing).
- **No cascade after exhaustion.** Block recovery (same tool, in-session) and CLI rotation (different
  tools, for limits/errors/stalls) stay separate axes. When recovery rounds are exhausted on a still-blocked
  task, the task stops and is flagged needs-human; `fallbacks` are **not** tried for the block. (`fallbacks`
  remain fully active for limit/error/stall, now carrying Variant B.) This preserves the existing
  "a block is authoritative" semantics from the CLI-rotation spec (§5.4 there).

## 9. Flagging for human

When recovery ends in a state a human must look at (a `HUMAN:` short-circuit, or rounds/`maxRunsPerTask`
exhausted while still blocked):

- Write the existing `status/task-NN.failed` marker (`Save-TaskFailedMarker`, [limitshift.ps1:1960](../../../limitshift.ps1)) so
  failure accounting/`stopOnError` is unchanged, **plus** a distinct `status/task-NN.needs-human` marker
  recording the final reason.
- Print a clear, distinct console/log beat: `Task N needs human review: <reason>`.
- `stopOnError` still governs whether the queue halts (`true` → stop; `false` → mark failed, continue) —
  the needs-human marker is additive, not a new queue-control path.

The separate marker lets the end-of-run summary and a quick directory scan distinguish *"waiting on me"*
from *"genuinely errored"*.

## 10. Back-compat invariant

When `recoveryAttempts` is `0`/absent (every existing queue):

- The block outcome is the current `Save-TaskFailedMarker` → `break` with no recovery branch taken.
- The handoff note is emitted byte-identically (no failure-context section).
- The fingerprint is unchanged (§5.4); no new state files are created (§11).
- A regression test asserts a no-recovery task still **fails (does not retry) on a block**, and that the
  handoff note text is unchanged when recovery is off.

## 11. State and resume

- **Recovery counter** persists in `limitshift-<queue>/task-NN-recovery-attempts.txt` (same pattern as the
  CLI-rotation runner/model-index files), so stopping LimitShift (`s` / Ctrl-C) and resuming does not reset
  the round count.
- The file is **created only when a task actually enters recovery** (`recoveryAttempts > 0` and a block
  occurred), so no-recovery state directories are untouched.
- It is dropped when the task fingerprint changes (alongside `.done`, session id, and the rotation state
  files), and on a clean completion.

## 12. Validation (`--validate-only`)

- `recoveryAttempts` is an integer **≥ 0** wherever it appears (settings or task). Non-integer / negative →
  fail.
- **Either/or placement** (§5.2): present in `settings` **and** on any task → fail with the dual-location
  message.
- **Completion-check dependency** (§5.3): `recoveryAttempts > 0` on a task whose effective
  `completionCheck` is `false` → fail, naming the task.
- The JSON Schema encodes `recoveryAttempts` in both `settings` and `tasks[]`; the either/or and
  completion-check cross-field rules are enforced by the **runner's** validation pass (schema cannot
  express them cleanly), kept in parity across both scripts.

## 13. Logging and UX

- A recovery round prints a one-line beat mirroring the rotation beats, e.g.
  *"Task N blocked — recovery 1/3, retrying in the same session"*.
- A `HUMAN:` short-circuit prints *"Task N needs human review: <reason>"* and skips remaining rounds.
- The final summary counts needs-human tasks distinctly from plain failures.
- `runs.csv` is unchanged in columns; recovery rounds appear as ordinary resumed runs (the `cli`/`model`
  columns from CLI rotation already capture the runner).

## 14. Cross-runner parity and testing

Implemented identically in `limitshift.ps1` and `limitshift.sh`, with new tests in both
`tests/limitshift.Tests.ps1` and `tests/test-limitshift.sh`. The existing mock CLI (which emits scripted
marker lines) is extended to emit a block-then-complete sequence. Coverage:

- **Back-compat:** `recoveryAttempts` absent/`0` → a block still fails the task with no extra run; handoff
  note text unchanged; fingerprint equals a known pre-upgrade value.
- **Recovery success:** `recoveryAttempts: 2`, block then complete → one recovery round, task done, counter
  respected.
- **HUMAN short-circuit:** `[[TASK_BLOCKED]] HUMAN: needs prod creds` → stops on round 0, `.needs-human`
  marker written, no extra run; case-insensitive `human:` also matches.
- **Exhaustion:** blocks every round → after N rounds, `.failed` + `.needs-human`, last reason recorded.
- **maxRunsPerTask cap during recovery** → needs-human (no hard queue abort).
- **Validation:** `recoveryAttempts` in both settings and a task → fail; `recoveryAttempts > 0` with
  `completionCheck: false` → fail; negative/non-integer → fail.
- **Variant B:** with recovery enabled, a limit/error switch produces a handoff containing the original
  task **and** the previous runner's failure reason + output tail; with recovery off, the handoff is the
  current text.
- **State:** the recovery counter persists across a simulated restart; it is dropped on a fingerprint
  change.

## 15. Documentation deliverables

- `README.md` / `README.uk.md`: a short "Block recovery" subsection near completion checking / CLI
  rotation; note the `HUMAN:` escape hatch and that it is opt-in.
- `REFERENCE.md`: `recoveryAttempts` in the settings and per-task tables; a "Block recovery" section
  describing the either/or placement, the two prompt variants, the `HUMAN:` convention, and the
  needs-human marker.
- `AGENTS.md`: how/when to set `recoveryAttempts`, the either/or placement rule, the completion-check
  requirement, and the `HUMAN:` convention; update the `[[TASK_BLOCKED]]` guidance to mention recovery.
- `limitshift-queue.schema.json`: `recoveryAttempts` (integer ≥ 0) in `settings` and `tasks[]`.
- `limitshift-queue.example-advanced.json`: a realistic `recoveryAttempts` example.
- `CHANGELOG.md`: a new `## [1.2.0]` section (minor bump; `[1.1.0]` is already used by CLI rotation) with an **Added** entry covering block recovery,
  the two prompt variants, the `HUMAN:` short-circuit, the either/or config rule, and the needs-human
  marker.

## 16. Risks / accepted trade-offs

- **Recovery thrash on a real dead-end:** an agent that should have blocked may burn its rounds before
  flagging needs-human. Bounded by `recoveryAttempts` (minimum 1 when enabled) and `maxRunsPerTask`;
  the `HUMAN:` hatch lets a clear-eyed agent exit on round 0. Accepted.
- **`HUMAN:` convention is text, not a hard marker:** an agent could phrase a real human-blocker without the
  prefix and waste rounds. Mitigated by spelling the convention out in the recovery prompt itself (§6.1)
  and in docs. Accepted (chosen over adding a new marker to keep the protocol small).
- **Variant B output tail size:** a noisy tail could crowd the prompt; capped (~40 lines / 2 KB) and clearly
  delimited. Accepted.
- **Same-session context may be the problem:** the nudge keeps the context that led to the block, so a
  fresh perspective is not guaranteed. Accepted for v1 (same-session was the chosen mechanism); a future
  option could re-seed a fresh session on block.

## 17. Out of scope / YAGNI

A new human-signal marker; switching tools on a block / cascading into `fallbacks` after recovery; a
per-task override layered on top of a settings default (placement is either/or); recovering simple-mode
tasks; re-seeding a fresh same-tool session on block; making `recoveryAttempts` part of the fingerprint.
