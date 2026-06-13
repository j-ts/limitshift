# Quick Start

1. **Get the files** - Clone or download this folder.
2. **Trust each project once** - Open every target project in `claude`, `codex`, or `gemini` interactively once so the CLI can finish its trust/onboarding prompt for that folder.
3. **Create your queue** - Copy `ai-run-queue.example.json` to `ai-run-queue.json` and edit it. Each task needs `name`, `cli`, `projectPath`, and `prompt`. Windows paths must escape backslashes: `"C:\\Users\\me\\proj"`.
4. **Validate**
   Windows: `.\run-ai.ps1 -ValidateOnly`
   macOS/Linux: `./run-ai.sh --validate-only`
5. **Dry run (optional)** - `-DryRun` / `--dry-run` prints commands only and does not mark tasks done.
6. **Run**
   Windows: `.\run-ai.ps1`
   macOS/Linux: `./run-ai.sh`

Keep the machine awake for long runs. On macOS, for example: `caffeinate -i ./run-ai.sh`.

## State & re-running

All of LimitShift's memory lives in one folder, `.ai-runner-ai-run-queue/`, next to your queue file. It holds three subfolders — `sessions/` (resume ids), `outputs/` (full run output), and `status/` (`.done` / `.failed` markers) — plus `runs.csv` (one row per run), the transcript `ai-run-log.txt`, and a `_README.txt` describing it all.

- Editing a task's `prompt`, `cli`, `projectPath`, `model`, `effort`, or `extraArgs` **auto-invalidates** its done marker, so that task re-runs with a fresh session next time.
- To re-run one finished task, delete its `status/task-NN.done` file.
- To start over completely, delete the whole `.ai-runner-ai-run-queue/` folder.
- The entire state folder is **safe to delete at any time** — it is rebuilt on the next run.
