# Quick Start

> **Set expectations.** There is no guarantee a task finishes exactly as you intended — the result depends on the model, your prompt, and the project. Treat the first run as a draft, refine with follow-up tasks or a better prompt, and **always run against a git-controlled folder** so you can review and revert.

1. **Get the files** - Clone or download this folder.
2. **Trust each project once** - Open every target project in `claude`, `codex`, `gemini`, `agy`, or `copilot` interactively once so the CLI can finish its trust/onboarding prompt for that folder.
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

   **Don't want to write JSON?** This folder ships an `AGENTS.md`, so you can open it in `claude`, `codex`, `gemini`, `agy`, or `copilot` and ask: *"read this folder and fill `limitshift-queue.json` with tasks for my project at `C:\\Users\\me\\proj` — suggest models and use codex."* The agent writes a valid queue for you.
4. **Validate**
   Windows: `.\limitshift.ps1 -ValidateOnly`
   macOS/Linux: `./limitshift.sh --validate-only`
5. **Dry run (optional)** - `-DryRun` / `--dry-run` prints commands only and does not mark tasks done.
6. **Run**
   Windows: `.\limitshift.ps1`
   macOS/Linux: `./limitshift.sh`

The console prints only the agent's reply under a `--- agent response ---` header; the full raw CLI JSON is saved under the state folder. For every optional field (models, effort, rotation, permissions, the `[[TASK_COMPLETE]]` workflow), see `limitshift-queue.example-advanced.json` and the README Reference section.

**Antigravity (`agy`):** the fourth supported CLI — Google's replacement for Gemini CLI on personal Google AI Pro/Ultra accounts. Install it without Node (`irm https://antigravity.google/cli/install.ps1 | iex` on Windows, `curl -fsSL https://antigravity.google/cli/install.sh | bash` on Mac/Linux), set `"cli": "agy"`, and use `["--dangerously-skip-permissions"]` as its permission flag. agy has no `effort` (leave it `null`) and no Ollama path.

**GitHub Copilot CLI (`copilot`):** the fifth supported CLI. Install GitHub CLI first if needed, then run `gh extension install github/gh-copilot` and `copilot login`. Set `"cli": "copilot"`, and use `["--allow-tool=read,write,shell(npm:*),shell(npx:*),shell(git:*)", "--deny-tool=shell(git push)", "--no-ask-user"]` as the recommended edit permission flags. `["--allow-all", "--no-ask-user"]` is full automation mode and should be used only when you fully trust the task. Copilot supports `effort` levels `low`, `medium`, `high`, `xhigh`, `max`; it does not currently expose a scriptable model-list command, so model names are passed through as-is. LimitShift sends the prompt via `-p`, uses `--name` / `--resume=<session-id>` for session identity, forces `--output-format=json --stream=off --no-ask-user`, and parses Copilot's JSONL output.

**Local models:** to run a task on a local [Ollama](https://ollama.com) model, set `model` to the Ollama model name and add `["--oss", "--local-provider", "ollama"]` to `extraArgs`. This works for `codex` and `claude` **only** (for claude, LimitShift runs it via `ollama launch claude --model <model> --yes -- …`). See the README's [Run with local models through Ollama](README.md#run-with-local-models-through-ollama). (agy and copilot have no Ollama path.)

The scripts were renamed from `run-ai.ps1` / `run-ai.sh`; the old names still work for one release as deprecated forwarders that call the new scripts.

Keep the machine awake for long runs. On macOS, for example: `caffeinate -i ./limitshift.sh`.

## State & re-running

All of LimitShift's memory lives in one folder, `limitshift-limitshift-queue/`, next to your queue file. It holds three subfolders — `sessions/` (resume ids), `outputs/` (full run output), and `status/` (`.done` / `.failed` markers) — plus `runs.csv` (one row per run), the transcript `limitshift-log.txt`, and a `_README.txt` describing it all.

- Editing a task's `name`, `prompt`, `cli`, `projectPath`, `model`, `effort`, or `extraArgs` **auto-invalidates** its done marker, so that task re-runs with a fresh session next time.
- To re-run one finished task, delete its `status/task-NN.done` file.
- To start over completely, delete the whole `limitshift-limitshift-queue/` folder.
- The entire state folder is **safe to delete at any time** — it is rebuilt on the next run.

## Running multiple queues in parallel

Create one queue JSON per project, then open a separate terminal for each:

```powershell
# terminal 1
.\limitshift.ps1 -QueuePath project-a-queue.json

# terminal 2
.\limitshift.ps1 -QueuePath project-b-queue.json
```
```bash
# terminal 1
./limitshift.sh --queue-path project-a-queue.json

# terminal 2
./limitshift.sh --queue-path project-b-queue.json
```

Each queue keeps its state in its own `limitshift-<name>/` folder. If you accidentally start the same queue twice, the second run exits immediately with an error — you'll see the PID of the first run in the message.
