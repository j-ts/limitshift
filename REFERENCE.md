# Reference

Detail to come back to when you need a specific option. Everything in the [README](README.md) is enough to get real work done.

## Configuration

The queue file is `limitshift-queue.json` (copy an example and edit). `settings` apply to the whole list; `tasks[]` fields apply to one task.

| Field | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| `settings.stopOnError` | boolean | no | `true` | Stop the queue after an unrecoverable failure |
| `settings.maxRunsPerTask` | integer | no | `20` | Cap on new + resumed runs per task |
| `settings.maxRetriesOnError` | integer | no | `2` | Retries for non-limit failures |
| `settings.limitWaitMinutes` | integer | no | `30` | Fallback wait when the reset time can't be parsed |
| `settings.resetBufferMinutes` | integer | no | `2` | Extra buffer added after a parsed reset time |
| `settings.completionCheck` | boolean | no | `true` | See [Completion checking](README.md#completion-checking) |
| `settings.maxStalls` | integer | no | `2` | Fail a task after this many identical no-marker replies in a row |
| `tasks[].name` | string | **yes** | — | Human-readable task name |
| `tasks[].cli` | string | **yes** | — | `claude`, `codex`, `gemini`, `agy`, or `copilot` |
| `tasks[].projectPath` | string | **yes** | — | Folder the CLI runs in (must exist) |
| `tasks[].prompt` | string | **yes** | — | The task prompt |
| `tasks[].model` | string or array | no | — | See [Models](#models) and [Model rotation](README.md#model-rotation) |
| `tasks[].effort` | string or null | no | — | Reasoning effort (see [Models](#models)) |
| `tasks[].completionCheck` | boolean | no | inherits settings | Per-task override |
| `tasks[].extraArgs` | string or array | no | — | Extra CLI flags — where [permission](#permissions) and [Ollama](README.md#run-with-local-models-through-ollama) flags go |
| `tasks[].fallbacks` | array | no | — | Backup runners for [CLI rotation](#cli-rotation). Each entry requires `cli`; `model`, `effort`, `extraArgs` are optional and follow the same shapes/rules as the top-level fields. `projectPath` must be a git working tree. |

Windows paths in JSON need **doubled backslashes** (`"C:\\Users\\me\\repo"`) or forward slashes (`"C:/Users/me/repo"`). Keep the `$schema` line from an example file to get inline validation in editors that support it.

## Models

> **Tested with:** Claude Code **2.1.170** · Codex CLI **0.136.0** · Gemini CLI **0.46.0** · Antigravity `agy` **1.0.8**. These are the builds LimitShift has been verified against; other recent versions should work too.

Model aliases passed through to each CLI:

- **claude:** `opus`, `sonnet`, `haiku` (or full ids like `claude-opus-4-8`).
- **codex:** `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`.
- **gemini:** `gemini-3.*` (e.g. `gemini-3.1-pro-preview`, `gemini-3-flash-preview`), `gemini-2.5-*`.
- **agy:** run `agy models` to see what your account can use (e.g. `gemini-3.1-pro`, `gemini-3.5-flash`, `claude-sonnet`, `gpt-oss-120b`). agy has no headless output mode (it draws its reply on screen), so LimitShift reads agy's answer back from its own local conversation history; and it resumes only its most recent conversation, so keep agy work to one linear chain of tasks — LimitShift handles the rest. Just have agy installed and signed in.
- **copilot:** install the GitHub CLI extension (`gh extension install github/gh-copilot`) and run `copilot login`. The Copilot CLI does not currently expose a scriptable model-list command, so choose a supported model from GitHub Copilot settings or docs, then pass it through as `model` / `--model`. LimitShift passes `effort` through as `--effort`, uses `--name` on the first run and `--resume=<session-id>` on resumed runs, sends the prompt via `-p`, forces `--output-format=json --stream=off --no-ask-user`, and parses the returned JSONL stream for assistant text, session ids, and usage-limit signals.

**Effort** (`tasks[].effort`): claude `low`/`medium`/`high`/`xhigh`/`max`; codex `minimal`/`low`/`medium`/`high`/`xhigh`; copilot `low`/`medium`/`high`/`xhigh`/`max`. Gemini, Antigravity (`agy`), and Claude Haiku have no effort flag — leave it `null`.

### Model validation

LimitShift validates model names at runtime against each CLI's own model list during `--validate-only` / `-ValidateOnly` — no new release is needed when a provider adds or renames a model.

**What gets checked:**

| Output prefix | Meaning |
|---|---|
| `ERROR:` | model not found in the CLI's discovered list — exits 2 (strict mode) |
| `WARNING:` | model not found but queue will still run (warn mode) |
| `INFO:` | model name could not be verified (CLI has no model-list command) |

**Discovery support:**
- `agy`: parses `agy models`
- `claude`, `codex`, `gemini`, `copilot`: no scriptable model list — prints INFO, never fails

**Settings** (inside `"settings": {}`):

```json
"modelValidation": "strictWhenDiscoverable",
"capabilityCacheHours": 24,
"probeModels": false
```

- `modelValidation`: `"strictWhenDiscoverable"` (default) · `"warn"` · `"off"`
- `capabilityCacheHours`: how long to cache the discovered list; `0` = always refresh
- `probeModels`: run a cheap connectivity prompt per CLI when using `--validate-only`

**Flags:**
- `--refresh-capabilities` / `-RefreshCapabilities`: ignore cache and re-query
- `--probe-models` / `-ProbeModels`: opt-in connectivity probe (consumes a small amount of quota)

**Typo detection:** if a model is missing, LimitShift suggests the nearest known model names (edit distance ≤ 4).

**Cache location:** `limitshift-<queue>/capabilities/<cli>.json` next to the queue file.

## CLI rotation

Add a `fallbacks` array to any task to give it backup runners. When the current runner can't continue, LimitShift picks the next runnable runner per these rules.

**The five run outcomes:**

| Outcome | Detection | What happens |
| --- | --- | --- |
| **Complete** | last non-empty line contains `[[TASK_COMPLETE]]` | Task done. |
| **Blocked** | last non-empty line contains `[[TASK_BLOCKED]] <reason>` | Task fails without switching runners; `stopOnError` applies. |
| **Limit** | usage-limit regex matches | Rotate to the runner's next model. When all models on this runner are capped, mark the runner **limited** (records its reset time) and switch to the next runner. |
| **Error** | non-zero exit, not a limit | Retry the same runner up to `maxRetriesOnError`. When retries are exhausted, **set the runner aside** permanently for this task and switch. |
| **Stall** | successive identical no-marker replies from the same runner | After `maxStalls` repeats, set the runner aside and switch. With no fallbacks, the task fails (unchanged behavior). |

**Runner selection:** the next runner is the first one, scanning from the current position, that is not set aside and whose reset time (if limited) is in the past.

**Soonest-reset waiting:** when no runner is immediately runnable, LimitShift waits for the runner with the soonest reset within 24 hours and retries. If every live runner is more than 24 hours away (weekly caps), or every runner has been set aside, the task fails per `stopOnError`.

**Handoff note:** when the runner changes, LimitShift prepends an exact note to the new session's prompt telling it to inspect `git status` (new/untracked files) and `git diff` (tracked-file changes) before starting.

**Git requirement:** a task with a non-empty `fallbacks` list requires its `projectPath` to be a git working tree. `--validate-only` fails with a clear error if it is not. A repo with no commits emits a non-fatal warning (the handoff is less precise without a baseline — see [STRATEGIES.md](STRATEGIES.md)).

**`runs.csv` columns:** rotation adds `cli` and `model` columns to every row so the full tool-switch history is reconstructable from the log.

**State files (fallbacks tasks only):** LimitShift saves a `task-NN-runner-index.txt` file (current runner index) and per-runner model-index files (`task-NN-runner-K-model-index.txt`). These are **not** created for single-runner tasks. When a task's definition changes (fingerprint changes), both are dropped along with the done marker and session id.

**`maxRunsPerTask` and rotation:** the default cap of 20 counts every CLI invocation. A rotation task legitimately uses more runs (runners × models × retries × stalls × progress-resumes). When the cap is reached on a fallbacks task, the task fails per `stopOnError` rather than aborting the whole queue. See [STRATEGIES.md](STRATEGIES.md) for budget guidance.

## Permissions

Headless runs can't answer permission prompts — set your choice in `extraArgs`, or **the AI runs read-only and changes nothing**:

- Claude: `--permission-mode acceptEdits` (or `--dangerously-skip-permissions`)
- Codex: `--sandbox workspace-write` (or `--dangerously-bypass-approvals-and-sandbox`)
- Gemini: `--approval-mode auto_edit` (or `--approval-mode yolo`)
- Antigravity (`agy`): `--dangerously-skip-permissions` (its only headless auto-approve)
- Copilot: recommended edit flags are `--allow-tool=read,write,shell(npm:*),shell(npx:*),shell(git:*) --deny-tool=shell(git push) --no-ask-user`; automation mode is `--allow-all --no-ask-user` and should be used only when you fully trust the task.

More autonomy means more risk — run only against Git-backed folders.

## Run options

| Flag (PowerShell / Bash) | Does |
| --- | --- |
| `-ValidateOnly` / `--validate-only` | Check the config; change nothing |
| `-DryRun` / `--dry-run` | Print the exact commands; don't run or mark tasks done |
| `-QueuePath <file>` / `--queue-path <file>` | Use a named or custom queue file (bare filename resolves from script folder) |
| `-ShowRawOutput` / `--show-raw` | Print the raw CLI output to the console |

### Stopping

| Action | Result |
| --- | --- |
| **Ctrl+C** | Stops immediately, even mid-task. Use for emergency exits. |
| **Press `s` (or `S`)** | Stops cleanly after the current step finishes. Ensures in-flight work is not lost. |

When you press `s`, the status line switches to "stopping after this task…" as a reminder. Progress is saved, and you can resume the same command later to pick up where you left off.

## Where LimitShift saves state

Everything lives in `limitshift-<queue-name>/` next to your queue (for the default file, `limitshift-queue/`): session ids (to resume the same conversation), `outputs/` (raw output per run), `status/` (`.done` / `.failed` markers), `runs.csv`, and a log.

Editing a task's `name`, `prompt`, `cli`, `projectPath`, `model`, `effort`, or `extraArgs` auto-invalidates its `.done` marker and re-runs it with a fresh session; untouched tasks stay skipped. Delete a single `status/task-NN.done` to re-run one task, or delete the whole folder to start over — it's rebuilt on the next run.

## Troubleshooting

| Message | Fix |
| --- | --- |
| `Config file is not valid JSON` | Check for trailing/missing commas or bad escaping (use forward slashes in paths). If you edited it by hand, paste it into a validator like [classic.online-json.com/json-validator](https://classic.online-json.com/json-validator) to pinpoint the error |
| `Task N is missing required JSON property` | Add the missing `name`, `cli`, `projectPath`, or `prompt` |
| `Allowed values: claude, codex, gemini, agy, copilot` | Fix the `cli` value |
| `Project path does not exist` | Fix the path or create the folder |
| `not found on PATH` | Install the named CLI and retry |
| `jq is required but not installed` | Install `jq` (`brew install jq` / `sudo apt install jq`) |
| `Task N exceeded maxRunsPerTask` | Inspect the prompt/output; raise the cap only if needed |
| `installed gemini rejects --resume` | Harmless — the runner retries with a continuation prompt |
| AI reported success but nothing changed | No permission flag — add the right `extraArgs` (see [Permissions](#permissions)) |

## Tests

```powershell
Invoke-Pester tests/limitshift.Tests.ps1
```
```bash
bash tests/test-limitshift.sh
```
