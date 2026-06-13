# Quick Start

> **Set expectations.** There is no guarantee a task finishes exactly as you intended — the result depends on the model, your prompt, and the project. Treat the first run as a draft, refine with follow-up tasks or a better prompt, and **always run against a git-controlled folder** so you can review and revert.

1. **Get the files** - Clone or download this folder.
2. **Trust each project once** - Open every target project in `claude`, `codex`, or `gemini` interactively once so the CLI can finish its trust/onboarding prompt for that folder.
3. **Create your queue** - Copy `limitshift-queue.example-simple.json` to `limitshift-queue.json` and edit it (use a plain-text editor like Notepad, not Word). It is one task with the required fields (`name`, `cli`, `projectPath`, `prompt`) plus `"completionCheck": false` (run the prompt once, only wait if you hit a usage limit) and a permission flag so the AI can actually edit files:

   ```json
   {
     "$schema": "./limitshift-queue.schema.json",
     "tasks": [
       {
         "name": "Document install steps",
         "cli": "claude",
         "projectPath": "C:\\Users\\you\\Documents\\my-project",
         "prompt": "Add an 'Installation' section to README.md with the steps to install this project.",
         "completionCheck": false,
         "extraArgs": ["--permission-mode", "acceptEdits"]
       }
     ]
   }
   ```

   Change `projectPath` to a real git-controlled folder and edit the `prompt`. **On Windows, double every backslash** in paths (`C:\\Users\\me\\proj`); a single `\` breaks JSON. (Forward slashes like `C:/Users/me/proj` also work.) Without the `extraArgs` permission flag the AI runs read-only and won't change files. (The old default name `ai-run-queue.json` is still accepted as a fallback for one release, with a warning to rename it.)

   **Don't want to write JSON?** This folder ships an `AGENTS.md`, so you can open it in Codex/Claude/Gemini and just ask: *"read this folder and fill `limitshift-queue.json` with tasks for my project at `C:\\Users\\me\\proj` — suggest models and use codex."* The agent writes a valid queue for you.
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

- Editing a task's `name`, `prompt`, `cli`, `projectPath`, `model`, `effort`, or `extraArgs` **auto-invalidates** its done marker, so that task re-runs with a fresh session next time.
- To re-run one finished task, delete its `status/task-NN.done` file.
- To start over completely, delete the whole `.limitshift-limitshift-queue/` folder.
- The entire state folder is **safe to delete at any time** — it is rebuilt on the next run.
