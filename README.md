# LimitShift

Queue long-running prompts for Claude Code, Codex, or Gemini CLI, run them headless one by one, and survive usage limits without losing the session. Start it before bed, let the runner wait out quota resets, and inspect the output in the morning.

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

## Configuration reference

The queue file is `limitshift-queue.json` by default. Copy [`limitshift-queue.example.json`](limitshift-queue.example.json) and edit it. (The old default name `ai-run-queue.json` is still accepted as a fallback for one release — the runner uses it if `limitshift-queue.json` is absent and prints a warning telling you to rename it.)

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
| `tasks[].projectPath` | string | yes | none | Folder the CLI runs inside |
| `tasks[].prompt` | string | yes | none | Task prompt |
| `tasks[].model` | string or array of strings | no | none | Passed through where supported. An array lists models in preference order; on a usage limit the runner rotates to the next model (see below). Primarily useful for gemini |
| `tasks[].effort` | string | no | none | `low`, `medium`, `high`; Gemini ignores it |
| `tasks[].completionCheck` | boolean | no | inherits `settings.completionCheck` | Per-task override of completion checking |
| `tasks[].extraArgs` | string or array | no | none | Extra CLI flags |

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

The runner appends `[[TASK_COMPLETE]]` instructions to every prompt automatically. A task is only marked done when the final non-empty line is exactly `[[TASK_COMPLETE]]`.

If the agent cannot finish, it should end with:

```text
[[TASK_BLOCKED]] <one-line reason>
```

Prompts should therefore describe concrete end conditions such as “write `docs/audit.md` and summarize the changes”.

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
