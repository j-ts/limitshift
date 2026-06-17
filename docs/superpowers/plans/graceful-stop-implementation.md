# Graceful Stop ("press s") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user press `s` (or `S`) while LimitShift runs to stop it cleanly *after the current step finishes* — so they can restart without killing work mid-prompt — with a reminder line shown at the bottom while it works and gone when it ends.

**Architecture:** A single **stop-flag file** in the queue's state folder is the internal signal. While a CLI runs, the existing spinner poll-loop (and the usage-limit rest loop) also watch the keyboard; on `s`/`S` they create the flag file and switch the reminder text to "stopping…". The main task loop checks the flag at each safe boundary (after a reply returns / before the next prompt or task) and, if set, prints a stop message and breaks out to the normal end-of-run summary (which releases the lock). The keyboard watch only activates on an interactive console; everywhere else (tests, pipes) the feature is inert, and the *flag file* is what the test suite drives to exercise the stop path without a TTY.

**Tech Stack:** PowerShell 5.1 (`limitshift.ps1`, Pester tests in `tests/limitshift.Tests.ps1`), Bash (`limitshift.sh`, custom harness in `tests/test-limitshift.sh`).

**Design notes (de-facto spec):**
- "After the current step" = after the in-flight CLI reply returns (the only between-actions moment). If that leaves a task not-yet-`[[TASK_COMPLETE]]`, the task is simply not marked done and resumes on the next run — nothing is lost.
- The reminder rides on the existing in-place spinner/rest line (the bottom-most active line), so it is erased by those loops' existing cleanup when work ends ("simple" reminder option; a fully pinned bottom row is out of scope).
- `s` is honored during a usage-limit wait too (it aborts the wait and stops).
- The keypress→flag wiring is the only piece that needs **manual** verification (no headless way to inject console keys); every other behavior is covered by automated tests that create the flag file directly.

**Conventions:** Run ps1 tests `Invoke-Pester tests/limitshift.Tests.ps1`; bash tests `bash tests/test-limitshift.sh`. Commit after each task with the shown message. Mirror every behavior in both runners.

---

## File structure

- `limitshift.ps1` — add stop-flag path + hint constants + `Test-StopRequested`/`Request-Stop`/`Get-StopHint`; clear the flag at startup; poll keys in `Invoke-UiSpinner` and `Invoke-UiRest`; check the flag in the main loop; remove the flag on clean exit.
- `limitshift.sh` — mirror: `STOP_FLAG` path + hint vars + `request_stop`/`stop_requested`; clear at startup; poll keys in the spinner subshell and `ui_rest`; check in `run_queue`; remove on exit.
- `tests/limitshift.Tests.ps1` — unit test for `Get-StopHint`; end-to-end test driving the flag file via a stub.
- `tests/test-limitshift.sh` — same end-to-end test in bash.

---

## Phase 1 — ps1 stop-signal foundation

### Task 1: Flag path, hint constants, and helper functions (ps1)

**Files:**
- Modify: `limitshift.ps1` — near the other glyph/`$script:` UI constants (around lines 95-110) and near the state-path setup (where `$RunnerStatePath`/`$LogPath` are defined, around lines 61-73)
- Test: `tests/limitshift.Tests.ps1`

- [ ] **Step 1: Write the failing unit test**

Add a new `Context` to `tests/limitshift.Tests.ps1`:
```powershell
Context 'Graceful stop (press s) — hint text' {
    It 'returns the active hint by default' {
        Get-StopHint | Should -Be ('Ctrl+C stop now ' + [char]0x00B7 + ' s stop after this task')
    }
    It 'returns the armed hint once stop is requested' {
        Get-StopHint -Armed | Should -Be ('stopping after this task' + [char]0x2026)
    }
}
```

- [ ] **Step 2: Run it and confirm failure**

Run: `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*press s*hint*'`
Expected: FAIL ("Get-StopHint" not recognized).

- [ ] **Step 3: Implement the constants, path, and helpers**

Add the hint constants beside the other `$script:Glyph*` constants (after line ~103):
```powershell
$script:StopHintActive = 'Ctrl+C stop now ' + [char]0x00B7 + ' s stop after this task'
$script:StopHintArmed  = 'stopping after this task' + [char]0x2026
```

Add the flag path beside `$LogPath` (after line ~69, inside the same state-path block so `$RunnerStatePath` exists):
```powershell
$StopFlagPath = Join-Path $RunnerStatePath 'stop-after-step.flag'
```

Add the helper functions (near the other small UI helpers, after `Test-UiAnimatable` ~line 111):
```powershell
function Get-StopHint {
    param([switch]$Armed)
    if ($Armed) { return $script:StopHintArmed }
    return $script:StopHintActive
}

function Test-StopRequested {
    # The single source of truth for "the user asked to stop after this step."
    if ([string]::IsNullOrWhiteSpace($script:__StopFlagPath)) { return $false }
    return (Test-Path -LiteralPath $script:__StopFlagPath)
}

function Request-Stop {
    # Called by the key watchers when 's'/'S' is pressed. Idempotent.
    if ([string]::IsNullOrWhiteSpace($script:__StopFlagPath)) { return }
    if (-not (Test-Path -LiteralPath $script:__StopFlagPath)) {
        try { Set-Content -LiteralPath $script:__StopFlagPath -Value 's' -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    }
}
```
Note: `Test-StopRequested`/`Request-Stop` read `$script:__StopFlagPath`. Set it once where the run begins (where `$StopFlagPath` is computed): `$script:__StopFlagPath = $StopFlagPath`. (`-LoadFunctionsOnly` test runs leave it `$null`, so the helpers no-op safely — that is why the unit test only covers `Get-StopHint`.)

- [ ] **Step 4: Run it and confirm pass**

Run: `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*press s*hint*'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add limitshift.ps1 tests/limitshift.Tests.ps1
git commit -m "feat(ps1): add graceful-stop flag path, hint text, and helpers"
```

### Task 2: Compute the keyboard-readable guard and clear the flag at startup (ps1)

**Files:**
- Modify: `limitshift.ps1` — the startup/state-init region (where `$script:__StopFlagPath` is set, and the runner state folder is initialized)

- [ ] **Step 1: Implement the guard + startup clear**

Where the run initializes (right after `$script:__StopFlagPath = $StopFlagPath`), add:
```powershell
# Can we read single keys? Only on an interactive console with non-redirected input.
$script:CanReadStopKey = $false
try {
    if (-not [Console]::IsInputRedirected) { $null = [Console]::KeyAvailable; $script:CanReadStopKey = $true }
} catch { $script:CanReadStopKey = $false }

# A stale flag from a previous run must never auto-stop a fresh run.
Remove-Item -LiteralPath $StopFlagPath -Force -ErrorAction SilentlyContinue
```
(Place this after `$RunnerStatePath` is created/migrated so the folder exists; if the folder is created later, move the `Remove-Item` to just after creation.)

- [ ] **Step 2: Add a helper to drain pending keypresses (used by both loops)**

Add near `Get-StopHint`:
```powershell
function Read-StopKey {
    # Drain buffered keys; if any is 's'/'S', request stop. Safe to call every poll tick.
    if (-not $script:CanReadStopKey) { return }
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.KeyChar -eq 's' -or $k.KeyChar -eq 'S') { Request-Stop }
        }
    } catch {}
}
```

- [ ] **Step 3: Sanity-check the script still loads**

Run: `powershell -NoProfile -Command ". ./limitshift.ps1 -LoadFunctionsOnly; 'loaded'"`
Expected: prints `loaded` (no parse error).

- [ ] **Step 4: Commit**

```bash
git add limitshift.ps1
git commit -m "feat(ps1): key-read guard and startup clear for graceful stop"
```

---

## Phase 2 — Hook the ps1 poll loops

### Task 3: Watch keys + show the reminder in the spinner (ps1)

**Files:**
- Modify: `limitshift.ps1` — `Invoke-UiSpinner` (lines 334-381)

- [ ] **Step 1: Add the keypress poll + reminder to the spinner loop**

Inside the `while (-not $Process.HasExited)` loop, just before `$pos += $dir` (after the existing `[Console]::Write` block, ~line 371), add the key drain and reminder render:
```powershell
            Read-StopKey
            $armed = Test-StopRequested
            $hint = Get-StopHint -Armed:$armed
            $hintColor = if ($armed) { [System.ConsoleColor]::Yellow } else { [System.ConsoleColor]::DarkGray }
            $prevH = [Console]::ForegroundColor
            try { [Console]::ForegroundColor = $hintColor; [Console]::Write("   " + $hint) }
            finally { [Console]::ForegroundColor = $prevH }
```
This appends the hint to the same in-place spinner line. Then widen the line-clear in the `finally` (line 378) so the longer line is fully erased:
```powershell
        [Console]::Write($cr + (' ' * ([Math]::Max(60, [Console]::WindowWidth - 1))) + $cr)
```

- [ ] **Step 2: Manual check (no automated keypress in headless mode)**

Run a real queue in an interactive terminal and confirm: while a task works, the bottom line reads `… running · 0:0X   Ctrl+C stop now · s stop after this task`, and pressing `s` switches it to `stopping after this task…`. (Automated coverage of the *stop behavior* comes in Task 5 via the flag file.)

- [ ] **Step 3: Confirm the existing suite still passes**

Run: `Invoke-Pester tests/limitshift.Tests.ps1`
Expected: all existing tests PASS (the spinner only animates on a TTY; headless tests are unaffected).

- [ ] **Step 4: Commit**

```bash
git add limitshift.ps1
git commit -m "feat(ps1): watch for 's' and show the stop reminder in the spinner"
```

### Task 4: Watch keys during the usage-limit wait (ps1)

**Files:**
- Modify: `limitshift.ps1` — `Invoke-UiRest` (lines 454-492)

- [ ] **Step 1: Poll keys and break the wait when stop is requested**

Inside the `while ((Get-Date) -lt $WakeTime)` loop, after the existing `[Console]::Write` block (~line 483) and before `$mi++`, add:
```powershell
            Read-StopKey
            if (Test-StopRequested) { break }
            $prevH2 = [Console]::ForegroundColor
            try { [Console]::ForegroundColor = [System.ConsoleColor]::Yellow; [Console]::Write("   " + (Get-StopHint -Armed:$true)) }
            finally { [Console]::ForegroundColor = $prevH2 }
```
Also append the active hint to the resting line during the wait: in the same loop, after the existing resting text write, append `("   " + (Get-StopHint))` (DarkGray) — mirroring the spinner. Widen the `finally` clear (line 489) to `([Math]::Max(60, [Console]::WindowWidth - 1))` spaces.

- [ ] **Step 2: Confirm the suite still passes**

Run: `Invoke-Pester tests/limitshift.Tests.ps1`
Expected: PASS (rest only animates on a TTY).

- [ ] **Step 3: Commit**

```bash
git add limitshift.ps1
git commit -m "feat(ps1): honor 's' during a usage-limit wait"
```

---

## Phase 3 — ps1 main loop clean stop

### Task 5: Stop after the current step in the task loop (ps1)

**Files:**
- Modify: `limitshift.ps1` — the task loop (outer `for` at line 2509, inner `while ($true)` at ~2548) and the `finally` cleanup (line ~2731)
- Test: `tests/limitshift.Tests.ps1`

- [ ] **Step 1: Write the failing end-to-end test**

Add to `tests/limitshift.Tests.ps1` (modeled on the existing "Model rotation — end-to-end" stub pattern):
```powershell
Context 'Graceful stop (press s) — end-to-end via flag file' {
    It 'stops cleanly after the current step and does not start the next task' {
        $root = New-TestRoot
        $projectPath = Join-Path $root 'project'
        $binPath = Join-Path $root 'bin'
        New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
        New-Item -ItemType Directory -Path $binPath -Force | Out-Null

        # The stub (task 1's CLI) creates the stop flag during its run — i.e. "user pressed s".
        $flagPath = Join-Path $root 'limitshift-queue\stop-after-step.flag'
        $callLog = Join-Path $root 'calls.txt'
        $geminiPath = Join-Path $binPath 'gemini.ps1'
        @"
`$null = [Console]::In.ReadToEnd()
[System.IO.File]::AppendAllText('$($callLog -replace '\\','\\')', 'call' + [Environment]::NewLine)
New-Item -ItemType File -Path '$($flagPath -replace '\\','\\')' -Force | Out-Null
Write-Output '{"session_id":"g-1","response":"done\n\n[[TASK_COMPLETE]]"}'
exit 0
"@ | Set-Content -LiteralPath $geminiPath -Encoding UTF8

        $queuePath = Join-Path $root 'queue.json'
        Write-TestQueue -Path $queuePath -Config @{
            settings = @{ stopOnError = $true; maxRunsPerTask = 5; completionCheck = $false }
            tasks = @(
                @{ name = 't1'; cli = 'gemini'; projectPath = $projectPath; prompt = 'p1'; model = 'm' }
                @{ name = 't2'; cli = 'gemini'; projectPath = $projectPath; prompt = 'p2'; model = 'm' }
            )
        }

        $oldPath = $env:PATH
        try {
            $env:PATH = "$binPath;$oldPath"
            $run = Invoke-RunnerProcess -Arguments @('-NoProfile', '-File', $script:__limitshiftScriptPath, '-QueuePath', $queuePath)
            $run.ExitCode | Should -Be 0
            $run.Output | Should -Match 'Stopping after the current step'
            # Task 1 ran and completed; task 2 was NOT started.
            (@(Get-Content -LiteralPath $callLog | Where-Object { $_ })).Count | Should -Be 1
            $run.Output | Should -Not -Match 'Task 2/2'
            # Lock released, flag cleaned up.
            Test-Path -LiteralPath (Join-Path $root 'limitshift-queue\limitshift.lock') | Should -BeFalse
        }
        finally { $env:PATH = $oldPath }
    }
}
```

- [ ] **Step 2: Run it and confirm failure**

Run: `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*press s*end-to-end*'`
Expected: FAIL (task 2 still runs; no "Stopping" message).

- [ ] **Step 3: Add the stop checks to the loop**

At the **top of the outer `for`** (right after `$task = $Tasks[$i]` / `$taskNumber = $i + 1`, ~line 2511) add:
```powershell
        if (Test-StopRequested) {
            Write-Host ""
            Write-UiBeat -Glyph ([string]$script:GlyphMoon) -Message ("Stopping after the current step (you pressed s). " + $doneCount + " task(s) done this run; rerun the same command to continue.") -Color Yellow
            break
        }
```
At the **top of the inner `while ($true)`** (right after `$runCount++` and the maxRuns guard, ~line 2552) add the same break out of the inner loop so a mid-task stop doesn't send another prompt:
```powershell
            if (Test-StopRequested) { break }
```
After the inner `while` exits, the outer-`for` top check (next iteration) prints the message and breaks. Because a stop can break the inner loop without marking the task done, that task simply has no done marker and resumes next run — which is the intended behavior.

- [ ] **Step 4: Remove the flag on exit**

In the `finally` block (line ~2731, where the lock is removed), add:
```powershell
    Remove-Item -LiteralPath $StopFlagPath -Force -ErrorAction SilentlyContinue
```

- [ ] **Step 5: Run it and confirm pass**

Run: `Invoke-Pester tests/limitshift.Tests.ps1 -FullNameFilter '*press s*end-to-end*'`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `Invoke-Pester tests/limitshift.Tests.ps1`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add limitshift.ps1 tests/limitshift.Tests.ps1
git commit -m "feat(ps1): stop cleanly after the current step when 's' is pressed"
```

---

## Phase 4 — bash parity

### Task 6: Stop-signal foundation + startup clear (bash)

**Files:**
- Modify: `limitshift.sh` — near the UI glyph/constant block, near where `RUNNER_STATE_PATH`/`USAGE_PATH` are defined (~line 1952), and `initialize_runner_state` (~line 1831)

- [ ] **Step 1: Add hint vars, flag path, and helpers**

Beside the other `GLYPH_*`/`UI_*` constants add:
```bash
STOP_HINT_ACTIVE="Ctrl+C stop now $GLYPH_DOT s stop after this task"
STOP_HINT_ARMED="stopping after this task…"
```
Beside `USAGE_PATH` (~line 1952) add:
```bash
STOP_FLAG="$RUNNER_STATE_PATH/stop-after-step.flag"
```
Add helpers near the other small helpers:
```bash
stop_requested() { [ -n "$STOP_FLAG" ] && [ -f "$STOP_FLAG" ]; }
request_stop()  { [ -n "$STOP_FLAG" ] && : > "$STOP_FLAG" 2>/dev/null || true; }
```

- [ ] **Step 2: Clear a stale flag at startup**

In `initialize_runner_state` (~line 1831), after the state folder is ensured, add:
```bash
  rm -f "$STOP_FLAG" 2>/dev/null || true
```

- [ ] **Step 3: Sanity-check the script parses**

Run: `bash -n limitshift.sh && echo "parse OK"`
Expected: prints `parse OK`.

- [ ] **Step 4: Commit**

```bash
git add limitshift.sh
git commit -m "feat(sh): graceful-stop flag, hint text, helpers, startup clear"
```

### Task 7: Watch keys + reminder in the spinner subshell and rest loop (bash)

**Files:**
- Modify: `limitshift.sh` — `ui_spinner_start` (lines 440-493), `ui_rest` (lines 497-535)

- [ ] **Step 1: Read keys + draw the reminder in the spinner subshell**

Inside the spinner subshell's `while :; do` loop (after the existing draw, before `pos=$((pos + dir))`, ~line 473), add a non-blocking single-char read from the tty and the reminder text:
```bash
      if [ -r /dev/tty ]; then
        if IFS= read -rsn1 -t 0.01 _key < /dev/tty 2>/dev/null; then
          case "$_key" in s|S) : > "$STOP_FLAG" 2>/dev/null || true ;; esac
        fi
      fi
      if [ -f "$STOP_FLAG" ]; then _hint="$STOP_HINT_ARMED"; else _hint="$STOP_HINT_ACTIVE"; fi
      printf '%s   %s%s' "$UI_DIM" "$_hint" "$UI_RESET" > /dev/tty
```
(The subshell already inherits `$STOP_FLAG`, `$STOP_HINT_*`, `$UI_*` at fork time.) Widen the clear in `ui_spinner_stop` (line 489) to a longer blank run so the appended hint is erased:
```bash
      printf '\r%s\r' "                                                                                " > /dev/tty 2>/dev/null
```

- [ ] **Step 2: Read keys + break the wait in `ui_rest`**

Inside `ui_rest`'s `while :; do` loop (after the draw, before `mi=$((mi + 1))`, ~line 530), add:
```bash
    if [ -r /dev/tty ] && IFS= read -rsn1 -t 0.01 _key < /dev/tty 2>/dev/null; then
      case "$_key" in s|S) : > "$STOP_FLAG" 2>/dev/null || true ;; esac
    fi
    if [ -f "$STOP_FLAG" ]; then break; fi
    printf '%s   %s%s' "$UI_DIM" "$STOP_HINT_ACTIVE" "$UI_RESET" > /dev/tty
```

- [ ] **Step 3: Sanity-check + manual verify**

Run: `bash -n limitshift.sh && echo "parse OK"`. Then, in a real terminal, confirm the reminder shows during a task and `s` flips it to "stopping…". (Automated stop coverage is Task 8.)

- [ ] **Step 4: Commit**

```bash
git add limitshift.sh
git commit -m "feat(sh): watch for 's' and show the stop reminder (spinner + wait)"
```

### Task 8: Stop after the current step in `run_queue` (bash)

**Files:**
- Modify: `limitshift.sh` — `run_queue` (the per-task loop ~line 1999, and the inner resume loop) and the exit cleanup
- Test: `tests/test-limitshift.sh`

- [ ] **Step 1: Write the failing end-to-end test**

Add to `tests/test-limitshift.sh` (modeled on the existing stub tests). The stub creates the flag during task 1's run:
```bash
test_graceful_stop_after_step() {
  local root="$TMP_ROOT/graceful-stop"; local project_dir="$root/project"; local bin_dir="$root/bin"
  local queue_path="$root/queue.json"; local call_log="$root/calls.txt"
  mkdir -p "$project_dir" "$bin_dir"
  local flag="$root/limitshift-queue/stop-after-step.flag"
  cat > "$bin_dir/gemini" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo call >> "$call_log"
mkdir -p "\$(dirname "$flag")"; : > "$flag"
printf '%s\n' '{"session_id":"g-1","response":"done\\n\\n[[TASK_COMPLETE]]"}'
EOF
  chmod +x "$bin_dir/gemini"
  cat > "$queue_path" <<EOF
{ "settings": { "completionCheck": false },
  "tasks": [
    { "name":"t1","cli":"gemini","projectPath":"$project_dir","prompt":"p1","model":"m" },
    { "name":"t2","cli":"gemini","projectPath":"$project_dir","prompt":"p2","model":"m" } ] }
EOF
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  if printf '%s' "$out" | grep -q 'Stopping after the current step' \
     && [ "$(grep -c call "$call_log")" = "1" ] \
     && ! printf '%s' "$out" | grep -q 'Task 2/2' \
     && [ ! -f "$root/limitshift-queue/limitshift.lock" ]; then
    pass "graceful stop: stops after current step, skips task 2, releases lock"
  else
    fail "graceful stop" "$out"
  fi
}
test_graceful_stop_after_step
```

- [ ] **Step 2: Run it and confirm failure**

Run: `bash tests/test-limitshift.sh`
Expected: the new assertion FAILS.

- [ ] **Step 3: Add the stop checks to `run_queue`**

At the **top of the per-task loop** (right after the task index/number are set, before the already-done check) add:
```bash
    if stop_requested; then
      printf '\n'
      ui_beat "$GLYPH_MOON" "Stopping after the current step (you pressed s). ${done_count} task(s) done this run; rerun the same command to continue." "$UI_BLUE"
      break
    fi
```
At the **top of the inner resume loop** (where each run iteration begins) add:
```bash
      if stop_requested; then break; fi
```
(Use the loop's actual done-counter variable name in the message.)

- [ ] **Step 4: Remove the flag on exit**

Wherever the lock is released at the end of `run_queue` / the script's exit path, add:
```bash
  rm -f "$STOP_FLAG" 2>/dev/null || true
```

- [ ] **Step 5: Run it and confirm pass**

Run: `bash tests/test-limitshift.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add limitshift.sh tests/test-limitshift.sh
git commit -m "feat(sh): stop cleanly after the current step when 's' is pressed"
```

---

## Phase 5 — docs

### Task 9: Document the `s` key

**Files:**
- Modify: `README.md` (and `README.uk.md`), `REFERENCE.md`

- [ ] **Step 1: Add a short note** wherever Ctrl+C / stopping is described (README "Run the queue" area mentions Ctrl+C): explain that **Ctrl+C stops immediately (mid-task)**, while **pressing `s` (or `S`) stops cleanly after the current step finishes** so you can restart without losing in-flight work, and that a reminder line shows this while it runs. Mirror in `README.uk.md`; add the same to `REFERENCE.md` run-options/state section.

- [ ] **Step 2: Commit**

```bash
git add README.md README.uk.md REFERENCE.md
git commit -m "docs: document pressing s to stop after the current step"
```

---

## Self-review checklist

- **Spec coverage:** keypress `s`/`S` → Tasks 3/4/7 (watchers) + 1 (helpers); reminder line shown/hidden → Tasks 3/4/7 (ride the spinner/rest lines, erased by existing cleanup); stop after current step → Tasks 5/8; honored during usage-limit wait → Tasks 4/7; clean exit + lock release → Tasks 5/8 (break → existing summary + `finally`); stale-flag safety → Tasks 2/6 (startup clear); docs → Task 9.
- **Cross-runner parity:** flag file name `stop-after-step.flag`, hint strings, and "Stopping after the current step" message are identical in ps1 and sh.
- **Back-compat:** the watchers only act on an interactive TTY; headless/test runs never create the flag on their own, so existing behavior and all existing tests are unchanged. The stop path is exercised in tests by creating the flag file directly (no TTY needed).
- **Name consistency:** ps1 `Test-StopRequested`/`Request-Stop`/`Read-StopKey`/`Get-StopHint`/`$StopFlagPath`/`$script:CanReadStopKey` ↔ bash `stop_requested`/`request_stop`/`$STOP_FLAG`/`$STOP_HINT_ACTIVE`/`$STOP_HINT_ARMED`.
- **Manual-only piece:** the actual key capture (`[Console]::KeyAvailable`/`read -rsn1`) is verified by hand (Tasks 3/7 Step 2); everything else is automated.
```
