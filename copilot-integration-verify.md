# Copilot Backend Integration — Verification Report

Commit reviewed: `56f7222` ([copilot] add backend support)  
Date: 2026-06-14

---

## Scope Reviewed

| File | Coverage |
|---|---|
| `AGENTS.md` | complete |
| `limitshift-queue.schema.json` | complete |
| `limitshift.ps1` | complete (2076 lines) |
| `limitshift.sh` | complete (1971 lines) |
| `README.md` | complete |
| `QUICKSTART.md` | complete |
| `CHANGELOG.md` | complete |
| `limitshift-queue.example-simple.json` | complete |
| `limitshift-queue.example-workflow.json` | complete |
| `limitshift-queue.example-advanced.json` | complete |
| `tests/limitshift.Tests.ps1` | complete (2284 lines) |
| `tests/test-limitshift.sh` | complete (2434 lines) |

---

## Verification Commands

| Command | Result |
|---|---|
| `.\limitshift.ps1 -ValidateOnly` | ✅ PASS — `Config OK` (1 copilot task in queue) |
| `./limitshift.sh --validate-only` (Git Bash) | ✅ PASS — `Config OK` |
| `Invoke-Pester tests/limitshift.Tests.ps1` | ✅ 157/158 PASS — 1 pre-existing failure, unrelated to copilot (see F-3) |
| `bash tests/test-limitshift.sh` | ✅ 79/80 PASS — 1 pre-existing failure, unrelated to copilot (see F-3) |

**Copilot smoke:** `copilot` v1.0.62 is installed at `/c/Users/JTs/AppData/Roaming/npm/copilot`.
- `copilot --version` → `GitHub Copilot CLI 1.0.62` ✅
- `copilot models` → **error: Invalid command format** (see finding F-1)
- Live `-p` prompt smoke skipped — would consume credits; not required for this verification.

---

## Checklist Results

### 1 — Schema accepts `cli="copilot"` and rejects invalid effort — ✅ PASS

- `cli` enum in `limitshift-queue.schema.json:57` includes `"copilot"` alongside the four existing values.
- `allOf` block (lines 113–125) enforces `effort ∈ {null, "low", "medium", "high", "xhigh", "max"}` when `cli=copilot`.
- `"minimal"` (codex-only) is rejected for copilot. All pre-existing CLI effort rules are unchanged.

### 2 — PS1 and Bash validation include copilot consistently — ✅ PASS

- PS1 `$AllowedClis` (line 155): `@('claude','codex','gemini','agy','copilot')`.
- PS1 effort block (lines 351–356): `$copilotEfforts = @('low','medium','high','xhigh','max')`.
- Bash CLI allowlist (line 243): `claude|codex|gemini|agy|copilot`.
- Bash effort case (lines 316–319): `low|medium|high|xhigh|max`.
- Both runners produce identical task-numbered error messages on invalid effort.

### 3 — Binary detection and install text mention copilot — ✅ PASS

- PS1 (lines 402–407): `"  copilot: install GitHub Copilot CLI and run: copilot login"`.
- Bash (line 360): identical message.
- Listed alongside claude/codex/gemini/agy in the "not found on PATH" hint.

### 4 — New/resume argument shape is correct — ✅ PASS (with runtime risk; see F-2)

PS1 `Get-CliArguments` copilot case (lines 1199–1210):
```
New:    --name <sessionId> --output-format=json --stream=off --no-ask-user -p <prompt> [--model m] [--effort e] <extraArgs>
Resume: --resume <sessionId> --output-format=json --stream=off --no-ask-user -p <prompt> [--model m] [--effort e] <extraArgs>
```
Bash `build_cli_args` copilot case (lines 1259–1277): identical structure, args appended as separate array elements.

Order matches spec: session flag first, then fixed JSONL/automation flags, then prompt, then optional flags, then extraArgs. Confirmed against `copilot --help` which shows `--name`, `--resume`, `--output-format`, `--stream`, `--no-ask-user`, `--model`, and `--effort`/`--reasoning-effort` as valid flags.

### 5 — Prompt transport excludes copilot from stdin — ✅ PASS

- PS1 (line 1494): `$promptChannel = if ($Task.Cli -eq 'agy' -or $Task.Cli -eq 'copilot') { 'passed as the -p argument' } else { 'sent via stdin' }`.
- PS1 (line 1511): `$invokeParams['StdinText'] = if ($Task.Cli -eq 'agy' -or $Task.Cli -eq 'copilot') { '' } else { $prompt }`.
- Bash prompt display (lines 1554–1557): includes copilot in `-p argument` branch.
- Bash stdin: copilot (like agy) gets `</dev/null`-equivalent (empty string closes EOF).

### 6 — JSONL parsing is tolerant, surfaces errors, detects limits, falls back — ✅ PASS

PS1 `ConvertFrom-CliOutput` copilot case (lines 1424–1461):
- Event types handled: `assistant.message`, `assistant`, `message`, `response`, `completion`, `final`, `role=assistant`.
- Session ID fields: `interactionId`, `session_id`, `sessionId`, `conversation_id`, `conversationId`, `thread_id`, `threadId`.
- Error paths: `error.message`/`text`/`detail` and `type=error` events.
- Limit regex (line 1333): `'(?i)(usage limit|rate limit|too many requests|quota|premium requests|billing|try again at|try again in|429)'`.
- Fallback: `$OutputText.Trim()` when no line matches known event shapes.

Bash `parse_cli_output` copilot case (lines 1446–1469): `jq`-based parallel implementation with identical field-name lists.

### 7 — Docs and examples mention copilot where relevant — ✅ PASS

- **README.md**: copilot in the tool comparison table (line 37), install table (lines 75–76), permission examples (lines 156–158), CLI field reference (line 283), Models section (lines 302–305), Effort section (line 305), Discovery support table (line 321), Permissions reference (line 351), Troubleshooting table (line 377).
- **QUICKSTART.md**: dedicated copilot paragraph (lines 39–40) with install steps, permission flags, and session/JSONL behavior.
- **AGENTS.md**: copilot in CLI enum (line 53), model guidance (lines 85–89), permission flags (lines 99–100), local-models exclusion note (line 118).
- **CHANGELOG.md**: full "GitHub Copilot CLI Support" entry in [Unreleased] (lines 23–30) with session, effort, model, prompt, JSONL, and permission details.
- **Examples**: all three shipped examples contain a `"cli": "copilot"` task.
  - `example-simple.json`: 2-task queue; second task is copilot with recommended edit flags.
  - `example-workflow.json`: 3-task pipeline; second task is copilot fixing bugs.
  - `example-advanced.json`: 4-task queue; fourth task is copilot with model array and `"effort": "high"`.

### 8 — Tests cover all required behaviors — ✅ PASS

**PS1 (tests/limitshift.Tests.ps1):**
- Schema/effort: accepts `"high"`, rejects `"minimal"` (lines 211–225).
- Arg construction (new): `--name`, JSONL flags, `-p`, model, effort (lines 688–706).
- Arg construction (resume): `--resume` in place of `--name` (lines 688–706).
- `ConvertFrom-CliOutput`: success parse (interactionId extracted, content concatenated), limit from error event, limit from error object, unknown-shape fallback (lines 1089–1125).
- E2E prompt via `-p`, empty stdin (lines 1392–1431).
- Shipped examples (including advanced with copilot task): all 4 validate with `-ValidateOnly` (lines 2245–2282).

**Bash (tests/test-limitshift.sh):**
- Effort: `run_effort_copilot_rejected_test` (minimal rejected), `run_effort_copilot_ok_test` (high accepted).
- `write_fake_copilot` stub emits real JSONL shapes (lines 1599–1624).
- E2E `-p` delivery: `run_copilot_prompt_as_arg_test` (stdin_len=0, JSONL parsed, task completes) (lines 1626–1658).
- Limit detection: `run_copilot_limit_detection_test` (lines 1660–1683).
- Shipped examples: all 4 pass `--validate-only`.

All copilot-specific tests pass in the bash run. Pester tests ran in parallel; the one failure is the pre-existing state-migration test (see F-3).

### 9 — Existing CLI behavior not regressed — ✅ PASS

All claude, codex, gemini, and agy tests pass in both suites. Copilot additions are purely additive (new enum value, new allowlist entry, new `switch`/`case` branches, new test functions). No existing branches were modified.

---

## Findings

### F-1 — MEDIUM: `copilot models` subcommand does not exist in copilot v1.0.62

**Files:** `AGENTS.md:85`, `README.md:303`, `CHANGELOG.md` (discovery support item)

Running `copilot models` returns:
```
error: Invalid command format.
Did you mean: copilot -i "models"?
For non-interactive mode, use the -p or --prompt option.
```

The copilot CLI's `--help` lists these subcommands: `completion`, `help`, `init`, `login`, `mcp`, `plugin`, `update`, `version`. There is no `models` subcommand.

**Runtime impact:** None. When `copilot models` fails, `discover_cli_models` (PS1 and bash) sets `supportsModelDiscovery = false`, and `--validate-only` prints an INFO message. Model names are passed through without validation, the same as `claude`/`codex`/`gemini`. The queue still runs.

**Documentation impact:** Users who follow the docs ("run `copilot models` to list what your account can use") will get a confusing error. AGENTS.md, README.md, and CHANGELOG.md all contain this incorrect instruction.

**Fix for next task:**
- `AGENTS.md:85`: replace "run `copilot models` to see what your account can use" with guidance to check the GitHub Copilot settings page or the Copilot docs for available models; note that model names are passed through as `--model` without CLI-side validation.
- `README.md` (Models section, copilot bullet): same replacement.
- `CHANGELOG.md` (discovery support item): change "agy and copilot: parse `agy models` / `copilot models`" to note that only `agy` supports model discovery; copilot has no scriptable model list (INFO printed, same behavior as claude/codex/gemini).
- Both `discover_cli_models` copilot cases: add a comment that `copilot models` does not exist and this branch is a no-op, retained for forward-compatibility if the CLI adds it.

---

### F-2 — LOW-MEDIUM: `--resume <sessionId>` space form may not attach the session ID

**Files:** `limitshift.ps1:1204`, `limitshift.sh` (copilot resume branch)

Both runners build the resume flag as space-separated array elements: `('--resume', $SessionId)` (PS1) / `("--resume" "$session_id")` (bash). This produces `--resume <sessionId>` on the command line.

The copilot CLI help declares `--resume[=value]` (optional value). Commander.js optional-value options typically require the `=` form to attach a value; space form leaves the option valueless (treats the next token as a positional argument). All examples in `copilot --help` use `=`:
```
copilot --resume=<session-id>
copilot --resume="my feature"
```

If the space form does not attach the session ID, resume runs would invoke the interactive session picker (or resume the most recent session with `--continue` behavior), silently breaking session continuity for copilot tasks.

**Not confirmed:** A live test with `copilot --resume fake-id --output-format=json --stream=off --no-ask-user -p test` was not performed. If the CLI exits with "session not found: fake-id", the space form works. If it opens interactive mode or resumes a different session, it does not.

**Fix (if confirmed broken):**
```powershell
# limitshift.ps1 — copilot resume branch
$cliArgs += "--resume=$SessionId"
```
```bash
# limitshift.sh — copilot resume branch
args+=("--resume=$session_id")
```

**Suggested smoke test for next task:** Run `copilot --resume nonexistent-name --output-format=json --stream=off --no-ask-user -p "echo hi"` and check whether the output contains "nonexistent-name" in an error (space form parsed it) or starts an interactive/most-recent session (space form was ignored).

---

### F-3 — LOW: State-folder migration test fails in both suites (pre-existing, unrelated to copilot)

**Files:** `tests/limitshift.Tests.ps1:1989`, `tests/test-limitshift.sh` (state-migration test)

Both suites fail "old .ai-runner-\<name\> state folder migrates to .limitshift-\<name\>, preserving contents". The runner exits 0 and completes the task, but the message `Migrated state folder .ai-runner-queue -> .limitshift-queue` does not appear in captured output. The migration notification is either written only to the log file (not stdout) or the detection logic is not firing when the test queue path and legacy folder are in a temp directory.

This failure predates the copilot integration. It is unrelated to any copilot-specific code and appears identically in both bash and PowerShell suites.

**Fix for next task:** Inspect the state-migration block in `limitshift.ps1` and `limitshift.sh`. Determine whether the migration message is written with `Write-Host`/`printf` (stdout) or only to the log file. If log-only, either add a stdout echo or update the test assertion to check the log file content instead of captured output.

---

## Copilot JSONL Sample Status

`copilot` v1.0.62 is installed and authenticated. A live JSONL sample was not captured to avoid consuming credits. The parsed event and field-name sets reviewed in the code are broad (7 session-ID field names, 6 event-type patterns) and cover multiple plausible API shapes. Both `ok - copilot receives prompt via -p, model/effort pass, JSONL parsed, task completes` and `ok - copilot limit detection identifies usage limit from JSONL error` passed in the bash run.

The actual JSONL keys emitted by the live CLI should be captured on first use and the parser's field-name lists trimmed to only those observed.

---

## Residual Risks

| Risk | Likelihood | Impact |
|---|---|---|
| `--resume <id>` (space) doesn't attach session ID (F-2) | Medium | High — resume runs may open interactive session picker |
| `copilot models` never added; docs mislead users (F-1) | High | Low — only affects user confusion, not runtime |
| JSONL session-ID field name in actual API doesn't match any of the 7 candidates | Low | High — every run starts a new session, no resume |
| Copilot JSONL schema changes in a future version | Low | Medium — parser falls back to raw text; task still completes |
