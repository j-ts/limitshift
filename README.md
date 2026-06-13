# LimitShift

You write a to-do list of prompts in one file. LimitShift runs them one by one in Claude Code, Codex, or Gemini while you're away. If you hit your usage limit, it waits for the reset and continues the same conversation.

> **Set expectations before you start.** There is **no guarantee** a task completes exactly as you intended — the result depends on the model, your prompt, and the project. Treat the first run as a **draft**: you steer the outcome by adding follow-up tasks or re-running with a refined prompt. **Always run against a git-controlled folder** so you can review the diff and revert anything you don't like.

## Requirements

- Windows: Windows PowerShell 5.1+
- macOS/Linux: Bash 3.2+ and `jq`
- At least one installed CLI: `claude`, `codex`, or `gemini`
- Each CLI must already be trusted/onboarded in every `projectPath` you plan to automate

Headless runs cannot answer first-run trust prompts. Open each project once interactively in the target CLI before using LimitShift.

## Installation

Clone or download the folder. There is no build step.

Windows:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Unblock-File .\limitshift.ps1
```

macOS/Linux:

```bash
chmod +x limitshift.sh
```

> **Deprecation:** the scripts were renamed from `run-ai.ps1` / `run-ai.sh` to `limitshift.ps1` / `limitshift.sh`. Thin `run-ai.ps1` / `run-ai.sh` forwarder stubs still work for one release (they print a deprecation warning and call the new script); they will be removed next release. Update your commands to the new names.

## Simple example

Start here. This is the smallest useful queue: **one** task, only the required fields, plus `"completionCheck": false` so LimitShift just runs your prompt once and only intervenes if you hit a usage limit. This is "run my prompt, survive limits" mode.

The file ships as [`limitshift-queue.example-simple.json`](limitshift-queue.example-simple.json):

```json
{
  "$schema": "./limitshift-queue.schema.json",
  "tasks": [
    {
      "name": "Document install steps",
      "cli": "claude",
      "projectPath": "C:\\Users\\you\\Documents\\my-project",
      "prompt": "Add a README section that explains how to install the project, then commit it",
      "completionCheck": false
    }
  ]
}
```

Copy it to `limitshift-queue.json` (the default name the runner looks for), change `projectPath` to a real git-controlled folder, and edit the `prompt`. The four required fields per task are `name`, `cli`, `projectPath`, and `prompt`. On Windows, escape backslashes in the path: `"C:\\Users\\me\\proj"`.

The `$schema` line is optional but gives you inline validation in editors that understand JSON Schema.

**Always validate first, then run.**

Windows (PowerShell):

```powershell
.\limitshift.ps1 -ValidateOnly
.\limitshift.ps1
```

macOS/Linux (Bash):

```bash
./limitshift.sh --validate-only
./limitshift.sh
```

The console shows only the agent's reply, under a clear header — not the raw CLI JSON:

```text
--- agent response ---
Added an "Installation" section to README.md with clone, dependency, and build
steps, then committed it as "docs: add installation instructions".
```

The full raw CLI JSON is still saved to `.limitshift-limitshift-queue/outputs/task-01-<slug>-output.txt` if you ever need it.

## Advanced example

Once you're comfortable, this 3-task queue shows every optional field. It ships as [`limitshift-queue.example-advanced.json`](limitshift-queue.example-advanced.json):

```json
{
  "$schema": "./limitshift-queue.schema.json",
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 20,
    "maxStalls": 2,
    "limitWaitMinutes": 30,
    "completionCheck": true
  },
  "tasks": [
    {
      "name": "Implement fixes with Codex",
      "cli": "codex",
      "projectPath": "C:\\Users\\you\\Documents\\my-project",
      "model": "gpt-5.4",
      "effort": "medium",
      "extraArgs": ["--sandbox", "workspace-write"],
      "prompt": "Implement the fixes listed in docs/audit.md, run the tests, and summarize what changed."
    },
    {
      "name": "Write release notes with Gemini",
      "cli": "gemini",
      "projectPath": "C:\\Users\\you\\Documents\\my-project",
      "model": ["gemini-3-flash-preview", "gemini-2.5-flash", "gemini-2.5-pro"],
      "effort": null,
      "extraArgs": ["--approval-mode", "auto_edit"],
      "prompt": "Read the git log since the last tag and write RELEASE_NOTES.md."
    },
    {
      "name": "Audit the project with Claude",
      "cli": "claude",
      "projectPath": "C:\\Users\\you\\Documents\\my-project",
      "model": "sonnet",
      "extraArgs": ["--permission-mode", "acceptEdits"],
      "completionCheck": true,
      "prompt": "Read the codebase and write a code-quality audit to docs/audit.md. List concrete issues with file paths. End with [[TASK_COMPLETE]] on its own line when done, or [[TASK_BLOCKED]] <reason> if you cannot finish."
    }
  ]
}
```

What each piece does:

- **`settings`** applies to the whole queue. `stopOnError` (`true`) halts the queue if a task fails unrecoverably. `maxRunsPerTask` (`20`) caps how many new + resumed runs one task may use. `maxStalls` (`2`) fails a task that returns the same answer twice in a row without finishing (only matters when `completionCheck` is `true`). `limitWaitMinutes` (`30`) is the fallback wait when LimitShift cannot read the exact reset time. `completionCheck` (`true`) is the queue-wide default for the completion-marker workflow described below; individual tasks override it.
- **Task 1 (Codex)** uses `model` `"gpt-5.4"` and `effort` `"medium"` (Codex accepts `minimal`/`low`/`medium`/`high`/`xhigh`). `extraArgs` `["--sandbox", "workspace-write"]` lets Codex edit files inside the workspace without prompting. Array form for `extraArgs` is safest because each flag and value is a separate element.
- **Task 2 (Gemini)** passes `model` as an **array** — a rotation list. On a usage limit LimitShift switches to the next model in the list immediately (no waiting) and only waits for a reset once every listed model is exhausted. Gemini has no reasoning-effort flag, so `effort` **must be `null` or omitted** (a non-null effort on a gemini task is rejected at validation). `extraArgs` `["--approval-mode", "auto_edit"]` lets Gemini apply edits automatically.
- **Task 3 (Claude)** sets `completionCheck` to `true`, so LimitShift appends `[[TASK_COMPLETE]]` instructions to the prompt and keeps resuming the same session until the agent ends with that marker (or `[[TASK_BLOCKED]] <reason>`). `model` is the `sonnet` alias. `extraArgs` `["--permission-mode", "acceptEdits"]` lets Claude apply edits without asking.

Every field above passes both schema validation and the runner's stricter runtime checks (for example the per-CLI effort rules). See the [Reference](#reference) for the full field table.

> Three example files ship with LimitShift: [`limitshift-queue.example.json`](limitshift-queue.example.json) (a copy of the simple example, kept under the legacy default name for one release), [`limitshift-queue.example-simple.json`](limitshift-queue.example-simple.json), and [`limitshift-queue.example-advanced.json`](limitshift-queue.example-advanced.json).

---

# Reference

## How it works

1. Read a JSON queue file containing `name`, `cli`, `projectPath`, `prompt`, and optional per-task settings.
2. Validate the JSON, required fields, project paths, and CLI binaries.
3. Start the task in the target project folder using structured JSON/JSONL output.
4. Parse the output to decide whether the task finished, blocked, hit a limit, or failed.
5. On limit, wait until the reset time or fall back to `limitWaitMinutes`.
6. Resume the same Claude/Codex/Gemini session when supported.
7. Mark only completed real runs as done so re-runs skip finished work.

```text
run -> parse output -> complete?
                   |-> yes: mark done, next task
                   |-> limit: wait, resume same session
                   |-> error: retry or stop
                   |-> no marker yet: resume same session
```

## Configuration reference

The queue file is `limitshift-queue.json` by default. Copy one of the example files and edit it. (The old default name `ai-run-queue.json` is still accepted as a fallback for one release — the runner uses it if `limitshift-queue.json` is absent and prints a warning telling you to rename it.)

| Field | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| `settings.stopOnError` | boolean | no | `true` | Stop the queue after an unrecoverable task failure |
| `settings.maxRunsPerTask` | integer | no | `20` | Cap new + resumed runs per task |
| `settings.maxRetriesOnError` | integer | no | `2` | Retries for non-limit failures |
| `settings.limitWaitMinutes` | integer | no | `30` | Fallback wait when reset time cannot be parsed |
| `settings.resetBufferMinutes` | integer | no | `2` | Extra buffer added after parsed reset time |
| `settings.completionCheck` | boolean | no | `true` | `true` injects the `[[TASK_COMPLETE]]` instructions and resumes until the marker appears; `false` ("simple mode") sends the prompt verbatim and marks the task done after the first OK run (only a usage limit triggers a resume) |
| `settings.maxStalls` | integer | no | `2` | When `completionCheck` is `true`, fail the task after this many identical no-marker responses in a row |
| `tasks[].name` | string | yes | none | Human-readable task name |
| `tasks[].cli` | string | yes | none | `claude`, `codex`, or `gemini` |
| `tasks[].projectPath` | string | yes | none | Folder the CLI runs inside (must exist) |
| `tasks[].prompt` | string | yes | none | Task prompt |
| `tasks[].model` | string or array of strings | no | none | Passed through where supported. An array lists models in preference order; on a usage limit the runner rotates to the next model (see below). Primarily useful for gemini |
| `tasks[].effort` | string or null | no | none | Reasoning effort, allowed values per CLI (enforced at validation): **claude** `low`, `medium`, `high`, `xhigh`, `max`; **codex** `minimal`, `low`, `medium`, `high`, `xhigh`; **gemini** must be `null` (it has no effort flag — use `thinkingLevel`/`thinkingBudget` via gemini settings instead). Claude Haiku supports no effort, so claude + a haiku model must also be `null`. `ultracode` (claude's interactive `/effort` menu) and codex `none` (plan-mode only) are rejected |
| `tasks[].completionCheck` | boolean | no | inherits `settings.completionCheck` | Per-task override of completion checking |
| `tasks[].extraArgs` | string or array | no | none | Extra CLI flags |

`model` aliases (passed through to each CLI):

- **claude**: `fable`, `opus`, `sonnet`, `haiku` (or the full ids, e.g. `claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5`).
- **codex**: `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`. (`gpt-5-codex` and `gpt-5.2` are deprecated.)
- **gemini**: `gemini-3.*` (e.g. `gemini-3.1-pro-preview`, `gemini-3-flash-preview`) and `gemini-2.5-*` (e.g. `gemini-2.5-pro`, `gemini-2.5-flash`).

`extraArgs` rules:

- Array form is safest when a flag value contains spaces.
- String form is split on whitespace.
- The runner filters `-C` / `--cd`, `--sandbox`, and `--add-dir` from `codex exec resume` because current Codex resume commands reject them.

Windows path escaping in JSON:

```json
{
  "projectPath": "C:\\Users\\me\\repo"
}
```

Wrong:

```json
{
  "projectPath": "C:\Users\me\repo"
}
```

If your editor supports JSON Schema, keep the `$schema` line from the example file to get inline validation.

## Per-CLI behavior

| CLI | Run mode | Resume mode | Limit detection |
| --- | --- | --- | --- |
| Claude | `claude -p --output-format json` | Native `--resume <session-id>` | Parses `claude -p "/usage"` for session and weekly resets |
| Codex | `codex exec --json` | `codex exec resume <thread-id> --json` | Parses JSONL error events and error text |
| Gemini | `gemini -p --output-format json` | Uses `--resume <session-id>` when supported by the installed CLI, otherwise falls back to a continuation prompt | Parses JSON error text / 429s, then falls back to `limitWaitMinutes` |

### Model rotation on usage limits

Set `tasks[].model` to an array of model names in preference order (most useful for gemini, e.g. `["gemini-3-flash-preview", "gemini-2.5-flash", "gemini-2.5-pro"]`). When a run hits a usage limit, LimitShift switches to the **next** model in the list and retries immediately in the same session (a resume) — no waiting. Only once **every** listed model has been limit-exhausted does it fall back to the normal wait-for-reset path, after which it restarts from model #1. The current position is remembered per task across restarts. A single-string `model` behaves exactly as before (limit → wait → resume the same model).

Switching models mid-session relies on gemini/claude resume. If a CLI rejects a model mid-resume, the existing error-retry path covers it.

## Permissions warning

Headless runs cannot answer permission prompts. Decide your risk posture explicitly through `extraArgs`.

Examples:

- Claude: `--permission-mode acceptEdits` or `--dangerously-skip-permissions`
- Codex: `--sandbox workspace-write` or `--dangerously-bypass-approvals-and-sandbox`
- Gemini: `--approval-mode auto_edit` or `--approval-mode yolo`

More autonomy means more risk. Run this only against version-controlled project folders.

## Running

Validate first:

```powershell
.\limitshift.ps1 -ValidateOnly
```

```bash
./limitshift.sh --validate-only
```

Dry run prints the exact commands and does not mark tasks done:

```powershell
.\limitshift.ps1 -DryRun
```

```bash
./limitshift.sh --dry-run
```

Run the default queue file:

```powershell
.\limitshift.ps1
```

```bash
./limitshift.sh
```

Use a custom queue path:

```powershell
.\limitshift.ps1 -QueuePath .\my-queue.json
```

```bash
./limitshift.sh --queue ./my-queue.json
```

The console shows only the agent's response text (under a `--- agent response ---` header); the full raw CLI JSON is still written to `outputs/task-NN-<slug>-output.txt`. To print the raw JSON to the console instead (useful for debugging), use:

```powershell
.\limitshift.ps1 -ShowRawOutput
```

```bash
./limitshift.sh --show-raw
```

Keep the machine awake for long runs:

- Windows: adjust sleep settings or use `presentationsettings`
- macOS: `caffeinate -i ./limitshift.sh`
- Linux: `systemd-inhibit ./limitshift.sh`

## State & re-running

LimitShift keeps everything it remembers in one folder, `.limitshift-<queue-name>/`, created next to your queue file. It is built and maintained automatically, and a plain-language `_README.txt` explaining the layout is dropped inside it on every run.

Where state lives and what is in it:

- `sessions/` — saved CLI session / thread ids so a task can resume the **same** conversation.
- `outputs/` — the full raw output of every run, one file per task named `task-NN-<slug>-output.txt` (zero-padded task number plus a slug of the task name).
- `status/` — per-task markers: `task-NN.done` when a task finished, `task-NN.failed` when it blocked or failed.
- `runs.csv` — one row per CLI run with `timestamp, task, run, mode (New/Resume), exit, status`. Open it in any spreadsheet to see what happened across the whole queue.
- `limitshift-log.txt` — the full runner transcript.
- `_README.txt` — the same explanation, right next to the data.

Editing a task auto-invalidates its done marker. When you change a task's `prompt`, `cli`, `projectPath`, `model`, `effort`, or `extraArgs` and run again, LimitShift notices the change (it stores a fingerprint of those fields inside the `.done` file), throws away the stale `.done` marker and the old session id, and **re-runs that task with a fresh session**. Tasks you did not touch keep being skipped.

To re-run **one** finished task by hand, delete its `status/task-NN.done` file. To start **completely over**, delete the whole `.limitshift-<queue-name>/` folder. The entire state folder is safe to delete at any time — LimitShift recreates whatever it needs on the next run.

## Completion marker

When `completionCheck` is `true`, the runner appends `[[TASK_COMPLETE]]` instructions to every prompt automatically. A task is marked done when the **last non-empty line of the response contains** `[[TASK_COMPLETE]]` — so a line like `OK[[TASK_COMPLETE]]` or the marker on its own both count. The marker only counts on that final line, so the agent can mention it earlier in its reply without accidentally completing the task.

If the agent cannot finish, it should end with:

```text
[[TASK_BLOCKED]] <one-line reason>
```

Prompts should therefore describe concrete end conditions such as "write `docs/audit.md` and summarize the changes".

## Troubleshooting

| Message | Meaning | Fix |
| --- | --- | --- |
| `Config file is not valid JSON` | Broken JSON syntax | Check for trailing commas, missing commas, or bad escaping |
| `Task N is missing required JSON property` | A task is missing `name`, `cli`, `projectPath`, or `prompt` | Fix the named field |
| `Allowed values: claude, codex, gemini` | Unsupported `cli` value | Use one of the supported CLIs |
| `Project path does not exist` | `projectPath` is wrong | Fix the path or create the folder |
| `not found on PATH` | Required CLI is not installed or not on PATH | Install the CLI and retry |
| `jq is required but not installed` | Unix runner cannot parse JSON without `jq` | Install `jq` first |
| `Task N exceeded maxRunsPerTask` | The task never finished or kept resuming | Inspect the prompt/output and raise the cap only if needed |
| `installed gemini rejects --resume` | Your Gemini CLI build does not support headless resume | The runner will retry with a continuation prompt |

## Running the tests

PowerShell regression suite (requires Pester 5):

```powershell
Invoke-Pester tests/limitshift.Tests.ps1
```

Install Pester 5 if needed:

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
```

Bash regression suite:

```bash
bash tests/test-limitshift.sh
```

On Windows, run the bash suite from Git Bash, or from PowerShell with:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' tests/test-limitshift.sh
```

## License

MIT. See [`LICENSE`](LICENSE).
