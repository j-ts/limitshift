# Quick Start

1. **Get the files** — Clone or download this folder.
2. **Check your CLI works headless** — Open the project folder you will automate and run your target CLI (`claude`, `codex`, or `gemini`) once interactively to accept its trust prompt for that folder.
3. **Create your queue** — Copy `ai-run-queue.example.json` to `ai-run-queue.json` (in the same folder as the script) and edit it. Define one entry per task containing `name`, `cli` (`claude`, `codex`, or `gemini`), `projectPath`, and `prompt`. Note that on Windows, paths in JSON must escape backslashes: `"C:\\Users\\me\\proj"`.
4. **Validate** —
   - Windows: `.\run-ai.ps1 -ValidateOnly`
   - macOS/Linux: `./run-ai.sh --validate-only`
   
   Fix any syntax errors or missing paths/binaries identified by the validator.
5. **Dry run (optional)** — Running with `-DryRun` or `--dry-run` prints the exact CLI commands that will execute without actually running them.
6. **Run** —
   - Windows: `.\run-ai.ps1`
   - macOS/Linux: `./run-ai.sh`
   
   Keep the machine awake (e.g. on macOS: `caffeinate -i ./run-ai.sh`). Logs and output state will land in a folder named `.ai-runner-ai-run-queue/` next to your queue JSON file.
