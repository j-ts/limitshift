# Copilot Backend Integration — Verification Report

Commits reviewed: `88ecc73` (add backend support), `1664523` (add GitHub Copilot CLI as fifth supported CLI; fix multi-line prompt delivery and completion detection)

---

## Scope Reviewed

| File | Lines | Status |
|---|---|---|
| `limitshift-queue.schema.json` | full diff | ✅ read |
| `limitshift.ps1` | full (1865 lines) | ✅ read |
| `limitshift.sh` | full (1678 lines) | ✅ read |
| `tests/limitshift.Tests.ps1` | full (2105 lines) | ✅ read |
| `tests/test-limitshift.sh` | full (2073 lines) | ✅ read |
| `README.md` | copilot grep | ✅ read |
| `QUICKSTART.md` | copilot grep | ✅ read |
| `CHANGELOG.md` | full | ✅ read |
| `AGENTS.md` | full | ✅ read |
| `limitshift-queue.example.json` | copilot grep | ✅ read |
| `limitshift-queue.example-simple.json` | copilot grep | ✅ read |
| `limitshift-queue.example-workflow.json` | copilot grep | ✅ read |
| `limitshift-queue.example-advanced.json` | full | ✅ read |

---

## Verification Commands

Execution of the required verification commands was **blocked by a user-configured hook** that requires explicit approval before running `bash *.sh`, `Invoke-Pester`, and nested `powershell.exe` processes. No commands were run; all status below is from static analysis only.

| Command | Status |
|---|---|
| `.\limitshift.ps1 -ValidateOnly` | ❌ blocked by hook — not run |
| `Invoke-Pester tests/limitshift.Tests.ps1` | ❌ blocked by hook — not run |
| `bash tests/test-limitshift.sh` | ❌ blocked by hook — not run |
| `./limitshift.sh --validate-only` | ❌ blocked by hook — not run |
| Copilot smoke test | ⏭️ skipped — copilot CLI not installed on this machine |

**To complete dynamic verification, run these four commands manually from the repo root. They must all exit 0 for full pass.**

---

## Checklist Results (Static Analysis)

### 1. Schema — PASS

- `"copilot"` added to `cli` enum: `limitshift-queue.schema.json:40`.
- `allOf` conditional block (lines 96–108) enforces `effort ∈ {null, "low", "medium", "high", "xhigh", "max"}` for `cli=copilot`.
- All pre-existing CLI effort conditions (gemini, agy, claude, codex) are unchanged.

### 2. PowerShell and Bash Validation — PASS

- PS1 `$AllowedClis` at line 153 includes `'copilot'`.
- PS1 effort block at lines 346–351: validates against `@('low','medium','high','xhigh','max')`, throws a task-numbered message on failure.
- Bash `claude|codex|gemini|agy|copilot)` at line 231 in the CLI-allowlist branch.
- Bash effort block at lines 304–309: `case` statement with same five values.
- Both scripts include `copilot` consistently in all validation paths.

### 3. Binary Detection and Install Text — PASS

- PS1 lines 395–404: `"  copilot: install GitHub Copilot CLI and run: copilot login\`n"`
- Bash line 347: same message.
- Both are listed alongside claude/codex/gemini/agy in the "missing CLI" install hint.

### 4. Argument Construction — PASS (with one doc-string discrepancy; see Findings)

PS1 `Get-CliArguments` copilot branch (lines 1194–1204):
```
--name <sessionId>          (New)    or
--resume <sessionId>        (Resume)
--output-format json --stream off --no-ask-user
-p <prompt>
--model <model>             (optional)
--effort <effort>           (optional)
<extraArgs...>
```
Bash `build_cli_args` copilot branch (lines 971–989): identical structure; args appended as separate array elements.

Order is correct. `extraArgs` appended last. `--model` and `--effort` are conditional. New vs resume branch correctly uses `--name` vs `--resume`.

### 5. Prompt Transport — PASS

- PS1 line 1488: copilot prompt channel set to `'passed as the -p argument'` (same branch as agy).
- PS1 line 1505: copilot `StdinText` set to `''` (empty) — closes EOF so the process cannot block on an inherited stdin handle.
- Bash lines 1266–1270: display says "(prompt passed as the -p argument; ...)".
- Bash lines 1287–1291: copilot gets `</dev/null` for stdin, output captured separately.

### 6. JSONL Parsing — PASS

PS1 `ConvertFrom-CliOutput` copilot branch (lines 1419–1456):
- Iterates output lines; attempts JSON parse per line.
- Extracts text from `content`, `text`, or `message` fields on `assistant.message` type events.
- Captures session ID from six field names: `interactionId`, `session_id`, `sessionId`, `conversation_id`, `conversationId`, `thread_id`, `threadId` — robust to API evolution.
- Surfaces errors from `error` object or `type=error` events.
- Detects limits via regex (line 1328): `'(?i)(usage limit|rate limit|too many requests|quota|premium requests|billing|try again at|try again in|429)'`.
- Falls back to raw output when no line parses as valid JSONL.

Bash `parse_cli_output` copilot branch (lines 1158–1182): `jq` expressions with the same logic.

### 7. Documentation — PASS

- **README**: 10+ copilot mentions; listed in feature table, install table (`gh extension install github/gh-copilot && copilot login`), field reference, effort reference, permission example, glossary, error table.
- **QUICKSTART**: Section on copilot with effort levels and permission flags (`--allow-tool`, `--deny-tool`, `--no-ask-user`).
- **CHANGELOG**: "Added GitHub Copilot CLI Support" section under [Unreleased] with all key behaviors documented.
- **AGENTS.md**: copilot in enum (line 4), model guidance (line 83), effort (line 83), permission flags (line 94).
- **All 4 example files**: each contains at least one `"cli": "copilot"` task (confirmed via grep).

### 8. Tests — PASS (with one gap; see Findings)

**PS1 (`tests/limitshift.Tests.ps1`)**:
- Effort: accepts `"high"`, rejects `"minimal"` — lines 211–220.
- `Get-CliArguments`: New and Resume arg strings verified at lines 688–706.
- `ConvertFrom-CliOutput`: success/limit/unknown-shape cases at lines 1089–1125.
- `Invoke-CliTaskRun`: end-to-end `-p` delivery and `stdin_len=0` at lines 1392–1431.
- Shipped examples: all four example files validate with `-ValidateOnly` at lines 2066–2103.

**Bash (`tests/test-limitshift.sh`)**:
- Effort: `run_effort_copilot_rejected_test`, `run_effort_copilot_ok_test` — called at lines 2052–2053.
- E2E `-p` delivery: `run_copilot_prompt_as_arg_test` — called at line 2065.
- Limit detection: `run_copilot_limit_detection_test` — called at line 2066.
- Shipped examples: `run_shipped_examples_validate_test` covers all four example files.

### 9. Regression of Existing CLIs — PASS

All existing test cases for claude, codex, gemini, and agy are intact. Copilot additions are purely additive to allowlists, enum values, `switch`/`case` branches, and test suites. No existing branches were modified.

---

## Findings

### F1 — LOW — Schema doc-string says `=` form, implementation uses space form

**File:** `limitshift-queue.schema.json:104`
**Text:** `"The runner passes this through to the CLI along with --model, --name / --resume, -p, --output-format=json, and --no-ask-user."`
**Reality:** Both `limitshift.ps1:1199` and `limitshift.sh:978` build args as separate array elements: `--output-format json --stream off` (space-separated, not `=` form). The tests at `limitshift.Tests.ps1:693` also assert the space form.

**Risk:** The inconsistency is documentation-only if the GitHub Copilot CLI (built on cobra/pflag) accepts both forms — standard Go CLI libraries do. However, if the copilot CLI requires `=` form, `--output-format json` would be silently misinterpreted as a positional argument at runtime.

**Fix:** Either (a) update the schema description at line 104 to match the implementation (`--output-format json`), or (b) change the implementation to use `=` form (`--output-format=json --stream=off`) to match the schema description. The lower-risk choice is (a) since both implementations and all tests already use space form and are internally consistent. If the real copilot CLI is available, run `copilot agent run --output-format json --stream off --no-ask-user -p "test" 2>&1` to confirm it accepts the space form.

---

### F2 — LOW — No E2E test for "copilot resumes after usage limit"

The test suites have unit-level tests for arg construction and JSONL parsing, and an E2E test that the prompt is delivered via `-p`. However, neither suite has a test analogous to the gemini limit-resume test (`limitshift.Tests.ps1:1498–1562`) or the agy resume test (`test-limitshift.sh: run_agy_resume_continue_test`) for copilot.

The copilot-specific resume path (JSONL session-id extraction → persisting `task-NN-session-id.txt` → next run using `--resume <id>`) is not exercised end-to-end.

**Risk:** Low, because the JSONL parsing and arg-construction paths are both unit-tested. But a regression in session-id extraction field names would not be caught by CI.

**Fix:** Add `run_copilot_resume_test` to `tests/test-limitshift.sh` (model the stub after the gemini one at lines 1799–1823: emit a limit JSON with a session-id field on run 1, then a success JSON on run 2; verify that run 2's args include `--resume <id>`). Add an equivalent Pester test to `tests/limitshift.Tests.ps1`.

---

## Copilot JSONL Sample

Skipped — the GitHub Copilot CLI is not installed on this machine. The parser handles multiple candidate field names for the session ID (`interactionId`, `session_id`, `sessionId`, `conversation_id`, `conversationId`, `thread_id`, `threadId`), which reduces the risk that an undocumented API field name causes silent session loss. The JSONL keys emitted by the real CLI should be captured and the parser field-name list trimmed to those that are actually used once the CLI is available.

---

## Residual Risks

1. **`--stream` flag**: The copilot CLI may not accept `--stream off`; if unknown flags cause a non-zero exit code, every run would be treated as an error rather than a successful no-streaming response. Requires smoke-test with the real CLI.

2. **`--no-ask-user` placement**: The flag is hardcoded in the runner before `extraArgs`. If copilot's parser treats `--no-ask-user` as a subcommand-specific flag that must appear after subcommand-specific args, it could be ignored. Verify with `copilot agent run --no-ask-user -p "test"`.

3. **Session-ID field**: The parser tries seven field names. Until a live JSONL sample is captured, there is no guarantee any of them match the actual field name the copilot CLI emits. Session loss on the first run would cause every subsequent run to start a new session rather than resuming.

4. **`copilot agent run` vs `copilot` entrypoint**: The implementation calls the `copilot` binary directly. If the real entrypoint is `gh copilot` or `copilot agent`, the binary detection and launch path would fail. Verify the PATH-visible binary name.

---

## Summary

**Static analysis**: all 9 checklist items pass. Two low-severity findings (schema doc-string `=` vs space form; missing E2E resume test) and four residual runtime risks that can only be resolved by running the real copilot CLI. No regressions to existing CLI behavior are present.

**Dynamic verification**: blocked by a user-configured hook requiring approval for `powershell.exe`, `bash *.sh`, and `Invoke-Pester` subprocesses. The four verification commands listed above must be run manually to confirm the static analysis holds at runtime.
