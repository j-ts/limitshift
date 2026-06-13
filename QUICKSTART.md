# Quick Start

> **Set expectations.** There is no guarantee a task finishes exactly as you intended — the result depends on the model, your prompt, and the project. Treat the first run as a draft, refine with follow-up tasks or a better prompt, and **always run against a git-controlled folder** so you can review and revert.

1. **Get the files** - Clone or download this folder.
2. **Trust each project once** - Open every target project in `claude`, `codex`, or `gemini` interactively once so the CLI can finish its trust/onboarding prompt for that folder.
3. **Create your queue** - Copy `limitshift-queue.example-simple.json` to `limitshift-queue.json` and edit it. It is one task with only the required fields (`name`, `cli`, `projectPath`, `prompt`) plus `"completionCheck": false`, which just runs your prompt once and only waits if you hit a usage limit:

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

   Change `projectPath` to a real git-controlled folder and edit the `prompt`. On Windows, escape backslashes: `"C:\\Users\\me\\proj"`. (The old default name `ai-run-queue.json` is still accepted as a fallback for one release, with a warning to rename it.)
4. **Validate**
   Windows: `.\limitshift.ps1 -ValidateOnly`
   macOS/Linux: `./limitshift.sh --validate-only`
5. **Dry run (optional)** - `-DryRun` / `--dry-run` prints commands only and does not mark tasks done.
6. **Run**
   Windows: `.\limitshift.ps1`
   macOS/Linux: `./limitshift.sh`

The console prints only the agent's reply under a `--- agent response ---` header; the full raw CLI JSON is saved under the state folder. For every optional field (models, effort, rotation, permissions, the `[[TASK_COMPLETE]]` workflow), see `limitshift-queue.example-advanced.json` and the README Reference section.

The scripts were renamed from `run-ai.ps1` / `run-ai.sh`; the old names still work for one release as deprecated forwarders that call the new scripts.

Keep the machine awake for long runs. On macOS, for example: `caffeinate -i ./limitshift.sh`.

## State & re-running

All of LimitShift's memory lives in one folder, `.limitshift-limitshift-queue/`, next to your queue file. It holds three subfolders — `sessions/` (resume ids), `outputs/` (full run output), and `status/` (`.done` / `.failed` markers) — plus `runs.csv` (one row per run), the transcript `limitshift-log.txt`, and a `_README.txt` describing it all.

- Editing a task's `prompt`, `cli`, `projectPath`, `model`, `effort`, or `extraArgs` **auto-invalidates** its done marker, so that task re-runs with a fresh session next time.
- To re-run one finished task, delete its `status/task-NN.done` file.
- To start over completely, delete the whole `.limitshift-limitshift-queue/` folder.
- The entire state folder is **safe to delete at any time** — it is rebuilt on the next run.
