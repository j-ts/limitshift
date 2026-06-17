# CLI Rotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional per-task `fallbacks` list so a task automatically switches to a backup CLI when the current tool hits a usage limit or fails persistently, keeping work moving instead of waiting or aborting.

**Architecture:** Each task normalizes into an ordered **runner list** (runner 0 = the flat task fields; runners 1..N = `fallbacks`). The task loop rotates models *within* a runner (existing behavior) and switches *runners* when a runner's models are all capped or it fails persistently. Each runner tracks two in-memory flags: `limitedUntil` (temporary, has a reset time, stays in rotation) and `setAside` (permanent error/stall, removed from this task). When no runner is runnable, wait for the soonest reset within 24h. Every change is mirrored byte-for-byte in `limitshift.ps1` and `limitshift.sh`, with tests in both suites.

**Tech Stack:** PowerShell 5.1 (`limitshift.ps1`, tested with Pester in `tests/limitshift.Tests.ps1`), Bash (`limitshift.sh`, tested with a custom harness in `tests/test-limitshift.sh`), JSON Schema draft-07 (`limitshift-queue.schema.json`).

**Source spec:** `docs/superpowers/specs/2026-06-15-cli-rotation-design.md`. Read it before starting; section references below (e.g. "spec §5.5") point into it.

**Conventions used by this plan:**
- PowerShell unit tests dot-source the script with `. $scriptPath -LoadFunctionsOnly` and call functions directly (see existing `Context` blocks). End-to-end tests use `Invoke-RunnerProcess` with stub CLIs (`gemini.ps1`, etc.) written onto `PATH`.
- Bash tests use `pass`/`fail` helpers and run `PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1`, asserting on captured output.
- Run PowerShell tests: `Invoke-Pester tests/limitshift.Tests.ps1`. Run bash tests: `bash tests/test-limitshift.sh`.
- Commit after every task. Use the shown commit message.
- A "runner" is `{ Cli, Models (ordered list), Effort, ExtraArgs }`. Runner 0 is the flat task; runners 1..N are `fallbacks`.

---

## Phase 0 — Test fixtures

### Task 0.1: Add queue fixtures for fallbacks

**Files:**
- Create: `tests/fixtures/configs/valid-fallbacks.json`
- Create: `tests/fixtures/configs/broken-fallback-bad-cli.json`
- Create: `tests/fixtures/configs/broken-fallback-bad-effort.json`

- [ ] **Step 1: Create a valid fallbacks fixture**

`tests/fixtures/configs/valid-fallbacks.json`:
```json
{
  "tasks": [
    {
      "name": "rotate-task",
      "cli": "claude",
      "model": ["opus", "sonnet"],
      "projectPath": ".",
      "prompt": "do it",
      "extraArgs": ["--permission-mode", "acceptEdits"],
      "fallbacks": [
        { "cli": "codex", "model": "gpt-5.5", "extraArgs": ["--sandbox", "workspace-write"] },
        { "cli": "gemini", "model": ["gemini-3-flash-preview", "gemini-2.5-pro"], "extraArgs": ["--approval-mode", "auto_edit"] }
      ]
    }
  ]
}
```
Note: `projectPath` is `"."` so the fixture resolves against the repo (a git repo) — this matters for the git-required check in Phase 4. Tests that need a *non-git* path will write their own temp queue.

- [ ] **Step 2: Create an invalid-cli fallback fixture**

`tests/fixtures/configs/broken-fallback-bad-cli.json`:
```json
{
  "tasks": [
    { "name": "t", "cli": "claude", "projectPath": ".", "prompt": "p",
      "fallbacks": [ { "cli": "not-a-cli" } ] }
  ]
}
```

- [ ] **Step 3: Create an invalid-effort fallback fixture**

`tests/fixtures/configs/broken-fallback-bad-effort.json`:
```json
{
  "tasks": [
    { "name": "t", "cli": "claude", "projectPath": ".", "prompt": "p",
      "fallbacks": [ { "cli": "gemini", "effort": "high" } ] }
  ]
}
```

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/configs/valid-fallbacks.json tests/fixtures/configs/broken-fallback-bad-cli.json tests/fixtures/configs/broken-fallback-bad-effort.json
git commit -m "test: add fallbacks queue fixtures"
```

---

## Phase 1 — Schema

### Task 1.1: Add `fallbacks` to the JSON schema with per-fallback validation

**Files:**
- Modify: `limitshift-queue.schema.json` (the task `items` object and its `allOf`)

Spec: §5.1, §11. JSON Schema `if/then` does **not** recurse into nested objects, so the per-CLI `effort` rules and the haiku rule must be **duplicated** inside the `fallbacks` items subschema.

- [ ] **Step 1: Add the `fallbacks` property to the task object**

In `limitshift-queue.schema.json`, inside `properties.tasks.items.properties` (alongside `extraArgs`), add a `fallbacks` array whose items reuse the runner fields. Each item requires `cli`; `model`/`effort`/`extraArgs` reuse the same shapes as the top-level task. Mirror the top-level `model`/`extraArgs` `oneOf` shapes and add the same per-CLI `effort` `allOf` and the haiku-no-effort rule scoped to the item.

```json
"fallbacks": {
  "type": "array",
  "minItems": 1,
  "description": "Backup runners tried in order when the primary runner hits a usage limit or fails persistently (CLI rotation). Each entry is a self-contained tool config. Requires projectPath to be a git working tree.",
  "items": {
    "type": "object",
    "required": ["cli"],
    "additionalProperties": false,
    "properties": {
      "cli": { "enum": ["claude", "codex", "gemini", "agy", "copilot"] },
      "model": {
        "oneOf": [
          { "type": "string" },
          { "type": "array", "items": { "type": "string" }, "minItems": 1 }
        ]
      },
      "effort": { "enum": [null, "minimal", "low", "medium", "high", "xhigh", "max"] },
      "extraArgs": {
        "oneOf": [
          { "type": "string" },
          { "type": "array", "items": { "type": "string" } }
        ]
      }
    },
    "allOf": [
      { "if": { "properties": { "cli": { "const": "gemini" } }, "required": ["cli"] },
        "then": { "properties": { "effort": { "enum": [null] } } } },
      { "if": { "properties": { "cli": { "const": "agy" } }, "required": ["cli"] },
        "then": { "properties": { "effort": { "enum": [null] } } } },
      { "if": { "properties": { "cli": { "const": "copilot" } }, "required": ["cli"] },
        "then": { "properties": { "effort": { "enum": [null, "low", "medium", "high", "xhigh", "max"] } } } },
      { "if": { "properties": { "cli": { "const": "claude" } }, "required": ["cli"] },
        "then": { "properties": { "effort": { "enum": [null, "low", "medium", "high", "xhigh", "max"] } } } },
      { "if": { "properties": { "cli": { "const": "claude" }, "model": { "pattern": "(?i)haiku" } }, "required": ["cli", "model"] },
        "then": { "properties": { "effort": { "enum": [null] } } } },
      { "if": { "properties": { "cli": { "const": "codex" } }, "required": ["cli"] },
        "then": { "properties": { "effort": { "enum": [null, "minimal", "low", "medium", "high", "xhigh"] } } } }
    ]
  }
}
```

- [ ] **Step 2: Validate the schema is still well-formed JSON and the valid fixture passes**

The runner's `--validate-only` runs its own validation (Phase 2), but confirm the schema file itself parses:

Run: `powershell -NoProfile -Command "Get-Content limitshift-queue.schema.json -Raw | ConvertFrom-Json | Out-Null; 'schema OK'"`
Expected: prints `schema OK` (no JSON error).

- [ ] **Step 3: Commit**

```bash
git add limitshift-queue.schema.json
git commit -m "feat(schema): add fallbacks field with per-fallback effort validation"
```

---

## Phase 2 — Parse `fallbacks` into a runner list

### Task 2.1: Parse and validate `fallbacks` in `Read-QueueConfig` (PowerShell)

**Files:**
- Modify: `limitshift.ps1` — `Read-QueueConfig` (the per-task parse loop around lines 833-960, where `Models` is built and the per-CLI effort/model validation lives)
- Test: `tests/limitshift.Tests.ps1` — new `Context 'CLI rotation (fallbacks) — parsing'`

Spec: §5.1, §11. Reuse the **existing** model-parse and effort/model validation logic for each fallback so rules stay identical to runner 0.

- [ ] **Step 1: Write failing tests for fallbacks parsing**

Add to `tests/limitshift.Tests.ps1`:
```powershell
Context 'CLI rotation (fallbacks) — parsing' {
    It 'parses fallbacks into a Runners list with runner 0 = flat task' {
        $cfg = Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'valid-fallbacks.json')
        @($cfg.Tasks[0].Runners) | Should -HaveCount 3
        $cfg.Tasks[0].Runners[0].Cli | Should -Be 'claude'
        @($cfg.Tasks[0].Runners[0].Models) | Should -Be @('opus','sonnet')
        $cfg.Tasks[0].Runners[1].Cli | Should -Be 'codex'
        @($cfg.Tasks[0].Runners[1].Models) | Should -Be @('gpt-5.5')
        @($cfg.Tasks[0].Runners[2].Models) | Should -Be @('gemini-3-flash-preview','gemini-2.5-pro')
    }

    It 'gives a no-fallbacks task a single-runner Runners list' {
        $cfg = Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'valid-minimal.json')
        @($cfg.Tasks[0].Runners) | Should -HaveCount 1
        $cfg.Tasks[0].Runners[0].Cli | Should -Be 'claude'
    }

    It 'rejects a fallback with an unknown cli, naming the task and fallback' {
        { Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'broken-fallback-bad-cli.json') } |
            Should -Throw '*Task 1*fallback*claude, codex, gemini, agy, copilot*'
    }

    It 'rejects a fallback effort that is invalid for that fallback cli (gemini)' {
        { Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'broken-fallback-bad-effort.json') } |
            Should -Throw '*Task 1*fallback*gemini has no effort flag*'
    }

    It 'rejects a local-Ollama claude fallback that has no model' {
        $root = New-TestRoot
        $projectPath = Join-Path $root 'project'; New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
        $queuePath = Join-Path $root 'queue.json'
        Write-TestQueue -Path $queuePath -Config @{
            tasks = @(@{ name='t'; cli='claude'; projectPath=$projectPath; prompt='p';
                fallbacks = @(@{ cli='claude'; extraArgs=@('--oss','--local-provider','ollama') }) })
        }
        { Read-QueueConfig -Path $queuePath } | Should -Throw '*fallback*local Ollama claude*needs a model*'
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*fallbacks*parsing*'`
Expected: FAIL (no `Runners` property; fallback validation not implemented).

- [ ] **Step 3: Implement fallbacks parsing in `Read-QueueConfig`**

Refactor the existing model-parse + effort/model/Ollama validation block (lines ~833-907) into a reusable inner helper, e.g. `Parse-Runner -Node $node -TaskNumber $n -Label '<task|fallback k>'`, returning `[pscustomobject]@{ Cli; Models; Model; Effort; ExtraArgs }`. Call it for the flat task fields (runner 0), then for each `fallbacks` entry, prefixing error messages with `fallback <k>`. Attach the result list to the task object as `Runners` (runner 0 first). Keep the existing top-level `Cli`/`Model`/`Models`/`Effort`/`ExtraArgs` properties populated from runner 0 so existing readers/tests are unaffected. A fallback inherits no value from runner 0 — only its own fields.

Key points to preserve from the existing logic: empty model array rejected; non-string array element rejected; claude dotted-model rejection (unless that runner is Ollama); local-Ollama-claude requires a model; per-CLI effort enums; empty-string effort → null.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*fallbacks*parsing*'`
Expected: PASS.

- [ ] **Step 5: Run the full PowerShell suite to confirm no regressions**

Run: `Invoke-Pester tests/limitshift.Tests.ps1`
Expected: all existing tests still PASS (the `Runners` addition is additive; top-level fields unchanged).

- [ ] **Step 6: Commit**

```bash
git add limitshift.ps1 tests/limitshift.Tests.ps1
git commit -m "feat(ps1): parse and validate fallbacks into a runner list"
```

### Task 2.2: Parse and validate `fallbacks` in `read_queue_config` (Bash, parity)

**Files:**
- Modify: `limitshift.sh` — `read_queue_config` (around lines 690-820), `get_task_models`/`get_task_models_joined` (646-657)
- Test: `tests/test-limitshift.sh`

- [ ] **Step 1: Write failing bash tests**

Add tests mirroring Task 2.1 using the existing harness style. Because the bash runner stores task data in shell arrays/`jq` lookups rather than objects, assert behavior through `--validate-only` output rather than an in-memory `Runners` object:
```bash
# valid fallbacks queue validates OK
out=$(bash "$SCRIPT" --queue "$CONFIGS/valid-fallbacks.json" --validate-only 2>&1)
printf '%s' "$out" | grep -q 'Config OK' && pass "fallbacks: valid queue validates" || fail "fallbacks: valid queue" "$out"

# bad fallback cli is rejected
out=$(bash "$SCRIPT" --queue "$CONFIGS/broken-fallback-bad-cli.json" --validate-only 2>&1)
printf '%s' "$out" | grep -q 'fallback' && printf '%s' "$out" | grep -q 'claude, codex, gemini, agy, copilot' && pass "fallbacks: bad cli rejected" || fail "fallbacks: bad cli" "$out"

# bad fallback effort (gemini) rejected
out=$(bash "$SCRIPT" --queue "$CONFIGS/broken-fallback-bad-effort.json" --validate-only 2>&1)
printf '%s' "$out" | grep -q 'fallback' && printf '%s' "$out" | grep -q 'gemini has no effort flag' && pass "fallbacks: bad effort rejected" || fail "fallbacks: bad effort" "$out"
```

- [ ] **Step 2: Run and confirm failure**

Run: `bash tests/test-limitshift.sh`
Expected: the three new assertions FAIL.

- [ ] **Step 3: Implement fallbacks parsing/validation in `read_queue_config`**

In `read_queue_config`, after validating the flat task fields, iterate `.tasks[i].fallbacks[]` via `jq` and run the same `cli`/`model`/`effort`/Ollama checks already applied to the task, with error messages prefixed `Task <n>: fallback <k>: ...`. Store the per-runner data so the loop can read it later — recommended: expose helpers `get_task_runner_count <i>`, `get_runner_field <i> <r> <field>`, and `get_runner_models_joined <i> <r>` that read `.tasks[i]` (runner 0) or `.tasks[i].fallbacks[r-1]` (runner ≥1) via `jq`. Reuse `is_ollama_task`'s logic against the runner's own extraArgs (see Task 7.4 for the runner-scoped variant).

- [ ] **Step 4: Run and confirm pass**

Run: `bash tests/test-limitshift.sh`
Expected: new assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add limitshift.sh tests/test-limitshift.sh
git commit -m "feat(sh): parse and validate fallbacks into a runner list"
```

---

## Phase 3 — Fingerprint (back-compat + fallbacks)

### Task 3.1: Extend `Get-TaskFingerprint` (PowerShell)

**Files:**
- Modify: `limitshift.ps1` — `Get-TaskFingerprint` (canonical format, lines ~1004-1042)
- Test: `tests/limitshift.Tests.ps1` — extend `Context 'Get-TaskFingerprint ...'`

Spec: §9. **Back-compat invariant:** absent/empty `fallbacks` must produce a byte-identical fingerprint to today. Fallback bundles use a distinct record separator (`U+001E`) between bundles and the existing field join inside each.

- [ ] **Step 1: Write failing tests**

```powershell
It 'fingerprint is unchanged when there are no fallbacks (back-compat)' {
    # A task object WITHOUT a Runners/Fallbacks contribution must hash exactly as before.
    $task = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p'; Model='m'; Models=@('m'); Effort='high'; Prompt='do it'; ExtraArgs=@('--x') }
    $withEmpty = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p'; Model='m'; Models=@('m'); Effort='high'; Prompt='do it'; ExtraArgs=@('--x'); Runners=@(); Fallbacks=@() }
    (Get-TaskFingerprint -Task $task) | Should -Be (Get-TaskFingerprint -Task $withEmpty)
}

It 'fingerprint changes when a fallback is added' {
    $base = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p'; Model='m'; Models=@('m'); Effort=$null; Prompt='X'; ExtraArgs=@() }
    $withFb = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p'; Model='m'; Models=@('m'); Effort=$null; Prompt='X'; ExtraArgs=@();
        Runners=@(
            [pscustomobject]@{ Cli='claude'; Models=@('m'); Effort=$null; ExtraArgs=@() },
            [pscustomobject]@{ Cli='codex'; Models=@('gpt-5.5'); Effort=$null; ExtraArgs=@() }
        ) }
    (Get-TaskFingerprint -Task $base) | Should -Not -Be (Get-TaskFingerprint -Task $withFb)
}

It 'fingerprint is identical for string vs 1-element-array fallback model' {
    $a = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p'; Model='m'; Models=@('m'); Effort=$null; Prompt='X'; ExtraArgs=@();
        Runners=@([pscustomobject]@{ Cli='claude'; Models=@('m'); Effort=$null; ExtraArgs=@() }, [pscustomobject]@{ Cli='codex'; Models=@('g'); Effort=$null; ExtraArgs=@() }) }
    $b = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p'; Model='m'; Models=@('m'); Effort=$null; Prompt='X'; ExtraArgs=@();
        Runners=@([pscustomobject]@{ Cli='claude'; Models=@('m'); Effort=$null; ExtraArgs=@() }, [pscustomobject]@{ Cli='codex'; Models=@('g'); Effort=$null; ExtraArgs=@() }) }
    (Get-TaskFingerprint -Task $a) | Should -Be (Get-TaskFingerprint -Task $b)
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*fingerprint*fallback*' `
Expected: FAIL (fallbacks not yet part of the hash; back-compat test may already pass — that one must stay passing).

- [ ] **Step 3: Implement the fallback contribution**

In `Get-TaskFingerprint`, after the existing 7-field canonical string is built, compute a fallbacks segment **only from runners 1..N** (skip runner 0 — it is already represented by the existing `Cli`/`Model`/`Effort`/`ExtraArgs` fields). For each fallback runner, build `cli + U+001F + (models -join ' ') + U+001F + effort + U+001F + (extraArgs -join ' ')`; join bundles with `U+001E`. Append the segment to the canonical string **only when there is at least one fallback runner** (so no-fallbacks hashes are byte-identical). Read fallback runners from `$Task.Runners` (elements 1..N) when present; if absent, contribute nothing.

```powershell
# after $canonical is assembled from the existing 7 fields:
$runnersProp = $Task.PSObject.Properties['Runners']
if ($null -ne $runnersProp -and @($runnersProp.Value).Count -gt 1) {
    $fbParts = foreach ($r in @($runnersProp.Value)[1..(@($runnersProp.Value).Count - 1)]) {
        $models = if ($r.PSObject.Properties['Models'] -and $r.Models) { (@($r.Models) -join ' ') } else { '' }
        $effort = if ($null -ne $r.Effort) { [string]$r.Effort } else { '' }
        $extra  = if ($r.PSObject.Properties['ExtraArgs'] -and $r.ExtraArgs) { (@($r.ExtraArgs) -join ' ') } else { '' }
        ($r.Cli, $models, $effort, $extra) -join ([char]0x1F)
    }
    $canonical = $canonical + ([char]0x1E) + ($fbParts -join ([char]0x1E))
}
```

- [ ] **Step 4: Run and confirm pass**

Run: `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*fingerprint*'`
Expected: PASS (including the existing fingerprint tests and the back-compat test).

- [ ] **Step 5: Commit**

```bash
git add limitshift.ps1 tests/limitshift.Tests.ps1
git commit -m "feat(ps1): include fallbacks in the task fingerprint (no-fallbacks hash unchanged)"
```

### Task 3.2: Extend `get_task_fingerprint` (Bash, parity)

**Files:**
- Modify: `limitshift.sh` — `get_task_fingerprint` (lines ~1330-1351)
- Test: `tests/test-limitshift.sh`

- [ ] **Step 1: Write failing tests**

Add bash assertions that (a) a queue's fingerprint is stable across two runs (already covered by re-run/skip behavior) and (b) editing a fallback re-runs the task. Concretely: run `valid-fallbacks.json` to completion with a stub, then edit a fallback's model and confirm the task re-runs (use the existing re-run test pattern around test-limitshift.sh:937-995 as the template). Also add a back-compat assertion: a no-fallbacks queue produces the same done-fingerprint before and after this change (compare the stored fingerprint file content to a value captured from a no-fallbacks run).

- [ ] **Step 2: Run and confirm failure**

Run: `bash tests/test-limitshift.sh`
Expected: the "edit a fallback re-runs" assertion FAILS (fallbacks not in the hash yet).

- [ ] **Step 3: Implement the fallback contribution in `get_task_fingerprint`**

Mirror Task 3.1: append, only when `.tasks[i].fallbacks` is non-empty, a segment built from each fallback's `cli`, space-joined models, effort, and space-joined extraArgs, joined inside a bundle by the `0x1f` byte and between bundles by the `0x1e` byte. Use `printf '\037'` / `printf '\036'` for the separators to match the bytes used elsewhere (the existing field separator is already `0x1f`). Do **not** alter the string when there are no fallbacks.

- [ ] **Step 4: Run and confirm pass**

Run: `bash tests/test-limitshift.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add limitshift.sh tests/test-limitshift.sh
git commit -m "feat(sh): include fallbacks in the task fingerprint (no-fallbacks hash unchanged)"
```

---

## Phase 4 — Git-required validation

### Task 4.1: Require a git working tree for fallbacks tasks (PowerShell)

**Files:**
- Modify: `limitshift.ps1` — `Read-QueueConfig` (after a task with fallbacks is parsed) or `Test-QueuePreflight`
- Test: `tests/limitshift.Tests.ps1`

Spec: §6.2, §11. Check only fires when `fallbacks` is non-empty. Hard-fail when no `.git`; non-fatal warning when a git repo has no commits.

- [ ] **Step 1: Write failing tests**

```powershell
Context 'CLI rotation (fallbacks) — git requirement' {
    It 'rejects a fallbacks task whose projectPath is not a git repo' {
        $root = New-TestRoot
        $projectPath = Join-Path $root 'project'; New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
        $queuePath = Join-Path $root 'queue.json'
        Write-TestQueue -Path $queuePath -Config @{
            tasks = @(@{ name='t'; cli='claude'; projectPath=$projectPath; prompt='p';
                fallbacks=@(@{ cli='codex'; model='gpt-5.5' }) })
        }
        { Read-QueueConfig -Path $queuePath } | Should -Throw '*Task 1*fallbacks*not a git repository*'
    }

    It 'accepts a fallbacks task whose projectPath is a git repo' {
        $root = New-TestRoot
        $projectPath = Join-Path $root 'project'; New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
        git -C $projectPath init -q
        $queuePath = Join-Path $root 'queue.json'
        Write-TestQueue -Path $queuePath -Config @{
            tasks = @(@{ name='t'; cli='claude'; projectPath=$projectPath; prompt='p';
                fallbacks=@(@{ cli='codex'; model='gpt-5.5' }) })
        }
        { Read-QueueConfig -Path $queuePath } | Should -Not -Throw
    }

    It 'does not require git for a task without fallbacks' {
        # valid-minimal has no fallbacks and a non-git projectPath; must still load.
        { Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'valid-minimal.json') } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*git requirement*'`
Expected: the "rejects non-git" test FAILS (no check yet).

- [ ] **Step 3: Implement the git check**

Add a helper `Test-IsGitRepo -Path $p` that returns true when `git -C $p rev-parse --is-inside-work-tree` exits 0 (capture and suppress output). In `Read-QueueConfig`, after a task is parsed, if it has more than one runner (`$task.Runners.Count -gt 1`) and `-not (Test-IsGitRepo -Path $task.ProjectPath)`, throw `"Task $n uses fallbacks (CLI rotation), which needs version control so the next tool can see what the previous one did. projectPath is not a git repository: $($task.ProjectPath)"`. If it *is* a repo but `git -C $p rev-parse HEAD` fails (no commits), `Write-Warning`/`Write-Step` a non-fatal note pointing at the commit-baseline guidance (do not throw).

- [ ] **Step 4: Run and confirm pass**

Run: `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*git requirement*'`
Expected: PASS. (Skip note: if `git` is unavailable on the runner, the "accepts" test needs git installed — it is part of the toolchain here.)

- [ ] **Step 5: Commit**

```bash
git add limitshift.ps1 tests/limitshift.Tests.ps1
git commit -m "feat(ps1): require a git working tree for fallbacks tasks"
```

### Task 4.2: Require a git working tree for fallbacks tasks (Bash, parity)

**Files:**
- Modify: `limitshift.sh` — `read_queue_config` / `check_cli_binaries` path
- Test: `tests/test-limitshift.sh`

- [ ] **Step 1: Write failing tests**

Mirror Task 4.1: a fallbacks queue with a non-git `projectPath` fails `--validate-only` with `not a git repository`; the same queue with `git init` in the project dir passes; a no-fallbacks queue is unaffected.

- [ ] **Step 2: Run and confirm failure** — `bash tests/test-limitshift.sh` (new git assertions FAIL).

- [ ] **Step 3: Implement** — add `is_git_repo() { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; }`; in `read_queue_config`, when a task's runner count > 1 and `! is_git_repo "$project_path"`, print the same error and exit non-zero. Warn (non-fatal) when the repo has no `HEAD`.

- [ ] **Step 4: Run and confirm pass** — `bash tests/test-limitshift.sh`.

- [ ] **Step 5: Commit**

```bash
git add limitshift.sh tests/test-limitshift.sh
git commit -m "feat(sh): require a git working tree for fallbacks tasks"
```

---

## Phase 5 — Handoff note

### Task 5.1: Handoff-note constant and prompt builder (PowerShell)

**Files:**
- Modify: `limitshift.ps1` — near `Get-CompletionMarkerInstructions` / `Get-TaskPromptWithCompletionMarker` (lines ~1352-1393)
- Test: `tests/limitshift.Tests.ps1`

Spec: §6.1. Exact, canonical text emitted verbatim by both scripts.

- [ ] **Step 1: Write failing tests**

```powershell
Context 'CLI rotation (fallbacks) — handoff note' {
    It 'prepends the exact handoff note in completion-check mode' {
        $task = [pscustomobject]@{ Name='t'; Cli='codex'; ProjectPath='C:\p'; Model=$null; Effort=$null; Prompt='do the thing'; ExtraArgs=@(); CompletionCheck=$true }
        $p = Get-TaskPromptWithHandoff -Task $task
        $p | Should -Match 'A previous AI tool started this task and was interrupted'
        $p | Should -Match 'git status'
        $p | Should -Match 'git diff'
        $p | Should -Match '\[\[TASK_COMPLETE\]\]'
        $p | Should -Match 'do the thing'
    }
    It 'omits the marker sentence in simple mode but keeps the git instruction' {
        $task = [pscustomobject]@{ Name='t'; Cli='codex'; ProjectPath='C:\p'; Model=$null; Effort=$null; Prompt='do the thing'; ExtraArgs=@(); CompletionCheck=$false }
        $p = Get-TaskPromptWithHandoff -Task $task
        $p | Should -Match 'git status'
        $p | Should -Not -Match '\[\[TASK_COMPLETE\]\]'
    }
}
```

- [ ] **Step 2: Run and confirm failure** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*handoff note*'` (function missing).

- [ ] **Step 3: Implement the constant and builder**

```powershell
$script:HandoffNoteBase = @'
A previous AI tool started this task and was interrupted (usage limit or failure). Partial work may already exist in the working tree. Before doing anything, inspect both `git status` (for new/untracked files) and `git diff` (for changes to tracked files) to see what has already been done. Continue from there; do not redo finished work.
'@

function Get-TaskPromptWithHandoff {
    param($Task)
    $base = Get-TaskPromptWithCompletionMarker -Task $Task   # existing: prompt (+marker block if completionCheck)
    return $script:HandoffNoteBase + "`n`n" + $base
}
```
(The marker sentence is already inside `Get-TaskPromptWithCompletionMarker` when `CompletionCheck` is true, so the simple-mode variant is handled automatically.)

- [ ] **Step 4: Run and confirm pass** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*handoff note*'`.

- [ ] **Step 5: Commit**

```bash
git add limitshift.ps1 tests/limitshift.Tests.ps1
git commit -m "feat(ps1): add the cross-tool handoff note"
```

### Task 5.2: Handoff-note constant and prompt builder (Bash, parity)

**Files:**
- Modify: `limitshift.sh` — near the completion-marker prompt builders
- Test: `tests/test-limitshift.sh`

- [ ] **Step 1: Write failing test** — assert that a runner-switch run's stdin (captured by a stub) contains the exact handoff sentence and `git status`/`git diff` (use the stdin-capture stub pattern from test-limitshift.sh:691).
- [ ] **Step 2: Run and confirm failure** — `bash tests/test-limitshift.sh`.
- [ ] **Step 3: Implement** — add `HANDOFF_NOTE_BASE` with the **identical** text and a `build_prompt_with_handoff <i>` that prepends it to the existing completion-marker prompt builder output.
- [ ] **Step 4: Run and confirm pass** — `bash tests/test-limitshift.sh`.
- [ ] **Step 5: Commit**

```bash
git add limitshift.sh tests/test-limitshift.sh
git commit -m "feat(sh): add the cross-tool handoff note"
```

---

## Phase 6 — Reset-time capture (`limitedUntil`)

### Task 6.1: Compute a runner's reset time on a limit (PowerShell)

**Files:**
- Modify: `limitshift.ps1` — add a helper near `Get-ResetTimeFromErrorText` (line ~2156) and `Get-ClaudeUsage` (line ~1209)
- Test: `tests/limitshift.Tests.ps1`

Spec: §5.6. Non-Claude: parse the error; fall back to `now + limitWaitMinutes`. Claude: read `SessionReset`/`WeekReset` from `Get-ClaudeUsage`.

- [ ] **Step 1: Write failing tests**

```powershell
Context 'CLI rotation (fallbacks) — reset time' {
    It 'parses a reset time from a non-claude limit error' {
        $r = Get-RunnerResetTime -Cli 'gemini' -ErrorText 'Quota exceeded. Try again in 2h 0m.' -LimitWaitMinutes 30
        ($r - (Get-Date)).TotalMinutes | Should -BeGreaterThan 100
    }
    It 'falls back to limitWaitMinutes when no reset is parseable' {
        $r = Get-RunnerResetTime -Cli 'codex' -ErrorText 'rate limit, no time here' -LimitWaitMinutes 30
        ($r - (Get-Date)).TotalMinutes | Should -BeGreaterThan 25
        ($r - (Get-Date)).TotalMinutes | Should -BeLessThan 35
    }
}
```

- [ ] **Step 2: Run and confirm failure** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*reset time*'`.

- [ ] **Step 3: Implement `Get-RunnerResetTime`**

```powershell
function Get-RunnerResetTime {
    param([string]$Cli, [string]$ErrorText, [int]$LimitWaitMinutes, $ClaudeUsage)
    if ($Cli -eq 'claude' -and $null -ne $ClaudeUsage) {
        if ($ClaudeUsage.WeekReset)    { return $ClaudeUsage.WeekReset }
        if ($ClaudeUsage.SessionReset) { return $ClaudeUsage.SessionReset }
    }
    $parsed = Get-ResetTimeFromErrorText -ErrorText $ErrorText
    if ($null -ne $parsed) { return $parsed }
    return (Get-Date).AddMinutes($LimitWaitMinutes)
}
```
(For Claude, the loop passes the `Get-ClaudeUsage` result as `-ClaudeUsage`; see Task 7.3.)

- [ ] **Step 4: Run and confirm pass** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*reset time*'`.

- [ ] **Step 5: Commit**

```bash
git add limitshift.ps1 tests/limitshift.Tests.ps1
git commit -m "feat(ps1): compute a runner reset time for soonest-reset rotation"
```

### Task 6.2: Compute a runner's reset time on a limit (Bash, parity)

**Files:**
- Modify: `limitshift.sh` — near `parse_reset_from_error` (1242) and `get_claude_usage` (1135)
- Test: `tests/test-limitshift.sh`

- [ ] **Step 1: Write failing test** — drive a 2-runner gemini→codex queue where runner 0 limits with "Try again in 0s" and assert the soonest-reset path picks the runner whose reset passed (this is mostly exercised in Phase 7; here add a focused unit-style check via a small stub if practical, else defer the assertion to Task 7.4).
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement `get_runner_reset_epoch <cli> <error_text> <wait_minutes>`** mirroring Task 6.1, returning an epoch seconds value (`parse_reset_from_error` already yields one via `$R_RESET`); for claude, read the parsed `get_claude_usage` reset.
- [ ] **Step 4: Run and confirm pass.**
- [ ] **Step 5: Commit**

```bash
git add limitshift.sh tests/test-limitshift.sh
git commit -m "feat(sh): compute a runner reset time for soonest-reset rotation"
```

---

## Phase 7 — Runner selection + rotation loop

### Task 7.1: Runner-selection helper (PowerShell)

**Files:**
- Modify: `limitshift.ps1` — add `Select-NextRunner`
- Test: `tests/limitshift.Tests.ps1`

Spec: §5.5, §5.6. Pure function over runner state so it is unit-testable.

- [ ] **Step 1: Write failing tests**

```powershell
Context 'CLI rotation (fallbacks) — runner selection' {
    # Each runner state: @{ SetAside=$bool; LimitedUntil=[datetime] or $null }
    It 'picks the first runner that is not set aside and not still-limited, scanning from the current index' {
        $states = @(
            @{ SetAside=$true;  LimitedUntil=$null },
            @{ SetAside=$false; LimitedUntil=(Get-Date).AddHours(1) },
            @{ SetAside=$false; LimitedUntil=$null }
        )
        $r = Select-NextRunner -States $states -StartIndex 0 -Now (Get-Date)
        $r.Action | Should -Be 'Run'
        $r.Index  | Should -Be 2
    }
    It 'returns Wait with the soonest within-24h reset when nothing is runnable' {
        $now = Get-Date
        $states = @(
            @{ SetAside=$false; LimitedUntil=$now.AddHours(3) },
            @{ SetAside=$false; LimitedUntil=$now.AddHours(1) }
        )
        $r = Select-NextRunner -States $states -StartIndex 0 -Now $now
        $r.Action | Should -Be 'Wait'
        $r.Index  | Should -Be 1
        ($r.WaitUntil - $now).TotalMinutes | Should -BeGreaterThan 55
    }
    It 'returns Fail when every live runner resets more than 24h out' {
        $now = Get-Date
        $states = @( @{ SetAside=$false; LimitedUntil=$now.AddHours(48) } )
        (Select-NextRunner -States $states -StartIndex 0 -Now $now).Action | Should -Be 'Fail'
    }
    It 'returns Fail when every runner is set aside' {
        $states = @( @{ SetAside=$true; LimitedUntil=$null }, @{ SetAside=$true; LimitedUntil=$null } )
        (Select-NextRunner -States $states -StartIndex 0 -Now (Get-Date)).Action | Should -Be 'Fail'
    }
}
```

- [ ] **Step 2: Run and confirm failure** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*runner selection*'`.

- [ ] **Step 3: Implement `Select-NextRunner`**

```powershell
function Select-NextRunner {
    param([object[]]$States, [int]$StartIndex, [datetime]$Now)
    $count = $States.Count
    for ($k = 0; $k -lt $count; $k++) {
        $i = ($StartIndex + $k) % $count
        $s = $States[$i]
        if ($s.SetAside) { continue }
        if ($null -ne $s.LimitedUntil -and $s.LimitedUntil -gt $Now) { continue }
        return @{ Action = 'Run'; Index = $i }
    }
    # Nothing runnable: consider live (not set aside) runners with a reset within 24h.
    $waitable = @()
    for ($i = 0; $i -lt $count; $i++) {
        $s = $States[$i]
        if (-not $s.SetAside -and $null -ne $s.LimitedUntil -and ($s.LimitedUntil - $Now).TotalHours -le 24) {
            $waitable += @{ Index = $i; At = $s.LimitedUntil }
        }
    }
    if ($waitable.Count -eq 0) { return @{ Action = 'Fail' } }
    $soonest = $waitable | Sort-Object { $_.At } | Select-Object -First 1
    return @{ Action = 'Wait'; Index = $soonest.Index; WaitUntil = $soonest.At }
}
```

- [ ] **Step 4: Run and confirm pass** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*runner selection*'`.

- [ ] **Step 5: Commit**

```bash
git add limitshift.ps1 tests/limitshift.Tests.ps1
git commit -m "feat(ps1): add the runner-selection rule (skip not-yet-reset, wait soonest within 24h)"
```

### Task 7.2: Runner-selection helper (Bash, parity)

**Files:**
- Modify: `limitshift.sh` — add `select_next_runner`
- Test: `tests/test-limitshift.sh`

- [ ] **Step 1: Write failing test** — drive `select_next_runner` via small fixtures: encode runner states as parallel arrays (`setaside[]`, `limited_until[]` epoch) and assert it echoes `RUN <i>`, `WAIT <i> <epoch>`, or `FAIL`. (If the bash harness can't easily unit-test internal functions, assert the behavior through the end-to-end tests in Task 7.4 and keep this task's logic minimal.)
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement `select_next_runner`** mirroring Task 7.1 using epoch-second comparisons and `now=$(date +%s)`.
- [ ] **Step 4: Run and confirm pass.**
- [ ] **Step 5: Commit**

```bash
git add limitshift.sh tests/test-limitshift.sh
git commit -m "feat(sh): add the runner-selection rule (skip not-yet-reset, wait soonest within 24h)"
```

### Task 7.3: Rewire the task loop to rotate runners (PowerShell)

**Files:**
- Modify: `limitshift.ps1` — `run` task loop (lines ~2509-2720): per-runner config, limit/error/stall handling, pre-check, session reset, handoff note, soft maxRunsPerTask
- Test: `tests/limitshift.Tests.ps1` — new end-to-end `Context`

Spec: §5.2–§5.8, §7, §8. **Back-compat:** a no-fallbacks task (`Runners.Count -eq 1`) must take the existing code paths unchanged.

- [ ] **Step 1: Write failing end-to-end tests** (follow the stub-CLI pattern from the existing "Model rotation — end-to-end" context)

```powershell
Context 'CLI rotation (fallbacks) — end-to-end' {
    It 'switches from runner 0 to runner 1 on a limit, fresh session + handoff note' {
        # gemini stub (runner 0) always limits; codex stub (runner 1) succeeds and records its stdin.
        # Assert: output contains 'switching to codex'; codex stdin contains the handoff note;
        # task completes; runner index file == 1.
    }
    It 'switches to the next runner after a persistent error (retries exhausted)' {
        # runner 0 stub exits non-zero with a non-limit error every time; maxRetriesOnError=1;
        # runner 1 succeeds. Assert switch happened after 2 runner-0 attempts; task done.
    }
    It 'does NOT switch on [[TASK_BLOCKED]]; fails per stopOnError' {
        # runner 0 returns [[TASK_BLOCKED]] no key; stopOnError=false; runner 1 never invoked.
        # Assert runner 1 stub log is empty and the task is marked failed.
    }
    It 'a no-fallbacks task still waits-and-resumes on a single-model limit (back-compat)' {
        # mirror the existing single-string-model test; assert 'switching to' is absent.
    }
    It 'when all runners are limited, waits for the soonest reset and resumes that runner' {
        # runner 0 limits "try again in 0s"; runner 1 limits "try again in 0s"; on the next cycle
        # the soonest (0s) runner runs and succeeds. Assert 'Hit a usage limit' then 'Task 1 done'.
    }
}
```
Write the stub CLIs and queues using the existing helpers; model each stub after the gemini stub at lines 854-866 (read stdin, inspect args, emit JSON, exit code). Use `projectPath` = a `git init`-ed temp dir (fallbacks require git, Phase 4).

- [ ] **Step 2: Run and confirm failure** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*fallbacks*end-to-end*'`.

- [ ] **Step 3: Implement the loop changes**

Replace the single-runner model-rotation bookkeeping with runner-aware state. Concretely:
- Build `$runners = @($task.Runners)`; `$runnerCount = $runners.Count`.
- Initialize per-runner state arrays: `$setAside` (all `$false`), `$limitedUntil` (all `$null`), and a per-runner saved model index. Restore the persisted **runner index** (Task 9.1) and that runner's model index.
- At the top of each iteration, if not already positioned, call `Select-NextRunner -States ... -StartIndex $currentRunnerIndex -Now (Get-Date)`:
  - `Run` → set `$currentRunnerIndex = Index`. If it changed since the last run, this is a **runner switch**: clear the saved session id, reset `$errorRetryCount=0`, `$stallCount=0`, `$previousNoMarkerText=$null`, set a `$pendingHandoff=$true` flag, and persist the new runner index.
  - `Wait` → `Wait-ForRunnerReset -Until WaitUntil` (sleep using the existing rest UI; see below), clear that runner's `LimitedUntil`, then re-select.
  - `Fail` → mark the task failed with the aggregate reason (§5.7) and break.
- The active runner's config comes from `$runners[$currentRunnerIndex]` (`Cli`/`Models`/`Effort`/`ExtraArgs`). The `$currentModel` is `Models[currentModelIndexForThisRunner]`.
- **Pre-check (per runner, §8):** the existing `Wait-UntilClaudeUsageReady` call must become runner-scoped. When `$runnerCount -eq 1` (no fallbacks) keep today's exact call. When there are fallbacks AND the current runner is cloud claude (`-not Test-IsOllamaRunner`), call `Get-ClaudeUsage`; if capped, set this runner's `LimitedUntil` from `Get-RunnerResetTime ... -ClaudeUsage`, mark it limited, and `continue` (the next loop pass re-selects, switching to a fallback instead of waiting). A local-Ollama runner never pre-checks and never gets a `LimitedUntil`.
- **Prompt:** when `$pendingHandoff`, build the New-mode prompt via `Get-TaskPromptWithHandoff`; otherwise the existing prompt builders. Clear `$pendingHandoff` after use.
- **Outcome handling (replace the existing `if ($result.IsLimit)` block):**
  - Limit: rotate model within the runner exactly as today; **only when the runner's models are exhausted**, set `$limitedUntil[$currentRunnerIndex] = Get-RunnerResetTime ...`, reset that runner's model index to 0, and `continue` (re-select).
  - Error: existing retry up to `maxRetriesOnError`; when exhausted, `$setAside[$currentRunnerIndex] = $true`, record the per-runner reason, and `continue`.
  - Stall: when `maxStalls` reached, if `$runnerCount -gt 1` set `$setAside[$currentRunnerIndex] = $true`, record reason, `continue`; **else** keep today's fail-the-task behavior.
  - Blocked / Done: unchanged (Blocked never switches).
- **maxRunsPerTask (§5.8):** when `$runnerCount -gt 1`, on exceeding the cap, mark the task failed with a "run budget exhausted" reason and honor `stopOnError` (do not `throw` unconditionally). No-fallbacks tasks keep the existing `throw`.
- **Aggregate failure reason (§5.7):** when failing after all runners are set aside / unwaitable, compose a reason listing each runner's cli/model and its terminal outcome.

Add `Wait-ForRunnerReset` as a thin wrapper over the existing rest UI (`Invoke-UiRestWithSummary`) that takes a target `DateTime`; for fallbacks tasks the >24h case never reaches it (the selector filters it), so it never throws.

- [ ] **Step 4: Run and confirm pass** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*fallbacks*end-to-end*'`.

- [ ] **Step 5: Run the full suite** — `Invoke-Pester tests/limitshift.Tests.ps1` (all existing + new PASS).

- [ ] **Step 6: Commit**

```bash
git add limitshift.ps1 tests/limitshift.Tests.ps1
git commit -m "feat(ps1): rotate runners on limit/persistent-failure with soonest-reset waiting"
```

### Task 7.4: Rewire the task loop to rotate runners (Bash, parity)

**Files:**
- Modify: `limitshift.sh` — `run_queue` (lines ~1999-2170), `is_ollama_task` (add a runner-scoped variant), `wait_for_limit_reset`
- Test: `tests/test-limitshift.sh`

- [ ] **Step 1: Write failing end-to-end tests** mirroring Task 7.3 (switch on limit + handoff note in stdin; switch on persistent error; no-switch on `[[TASK_BLOCKED]]`; no-fallbacks back-compat; soonest-reset resume). Use the existing stub + `PATH=` pattern; `git init` the project dir.
- [ ] **Step 2: Run and confirm failure** — `bash tests/test-limitshift.sh`.
- [ ] **Step 3: Implement the same loop logic in `run_queue`** using parallel arrays for `setaside`/`limited_until`, runner-scoped config lookups (Task 2.2 helpers), `select_next_runner` (Task 7.2), the runner-scoped pre-check/Ollama gate, the handoff prompt builder (Task 5.2), and the soft `maxRunsPerTask` for fallbacks tasks. Keep the no-fallbacks path identical to today.
- [ ] **Step 4: Run and confirm pass** — `bash tests/test-limitshift.sh`.
- [ ] **Step 5: Commit**

```bash
git add limitshift.sh tests/test-limitshift.sh
git commit -m "feat(sh): rotate runners on limit/persistent-failure with soonest-reset waiting"
```

---

## Phase 8 — runs.csv columns

### Task 8.1: Add `cli` and `model` columns to runs.csv (PowerShell)

**Files:**
- Modify: `limitshift.ps1` — `$RunsCsvHeader` (line 76), `Add-RunsCsvRow` (lines ~686-706) and its call site (~2608)
- Test: `tests/limitshift.Tests.ps1`

Spec: §12.

- [ ] **Step 1: Write failing test** — assert the header is `timestamp,task,run,mode,exit,status,cli,model` and that `Add-RunsCsvRow -Cli 'codex' -Model 'gpt-5.5' ...` writes those values (read back the CSV line).
- [ ] **Step 2: Run and confirm failure** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*runs.csv*'`.
- [ ] **Step 3: Implement** — extend the header constant, add `-Cli`/`-Model` params to `Add-RunsCsvRow` (CSV-escaped via `ConvertTo-CsvField`), and pass the active runner's cli + current model at the call site.
- [ ] **Step 4: Run and confirm pass** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*runs.csv*'`.
- [ ] **Step 5: Commit**

```bash
git add limitshift.ps1 tests/limitshift.Tests.ps1
git commit -m "feat(ps1): record cli and model columns in runs.csv"
```

### Task 8.2: Add `cli` and `model` columns to runs.csv (Bash, parity)

**Files:**
- Modify: `limitshift.sh` — `RUNS_CSV_HEADER` (line 1955), `add_runs_csv_row` (1880), call site (~run_queue)
- Test: `tests/test-limitshift.sh`

- [ ] **Step 1: Write failing test** — assert the bash runs.csv header and a row include cli+model.
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement** mirroring Task 8.1 (`csv_field` for escaping).
- [ ] **Step 4: Run and confirm pass.**
- [ ] **Step 5: Commit**

```bash
git add limitshift.sh tests/test-limitshift.sh
git commit -m "feat(sh): record cli and model columns in runs.csv"
```

---

## Phase 9 — State persistence (runner index + per-runner model index)

### Task 9.1: Persist runner index and per-runner model index (PowerShell)

**Files:**
- Modify: `limitshift.ps1` — model-index file helpers (lines ~1074-1098); the re-run invalidation block (~2530-2533)
- Test: `tests/limitshift.Tests.ps1`

Spec: §7. Only created when the task has fallbacks.

- [ ] **Step 1: Write failing tests** — (a) after a runner switch, a `task-NN-runner-index.txt` file holds the current runner index; (b) the model-index file is scoped per runner (e.g. `task-NN-runner-1-model-index.txt`); (c) a changed task (edited fallback) drops both files on re-run; (d) a no-fallbacks task creates **no** runner-index file (back-compat).
- [ ] **Step 2: Run and confirm failure** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*runner index*'`.
- [ ] **Step 3: Implement** — add `Get-TaskRunnerIndexFilePath` / `Get-SavedTaskRunnerIndex` / `Save-TaskRunnerIndex` mirroring the existing model-index helpers; change the model-index path to include the runner index; create these only when `Runners.Count -gt 1`; in the re-run invalidation block, also remove the runner-index and per-runner model-index files.
- [ ] **Step 4: Run and confirm pass** — `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*runner index*'`.
- [ ] **Step 5: Commit**

```bash
git add limitshift.ps1 tests/limitshift.Tests.ps1
git commit -m "feat(ps1): persist runner index and per-runner model index"
```

### Task 9.2: Persist runner index and per-runner model index (Bash, parity)

**Files:**
- Modify: `limitshift.sh` — `get_task_model_index_file_path` (1370) and the re-run reset block (~2048)
- Test: `tests/test-limitshift.sh`

- [ ] **Step 1: Write failing tests** mirroring Task 9.1.
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement** `get_task_runner_index_file_path` / `get_saved_task_runner_index` / `save_task_runner_index` and the runner-scoped model-index path; drop both on re-run; create only for fallbacks tasks.
- [ ] **Step 4: Run and confirm pass.**
- [ ] **Step 5: Commit**

```bash
git add limitshift.sh tests/test-limitshift.sh
git commit -m "feat(sh): persist runner index and per-runner model index"
```

---

## Phase 10 — Example and documentation

### Task 10.1: Add a CLI-rotation example queue

**Files:**
- Modify: `limitshift-queue.example-advanced.json`

- [ ] **Step 1: Add a task using `fallbacks`** — a realistic claude→codex→gemini rotation with per-tool permission flags and a model array on at least one runner; `projectPath` a placeholder absolute path consistent with the other examples; `completionCheck: true`.
- [ ] **Step 2: Validate the example** — `powershell -NoProfile -File limitshift.ps1 -QueuePath limitshift-queue.example-advanced.json -ValidateOnly` (a non-git placeholder path will trip the git check; if so, document in the example a comment-free note in the README that rotation needs git, and point the example's `projectPath` at a path the user replaces — OR keep the example's rotation task `projectPath` as the repo root `.` so validation passes in-repo). Confirm `Config OK`.
- [ ] **Step 3: Commit**

```bash
git add limitshift-queue.example-advanced.json
git commit -m "docs(example): add a CLI rotation (fallbacks) example"
```

### Task 10.2: README + README.uk "CLI rotation" section

**Files:**
- Modify: `README.md` (Features, near "Model rotation" §265; Roadmap §320), `README.uk.md` (parity)

- [ ] **Step 1: Write a "CLI rotation" subsection** describing: the `fallbacks` field with a JSON example; switch-on-limit-or-persistent-failure (not on `[[TASK_BLOCKED]]`); soonest-reset waiting; the **git requirement** and commit-before-rotation advice; link to `STRATEGIES.md`. Add a one-line entry to the feature bullet list near line 80.
- [ ] **Step 2: Mark the roadmap item done** — change the `- [ ]` CLI-rotation roadmap line (§320) to `- [x]` (or remove it from Roadmap and fold into Features).
- [ ] **Step 3: Mirror the same edits in `README.uk.md`** (Ukrainian translation).
- [ ] **Step 4: Commit**

```bash
git add README.md README.uk.md
git commit -m "docs(readme): document CLI rotation and mark the roadmap item done"
```

### Task 10.3: AGENTS.md fallbacks guidance

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Add a "CLI rotation (fallbacks)" subsection** covering: the `fallbacks` shape; each fallback carries its **own** permission flag; use a **model array on one runner** for same-tool variation and reserve `fallbacks` for different tools (spec §5.3); the git requirement; that `[[TASK_BLOCKED]]` stops without switching. Add `fallbacks` to the "Useful optional fields" list.
- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs(agents): how to build a fallbacks (CLI rotation) task"
```

### Task 10.4: REFERENCE.md fallbacks reference

**Files:**
- Modify: `REFERENCE.md`

- [ ] **Step 1: Document the `fallbacks` field and rotation behavior** (the five outcomes, soonest-reset, git requirement, runs.csv cli/model columns, per-runner state files).
- [ ] **Step 2: Commit**

```bash
git add REFERENCE.md
git commit -m "docs(reference): document the fallbacks field and rotation behavior"
```

### Task 10.5: Create STRATEGIES.md

**Files:**
- Create: `STRATEGIES.md`
- Modify: `README.md` / `README.uk.md` (link to it from the Documentation table)

Spec: §14.

- [ ] **Step 1: Write `STRATEGIES.md`** with sections: writing high-quality prompts (seed from AGENTS.md "Prompt Quality Bar", §121-136); commit-before-rotation rule and why git is required; choosing models and tools; completion-check vs simple mode; the `maxRunsPerTask` budget for rotation tasks (`runs ≈ Σ over runners [models + retries + stalls + progress-resumes]`, recommend ≥ 10×runner count); example workflows (overnight rotation, review→fix→verify with rotation).
- [ ] **Step 2: Link it** from the README Documentation table (and the README.uk equivalent).
- [ ] **Step 3: Commit**

```bash
git add STRATEGIES.md README.md README.uk.md
git commit -m "docs: add STRATEGIES.md guide and link it from the README"
```

---

## Phase 11 — Final verification

### Task 11.1: Full suites + example validation

**Files:** none (verification only)

- [ ] **Step 1: Run the full PowerShell suite**

Run: `Invoke-Pester tests/limitshift.Tests.ps1`
Expected: all tests PASS.

- [ ] **Step 2: Run the full bash suite**

Run: `bash tests/test-limitshift.sh`
Expected: all tests PASS.

- [ ] **Step 3: Validate the representative queues in both runners**

Run: `powershell -NoProfile -File limitshift.ps1 -QueuePath limitshift-queue.example-advanced.json -ValidateOnly`
Run: `bash limitshift.sh --queue limitshift-queue.example-advanced.json --validate-only`
Expected: both print `Config OK`.

- [ ] **Step 4: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "chore: verify CLI rotation across both runners and example queues"
```

---

## Self-review checklist (run before handing off)

- **Spec coverage:** §5.1 `fallbacks` shape → Tasks 1.1/2.x; §5.2–5.4 outcomes → 7.3/7.4; §5.5–5.6 selection/soonest-reset/>24h → 6.x/7.1/7.2/7.3; §6 handoff + git → 4.x/5.x; §7 session/state → 7.3/7.4/9.x; §8 pre-check per runner → 7.3/7.4; §9 fingerprint → 3.x; §11 validation → 1.1/2.x/4.x; §12 runs.csv → 8.x; §14 docs/STRATEGIES → 10.x.
- **Back-compat:** no-fallbacks fingerprint identical (3.1 Step 1); no-fallbacks stall still fails (7.3 Step 1); no-fallbacks Claude pre-check unchanged (7.3 Step 3); no runner-index file for no-fallbacks tasks (9.1 Step 1).
- **Name consistency:** `Runners`, `Select-NextRunner`, `Get-RunnerResetTime`, `Get-TaskPromptWithHandoff`, `Get-TaskRunnerIndexFilePath` (ps1) ↔ `select_next_runner`, `get_runner_reset_epoch`, `build_prompt_with_handoff`, `get_task_runner_index_file_path` (sh) used consistently across tasks.
