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

## Where LimitShift saves state

Everything lives in `limitshift-<queue-name>/` next to your queue (for the default file, `limitshift-limitshift-queue/`): session ids (to resume the same conversation), `outputs/` (raw output per run), `status/` (`.done` / `.failed` markers), `runs.csv`, and a log.

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
