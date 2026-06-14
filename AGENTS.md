# AGENTS.md - LimitShift agent guide

This repository contains **LimitShift**, a small cross-platform queue runner for AI coding CLIs
(`claude`, `codex`, `gemini`, `agy`, and `copilot`). Your most common task is to convert a user's rough draft into a
valid `limitshift-queue.json` that LimitShift can run.

`agy` is the **Antigravity CLI**, Google's official successor to Gemini CLI for individual Google AI
Pro/Ultra accounts (Gemini CLI stays for enterprise). It is fully supported, with two caveats baked
into the runner: it has **no headless output mode** — in `-p` print mode it renders the reply to a
TTY, so LimitShift recovers the reply from agy's local conversation store
(`~/.gemini/antigravity-cli/.../transcript.jsonl`) instead of from stdout — and it has **no
per-conversation session IDs**, so resume works only by continuing the most recent conversation
(`agy -c`) and agy tasks are inherently sequential. Both are handled for you; you just pick `agy` as
the `cli`. (The user must have agy installed and signed in, same as any other CLI.)

## Default Scope

- Unless the user explicitly asks for something else, edit only `limitshift-queue.json`.
- If the user asks to change docs, scripts, tests, or this file, keep the edit limited to the named files.
- Do not modify the user's target project. Queue tasks should point at it through `projectPath`.
- Treat this file as the canonical agent manifest. `CLAUDE.md` and `GEMINI.md` are compatibility
  shims that point back here.

## Repository Map

- `limitshift.ps1` - Windows runner and validator.
- `limitshift.sh` - macOS/Linux runner and validator.
- `limitshift-queue.schema.json` - authoritative queue schema. Read this before editing a queue.
- `limitshift-queue.example-simple.json` - minimal one-task queue.
- `limitshift-queue.example-workflow.json` - review -> fix -> verify workflow.
- `limitshift-queue.example-advanced.json` - model, effort, rotation, and completion-check examples.
- `tests/` - PowerShell and Bash regression tests for runner changes.
- `README.md` and `QUICKSTART.md` - user-facing docs.

## Queue-Building Workflow

1. Read the user's draft, target project path, preferred CLI, and any model preference.
2. Read `limitshift-queue.schema.json`; keep the queue schema-compliant.
3. Rewrite vague requests into ordered, self-contained tasks. Each prompt must name relevant files
   and define what "done" looks like.
4. Use the user's real absolute `projectPath`. If it is unknown, ask for it, or use the current
   folder only when that is clearly what the user wants.
5. Add the required permission flag in `extraArgs` for every task that should edit files.
6. Validate before reporting back:
   - Windows: `.\limitshift.ps1 -ValidateOnly`
   - macOS/Linux: `./limitshift.sh --validate-only`

## Queue Schema Essentials

Each task must include:

- `name` - short human label.
- `cli` - one of `claude`, `codex`, `gemini`, `agy`, or `copilot`; use the user's requested CLI when specified.
- `projectPath` - absolute folder for the CLI run. Windows paths need escaped backslashes
  (`"C:\\Users\\me\\project"`) or forward slashes (`"C:/Users/me/project"`).
- `prompt` - concrete task instruction, including files to inspect/edit and completion criteria.

Useful optional fields:

- `model` - a string or an array in preference order for model rotation on usage limits.
- `effort` - CLI-specific reasoning effort; omit or set `null` when unsupported.
- `completionCheck` - `true` for multi-step work that should resume until `[[TASK_COMPLETE]]`;
  `false` for one-shot prompts.
- `extraArgs` - CLI flags. Use array form for reliability.

## Model and Effort Guidance

- Codex: use `gpt-5.5` or `gpt-5.4` for substantive coding/reasoning; use `gpt-5.4-mini` for quick
  or repetitive edits. Effort: `minimal`, `low`, `medium`, `high`, or `xhigh`. Do not use
  deprecated `gpt-5-codex`, `gpt-5.2`, or codex effort `none`.
- Claude: use `opus` for the hardest work, `sonnet` for everyday tasks, and `haiku` for cheap/simple
  tasks. Effort: `low`, `medium`, `high`, `xhigh`, or `max`; omit effort for Haiku.
- Gemini: use `gemini-3-flash-preview` or `gemini-2.5-flash` for speed; use
  `gemini-2.5-pro` or `gemini-3.1-pro-preview` for depth. Omit `effort` or set it to `null`.
  Model arrays are especially useful for Gemini limit rotation.
- Antigravity (`agy`): run `agy models` to see what the account can use; pass the chosen name as
  `model`. Omit `effort` or set it to `null` (agy has no `--effort` flag).

> **Schema note:** `limitshift-queue.schema.json` validates `model` as a string or non-empty string array — it does not enumerate provider model names. Do not update the schema to add new model names; they are discovered at runtime from the CLI during `--validate-only`.

  agy has no headless output
  and no isolated sessions, so keep agy work to a single linear chain of tasks; completion-marker
  checking (`completionCheck: true`) still works because the runner recovers agy's reply from its
  conversation transcript.
- GitHub Copilot CLI (`copilot`): run `copilot models` to see what your account can use; pass the
  chosen name as `model`. Effort: `low`, `medium`, `high`, `xhigh`, `max`. Copilot delivers prompts
  via `-p`, uses `--name` / `--resume` for session identity, returns structured JSONL, and supports
  `--output-format=json`, `--stream=off`, `--no-ask-user`, `--allow-tool`, `--deny-tool`, and
  `--allow-all` / `--yolo`-style permission bypass where appropriate.

## Permission Flags

Headless CLI runs cannot answer permission prompts. If a task should edit files, include:

- Claude: `["--permission-mode", "acceptEdits"]`
- Codex: `["--sandbox", "workspace-write"]`
- Gemini: `["--approval-mode", "auto_edit"]`
- Antigravity (`agy`): `["--dangerously-skip-permissions"]` (agy's only headless auto-approve; it
  has no softer "accept edits only" mode).
- Copilot: recommended edit args are `["--allow-tool=read,write,shell(npm:*),shell(npx:*),shell(git:*)", "--deny-tool=shell(git push)", "--no-ask-user"]`; full automation mode is `["--allow-all", "--no-ask-user"]` and should only be used when you fully trust the task.

Without these flags, the agent may run read-only and leave the project unchanged.

## Local Models (Ollama)

To run a task against a local Ollama model, set `model` to the Ollama model name (e.g. `qwen3.5:9b`
or `nemotron-3-nano:4b`) and add `["--oss", "--local-provider", "ollama"]` to `extraArgs`. The same
shape works for both CLIs:

- `codex` reaches Ollama natively — the flags pass straight through to `codex exec`.
- `claude` has no native Ollama flag, so LimitShift runs it via
  `ollama launch claude --model <model> --yes -- <claude args>`. The `model` is therefore
  **required** for a local `claude` task (validation rejects it otherwise), and `ollama` must be on
  PATH alongside `claude`.

A local task that should edit files still needs its permission flag in `extraArgs` — the
local-provider flags only choose the model. List both, e.g.
`["--oss", "--local-provider", "ollama", "--permission-mode", "acceptEdits"]`. Gemini, agy, and copilot
have no Ollama path here.

## Prompt Quality Bar

- Match prompt detail to the chosen tool and model. A capable model with a precise task can take a
  short prompt; cheaper/smaller models, or broad and fuzzy goals, need step-by-step detail, named
  files, and an explicit definition of "done". Don't pad a clear task, and don't under-specify a vague one.
- For a short or vague draft (for example "audit the whole repo code"), with `claude` or `codex` you
  may begin the `prompt` with the `/goal` command (e.g. `/goal audit the whole repo and write the
  findings to audit.md`) so the agent sets its own success criteria and keeps working until they are
  met. (Gemini has no `/goal`.)
- Prefer explicit file paths and artifacts over broad requests.
- Split multi-stage work into separate tasks, because each task is its own CLI run.
- Chain outputs intentionally, for example: write `bugs.md`, then fix entries in `bugs.md`, then
  verify and mark each entry.
- Ask agents to summarize changed files and verification commands in their final response.
- Use `completionCheck: true` for tasks that may need multiple resumes; prompts should end by
  emitting `[[TASK_COMPLETE]]` or `[[TASK_BLOCKED]] <reason>`.

## Multiple Queues

The recommended workflow when a user wants to work on two or more projects at the same time is **one queue file per project**, named after the project (e.g. `surgemesh-queue.json`, `papertrade-queue.json`). Each queue gets its own isolated state folder automatically (`​.limitshift-surgemesh-queue/`, etc.).

To run multiple queues in parallel the user opens separate terminals:
```powershell
.\limitshift.ps1 -QueuePath surgemesh-queue.json   # terminal 1
.\limitshift.ps1 -QueuePath papertrade-queue.json  # terminal 2
```

A bare filename passed as `-QueuePath` / `--queue-path` resolves from the script's own folder, so the file just needs to exist there. An absolute path works too.

Mixed-project queues (all tasks in one file, using per-task `projectPath`) are still supported and work fine — they just can't be parallelised across separate runs. Recommend separate queues whenever isolation matters.

## Good Local Examples

- Minimal queue shape: `limitshift-queue.example-simple.json`.
- Multi-task workflow: `limitshift-queue.example-workflow.json`.
- Advanced options and model rotation: `limitshift-queue.example-advanced.json`.

Avoid:

- Inventing fields not present in `limitshift-queue.schema.json`.
- Leaving placeholder paths such as `C:\\Users\\you\\project` in the final queue.
- Using unescaped Windows backslashes in JSON.
- Choosing a model/effort combination that validation rejects.
- Omitting `extraArgs` on tasks expected to modify files.

## Security and Safety

- Never put API keys, tokens, passwords, private URLs, customer data, or production secrets in
  `AGENTS.md`, prompts, or queue files.
- Refer to where secrets live, not to their values.
- Do not run destructive commands, push commits, install packages, or apply infrastructure changes
  unless the user explicitly asks for that work.
- If validation or a task requirement is ambiguous, ask a concise clarifying question before guessing.

## Runner Development

Only use this section when the user explicitly asks to modify LimitShift itself.

- PowerShell tests: `Invoke-Pester tests/limitshift.Tests.ps1`
- Bash tests: `bash tests/test-limitshift.sh`
- Validate representative queues with `.\limitshift.ps1 -ValidateOnly` or
  `./limitshift.sh --validate-only`.
- Keep README and examples synchronized when schema or behavior changes.
