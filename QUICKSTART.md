# Quick Start

1. **Get the files** - Clone or download this folder.
2. **Trust each project once** - Open every target project in `claude`, `codex`, or `gemini` interactively once so the CLI can finish its trust/onboarding prompt for that folder.
3. **Create your queue** - Copy `limitshift-queue.example.json` to `limitshift-queue.json` and edit it. Each task needs `name`, `cli`, `projectPath`, and `prompt`. Windows paths must escape backslashes: `"C:\\Users\\me\\proj"`. (The old default name `ai-run-queue.json` is still accepted as a fallback for one release, with a warning to rename it.)
4. **Validate**
   Windows: `.\limitshift.ps1 -ValidateOnly`
   macOS/Linux: `./limitshift.sh --validate-only`
5. **Dry run (optional)** - `-DryRun` / `--dry-run` prints commands only and does not mark tasks done.
6. **Run**
   Windows: `.\limitshift.ps1`
   macOS/Linux: `./limitshift.sh`

The scripts were renamed from `run-ai.ps1` / `run-ai.sh`; the old names still work for one release as deprecated forwarders that call the new scripts.

Keep the machine awake for long runs. On macOS, for example: `caffeinate -i ./limitshift.sh`.

## State & re-running

All of LimitShift's memory lives in one folder, `.limitshift-limitshift-queue/`, next to your queue file. It holds three subfolders — `sessions/` (resume ids), `outputs/` (full run output), and `status/` (`.done` / `.failed` markers) — plus `runs.csv` (one row per run), the transcript `limitshift-log.txt`, and a `_README.txt` describing it all.

- Editing a task's `prompt`, `cli`, `projectPath`, `model`, `effort`, or `extraArgs` **auto-invalidates** its done marker, so that task re-runs with a fresh session next time.
- To re-run one finished task, delete its `status/task-NN.done` file.
- To start over completely, delete the whole `.limitshift-limitshift-queue/` folder.
- The entire state folder is **safe to delete at any time** — it is rebuilt on the next run.
