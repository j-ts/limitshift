# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Multi-line prompts on Windows (the "stuck in a loop" bug)**: prompts are now delivered to every CLI on **stdin** instead of as a process argument. Passing a multi-line prompt as an argument through `Start-Process` and the npm `.cmd` shim silently truncated it to (almost) nothing, so the agent never saw the task, never emitted the completion marker, and the runner resumed in a token-burning loop until `maxRunsPerTask`.
- **Completion-marker detection**: a task is now marked done when the **last non-empty line *contains*** `[[TASK_COMPLETE]]` (e.g. `OK[[TASK_COMPLETE]]`, or the marker with trailing whitespace), not only when the line is exactly the marker. `[[TASK_BLOCKED]] <reason>` is detected the same way, checked first.
- **Resume prompt loses the task**: on resume the runner now repeats the **original prompt verbatim** (including any `/goal …` line) alongside the "continue where you stopped" instruction, so a thin first run or a fresh session has the full task to work from.
- **Output-file encoding**: per-task output and the usage capture are written as **UTF-8 without BOM** (were UTF-16/Tee-Object), so they are greppable and parseable.

### Added
- **`--queue-path` flag:** explicit alias for `--queue` in bash (PowerShell's `-QueuePath` already existed). A bare filename (no path separators) resolves from the script's own directory, so `--queue-path surgemesh-queue.json` just works next to the script.
- **Isolated state per queue file:** each queue file always had its own `.limitshift-<name>/` folder; this is now the documented, first-class multi-queue workflow. Run one terminal per queue to parallelize projects.
- **Concurrency lock:** a `limitshift.lock` file in the queue's state folder prevents two runners from using the same queue simultaneously. If a second run detects an active lock it exits with a clear error naming the queue and the running PID. Stale locks (dead PID) are silently cleared.
- **Dynamic model validation:** runtime capability discovery queries `agy models` and validates configured model names against the live list during `--validate-only` / `-ValidateOnly`. `claude`, `codex`, `gemini`, and `copilot` currently have no scriptable model list — they print an INFO message and are never blocked.
- **Typo suggestions:** when a model name is not found in the discovered list, LimitShift suggests the nearest known model names using Levenshtein edit distance (threshold 4).
- **Capability cache:** discovered model lists are cached under `.limitshift-<queue>/capabilities/<cli>.json` next to the queue file. Configure TTL with `settings.capabilityCacheHours` (default 24 h; set 0 to always refresh).
- **`settings.modelValidation`:** `"strictWhenDiscoverable"` (default — fail when a discoverable CLI's model is absent) · `"warn"` (warn but continue) · `"off"` (skip model-name checks).
- **`--refresh-capabilities` / `-RefreshCapabilities`:** ignore the cached capability file and re-query the CLI for a fresh model list.
- **`--probe-models` / `-ProbeModels`:** opt-in connectivity probe — runs a cheap non-editing prompt per unique CLI during `--validate-only` only (never during normal queue execution). Also configurable via `settings.probeModels: true`.
- **GitHub Copilot CLI Support**: Added `copilot` as a first-class fifth `cli`.
  - Supports session persistence via `--name` (new) and `--resume` (resumed).
  - Supports reasoning effort (`--effort` / `--reasoning-effort`) with levels `low`, `medium`, `high`, `xhigh`, `max`.
  - Supports model selection via `--model`.
  - Delivers prompt via `-p` argument; hands it an **empty/EOF stdin** so it cannot block.
  - Robust structured JSONL output parsing and automated usage-limit recovery.
  - Install/login flow: install the GitHub CLI extension with `gh extension install github/gh-copilot`, then run `copilot login`.
  - Recommended permission flags: `--allow-tool=read,write,shell(npm:*),shell(npx:*),shell(git:*) --deny-tool=shell(git push) --no-ask-user` (automation mode: `--allow-all --no-ask-user`).
- **Antigravity CLI (`agy`) support**: `agy` is now a first-class fourth `cli`, alongside `claude`, `codex`, and `gemini` — Google's official successor to Gemini CLI for individual Google AI Pro/Ultra accounts. Its rough edges are handled transparently:
  - **No headless output → read from agy's transcript store.** In `-p`/`--print` mode agy renders its reply to a TTY, so a captured/redirected stdout is empty and there is no `--output-format json`. LimitShift instead recovers the reply from agy's own conversation store: `~/.gemini/antigravity-cli/cache/last_conversations.json` maps the absolute workspace path to a conversation id, and the **last `PLANNER_RESPONSE`** in `…/brain/<id>/.system_generated/logs/transcript.jsonl` is the agent's user-facing message (which is what completion-marker / stall detection then runs on). It falls back to the captured stdout when no transcript reply is found. The store location can be overridden with `LIMITSHIFT_AGY_DATA_DIR`. Because output capture no longer depends on the exit code (which is unreliable under redirection), an agy run is treated as successful exactly when a response was recovered.
  - **No per-conversation session ids.** Resume continues the most recent conversation with `agy -c` (driven by a sentinel session marker), so agy tasks are inherently sequential.
  - The prompt is passed as the value of `-p` (agy does not read it from stdin); agy is still handed an **empty/EOF stdin** so it cannot block on an inherited handle. `--model` is passed through; there is **no `effort` flag** (validation requires `null`) and **no Ollama path**. Permission flag: `--dangerously-skip-permissions`.
  - On Windows, native-exe arguments are delivered as a single canonical command-line string (`ConvertTo-WindowsArgString`), so agy's whole multi-line `-p` prompt survives `CreateProcess` intact (this also fixes spaces in command/project paths for the other native-exe CLIs).
- **Local models via Ollama**: a task can target a local [Ollama](https://ollama.com) model by setting `model` to the model name and adding `["--oss", "--local-provider", "ollama"]` to `extraArgs` — the same shape for both CLIs. `codex` passes the flags through natively; `claude`, which has no native Ollama flag, is run as `ollama launch claude --model <model> --yes -- <claude args>` (the model goes to the launcher, the provider flags are stripped from claude's own args). A local `claude` task **requires** a `model` (enforced at validation) and `ollama` on PATH, and skips the cloud usage pre-check since local runs never hit usage limits.
- **Optional completion checking (`completionCheck`)**: new `settings.completionCheck` (default `true`) with a per-task override. Set it to `false` for "simple mode" — the prompt is sent **verbatim** (no automation instructions appended) and the task is marked done after the first successful run; the only reason to resume is a usage limit.
- **No-progress stall guard (`maxStalls`, default 2)**: in completion-check mode, if the agent returns the same response with no marker `maxStalls` times in a row, the task is failed instead of looping to `maxRunsPerTask`.
- **Clean console output**: the terminal shows just the agent's response under an `--- agent response ---` header (claude `result` / codex final message / gemini `response`); the full raw JSON still goes to the per-task output file. `-ShowRawOutput` / `--show-raw` restores raw-JSON printing.
- **Per-task model rotation (`model` may be an array)**: `tasks[].model` accepts a single string or an ordered list. On a usage limit the runner switches to the next model **immediately** (resuming the same session) and only waits for a reset once every listed model is limit-exhausted, then restarts from the first model. The current model index is persisted per task.
- **Fingerprint-based done invalidation**: each `.done`/`.failed` marker stores a SHA-256 fingerprint of the task definition (name, cli, projectPath, model, effort, prompt, extraArgs). Editing any of those in the queue now **auto-invalidates** the marker so the task re-runs (and its stale session is dropped) — no more manually deleting state after a prompt edit.
- **Self-documenting state directory**: each state folder gets a generated `_README.txt` explaining the layout and how to re-run; a `runs.csv` at the state root records one row per run (timestamp, task, run, mode, exit, status); per-task output files are named `task-NN-<slug>-output.txt`.
- **Per-CLI effort validation**: misconfigured `effort` now fails at validation with a task-numbered message — gemini must use `effort: null`, claude accepts `low|medium|high|xhigh|max` (and rejects `ultracode`, and requires `null` for haiku models), codex accepts `minimal|low|medium|high|xhigh` (rejects plan-mode-only `none`).
- **`AGENTS.md` (ask your agent to write the queue)**: ships an `AGENTS.md` (plus `CLAUDE.md` / `GEMINI.md` pointers) that teaches an AI coding tool how to build a valid `limitshift-queue.json` from a plain-language draft — correct fields, sensible model suggestions, per-CLI effort rules, and the permission flag needed to edit files. Open this folder in your agent and ask it to fill the queue instead of writing JSON by hand.
- **Example queues**: ship `limitshift-queue.example-simple.json` (one task, required fields only, `completionCheck: false`), `limitshift-queue.example-advanced.json` (every optional field), and `limitshift-queue.example-workflow.json` (a review → fix → verify pipeline). The legacy `limitshift-queue.example.json` is a copy of the simple example. A regression test in both suites validates all four shipped examples with `-ValidateOnly` / `--validate-only`.
- **Beginner-friendly README**: top-down rewrite aimed at people who use Codex/Claude/Gemini as an app and have never used a terminal — what it is, why in-app queues stall on usage limits, an expectations callout, a first-run walkthrough, a real review→fix→verify workflow, the "ask your agent" shortcut, and an advanced example. Reference material moved under a `## Reference` heading.

### Changed
- **Naming alignment**: renamed the runner scripts to `limitshift.ps1` / `limitshift.sh`, the default queue file to `limitshift-queue.json`, the shipped example/schema to `limitshift-queue.example.json` / `limitshift-queue.schema.json`, the per-queue state folder to `.limitshift-<queue-name>/` (was `.ai-runner-<queue-name>/`), and the in-folder log to `limitshift-log.txt`.
- **Automatic state-folder migration**: on startup the runner renames an existing `.ai-runner-<queue-name>/` folder to `.limitshift-<queue-name>/` when the new one does not yet exist.
- **Legacy queue filename fallback**: when no queue path is given, the runner uses `limitshift-queue.json` if present, otherwise falls back to the old `ai-run-queue.json` with a warning.

### Deprecated
- The old `run-ai.ps1` / `run-ai.sh` script names now exist only as thin forwarder stubs that print a deprecation warning and call the new `limitshift.ps1` / `limitshift.sh` scripts. These forwarders, and the `ai-run-queue.json` legacy queue-filename fallback, will be **removed in the next release** — switch to the new names.

## [1.0.0] - 2026-06-12

### Added
- **Multi-CLI Support**: Native integration for Claude Code (`claude`), Codex (`codex`), and Gemini CLI (`gemini`).
- **Cross-Platform Runners**: Added PowerShell `run-ai.ps1` (Windows PowerShell 5.1+) and Bash `run-ai.sh` (macOS/Linux compatible down to Bash 3.2).
- **Validation Modes**: Added configuration validation checks (`-ValidateOnly` / `--validate-only`) to check JSON syntax, task schema requirements, folder existence, and tool bin availability at startup.
- **Dry-run Execution**: Support for dry-run simulation (`-DryRun` / `--dry-run`) to preview command line construction.
- **Structured JSON Parsing**: Replaced regex console scraping with structured JSON/JSONL output parsing and automated limit wait recovery.
- **Regression Tests**: Added a Pester 5 suite for PowerShell and a pure Bash test harness for the Unix runner.
