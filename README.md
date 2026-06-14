<h1 align="center">LimitShift</h1>

<p align="center">
  <strong>Give your AI coding CLI a to-do list and walk away — when you hit your usage limit, LimitShift waits for the reset and picks up exactly where it left off.</strong>
</p>

<p align="center">
  <a href="#what-is-limitshift">What is it</a> ·
  <a href="#why-limitshift">Why</a> ·
  <a href="#key-features">Features</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="#write-your-to-do-list">Write your list</a> ·
  <a href="#run-it">Run it</a> ·
  <a href="#reference">Reference</a>
</p>

---

## What is LimitShift?

LimitShift is a tiny terminal app that runs **Codex, Claude, Gemini, Antigravity (`agy`), or GitHub Copilot (`copilot`)** through a list of tasks, one at a time. It drives the *command-line* version of those tools — if you've only ever used the app, you install the matching CLI once and sign in with the same account.

You write your tasks in one list and start it. When a tool says *"you're out of quota,"* LimitShift doesn't quit — it **sleeps until your quota resets, then continues the same conversation.** Start a big list before bed and wake up to the work done (or as far as it got).

You don't need to be a programmer. You do need to open a terminal once or twice — every step is spelled out.

> ⚠️ **Treat first runs as rough drafts.** The result depends on the model, your wording, and the project. Only point LimitShift at a folder backed up with **Git**, so you can review and undo anything you don't like.

---

## Why LimitShift?

|  | Using the app or CLI directly | **LimitShift** |
| --- | --- | --- |
| You hit a usage limit mid-task | You stop and lose your place | **Waits for the reset, then resumes the same conversation** |
| A long list of changes | Babysit each one by hand | **Queue them once and walk away** |
| More than one AI tool | Switch tools manually | **Mix `claude`, `codex`, `gemini`, `agy`, `copilot` in one queue** |
| Overnight / unattended runs | Not really possible | **Start before bed, done by morning** |
| Running a local model | Look up the flags every time | **Built-in [Ollama](#run-with-local-models-through-ollama) support** |

---

## Key Features

- **Usage-limit aware** — detects the cap, works out when it resets, waits, and resumes the *same* session so the AI keeps its memory.
- **Five CLIs, one queue** — `claude`, `codex`, `gemini`, Antigravity (`agy`), and `copilot`, mixable task by task.
- **[Model rotation](#model-rotation)** — give a task a list of models and it switches the instant one is capped, with no waiting.
- **[Completion checking](#completion-checking)** — keeps nudging a task across several rounds until the AI signals it's genuinely done.
- **[Local models via Ollama](#run-with-local-models-through-ollama)** — run `claude` or `codex` against a model on your own machine.
- **Resumable & safe** — press Ctrl+C anytime; progress is saved, and it's built for Git-backed folders so nothing is lost.
- **Cross-platform, no build step** — one PowerShell script for Windows, one Bash script for Mac/Linux.

---

## Get started

You need a **Windows, Mac, or Linux** computer, at least one AI CLI (`claude`, `codex`, `gemini`, `agy`, or `copilot`), and a project folder tracked by **Git**. Pick the path that sounds like you:

### 🐣 New to the terminal

No command-line experience needed — this uses buttons, links, and copy-paste.

1. **Open a terminal** (where you type commands instead of clicking):
   - **Windows:** Start button → type **PowerShell** → open **Windows PowerShell**.
   - **Mac:** `Cmd+Space` → type **Terminal** → Enter.
   - **Linux:** open your **Terminal** app.
2. **Install Node.js** (the "LTS" version) from [nodejs.org](https://nodejs.org). This gives you `npm`, used to install most of the AI tools.
3. **Install your AI tool** — paste the line for the one you use:

   | Tool | Paste this |
   | --- | --- |
   | [Claude](https://www.npmjs.com/package/@anthropic-ai/claude-code) | `npm install -g @anthropic-ai/claude-code` |
   | [Codex](https://www.npmjs.com/package/@openai/codex) | `npm install -g @openai/codex` |
   | [Gemini](https://www.npmjs.com/package/@google/gemini-cli) | `npm install -g @google/gemini-cli` |
   | [Copilot](https://github.com/features/copilot#cli) | [Install GitHub Copilot CLI](https://github.com/github/gh-copilot) and run `copilot login` |

   **[Antigravity (`agy`)](https://antigravity.google)** — Google's replacement for Gemini CLI on personal Google AI Pro/Ultra accounts (Gemini CLI stays for enterprise) — installs **without Node**: on **Windows** run `irm https://antigravity.google/cli/install.ps1 | iex`, on **Mac/Linux** run `curl -fsSL https://antigravity.google/cli/install.sh | bash`.
4. **Get LimitShift's files without Git** using the free [GitHub Desktop](https://desktop.github.com) app: **File → Clone repository → URL**, paste `https://github.com/j-ts/limitshift`, and clone it somewhere you'll remember. (Or click the green **Code → Download ZIP** on the project page and unzip it.)
5. **Open that folder in a terminal:** in File Explorer (Windows), right-click inside the folder → **"Open in Terminal"**. On Mac, type `cd ` in Terminal then drag the folder onto the window.
6. **Unblock the script (one time):**
   - **Windows:** `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (type `Y` if asked), then `Unblock-File .\limitshift.ps1`
   - **Mac / Linux:** `chmod +x limitshift.sh` — and if `jq --version` is missing, install it (`brew install jq` / `sudo apt install jq`).
7. **Open each project once, normally, in your AI tool** so it remembers you trust the folder. LimitShift runs the tool in the background, where it can't answer first-time "do you trust this folder?" prompts.

Now skip to [Write your to-do list](#write-your-to-do-list).

### ⚡ At home in a terminal

```bash
gh repo clone j-ts/limitshift
cd limitshift

# install whichever CLIs you use:
npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli
# GitHub Copilot CLI (requires GitHub CLI 'gh' to be installed first):
gh extension install github/gh-copilot && copilot login

# Antigravity (agy) — Google's Gemini CLI successor — installs separately (no npm):
#   Windows:   irm https://antigravity.google/cli/install.ps1 | iex
#   Mac/Linux: curl -fsSL https://antigravity.google/cli/install.sh | bash
```

Then make the script runnable:

- **Windows:** `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned; Unblock-File .\limitshift.ps1`
- **Mac / Linux:** `chmod +x limitshift.sh` and `brew install jq` (or `sudo apt install jq`)

Sign in to each CLI once inside a real project folder — headless runs can't answer "trust this folder?" prompts.

---

## Write your to-do list

Your list is a file named **`limitshift-queue.json`**, saved in the LimitShift folder. Each entry is one **task**. You can let an AI agent write it for you, or write it by hand.

### Option 1: Let your AI agent help you

You don't have to write any JSON yourself — but the agent does its best work when it actually understands your code. So **open your own project in your agent app** (Codex, Claude, Gemini, or your editor's agent), then point it at the LimitShift folder and your rough draft:

> *"Read the files in `C:\path\to\limitshift` (where you unzipped LimitShift) and create a `limitshift-queue.json` there, with prompts for **this** project based on my draft below. Use codex and suggest good models.*
> *Draft: review the code and list the bugs in `bugs.md`, fix them one by one, then double-check the fixes."*

Because the agent already understands your project, it can turn a vague draft into concrete, well-scoped prompts. The LimitShift folder ships an [`AGENTS.md`](AGENTS.md) that teaches it the exact fields, sensible model choices, and the permission flag each task needs — and it validates the result for you. Then just [run it](#run-it).

### Option 2: Write it yourself

Edit it in a plain-text editor (Notepad, or TextEdit in *plain text* mode) — **not Microsoft Word**, which adds hidden formatting that breaks the file.

```json
{
  "tasks": [
    {
      "name": "Document install steps",
      "cli": "claude",
      "projectPath": "C:\\Users\\you\\Documents\\my-project",
      "prompt": "Add an 'Installation' section to README.md.",
      "extraArgs": ["--permission-mode", "acceptEdits"]
    }
  ]
}
```

Four fields are required:

- **`name`** — a short label, for you.
- **`cli`** — `claude`, `codex`, `gemini`, `agy`, or `copilot`.
- **`projectPath`** — the folder to work in. On Windows, **double every backslash** (`C:\\Users\\you\\my-project`) or use forward slashes (`C:/Users/you/my-project`).
- **`prompt`** — what you're asking for, in plain words. The clearer and more specific, the closer the result lands.

**Give it permission to edit files.** Because LimitShift runs in the background, the AI can't stop to ask *"may I edit this?"* — without a permission flag it runs read-only and changes nothing, even though it reports success. Add the matching `extraArgs`:

- Claude → `["--permission-mode", "acceptEdits"]`
- Codex → `["--sandbox", "workspace-write"]`
- Gemini → `["--approval-mode", "auto_edit"]`
- Antigravity (`agy`) → `["--dangerously-skip-permissions"]`
- Copilot → `["--allow-tool=read,write,shell(npm:*),shell(npx:*),shell(git:*)", "--deny-tool=shell(git push)", "--no-ask-user"]`

For Copilot, `["--allow-all", "--no-ask-user"]` is full automation mode. It is broader than the recommended edit flags and should be used only when you fully trust the task.

> **Notepad trap:** when saving, set **Save as type → All Files**, or Notepad adds `.txt` and you get `limitshift-queue.json.txt`, which LimitShift won't find.

Ready-made examples to copy: [`example-simple.json`](limitshift-queue.example-simple.json) (one task), [`example-workflow.json`](limitshift-queue.example-workflow.json) (review → fix → verify), [`example-advanced.json`](limitshift-queue.example-advanced.json) (models, effort, rotation, completion checks).

---

## Run it

From the LimitShift folder:

**Check for typos first** (changes nothing):

```powershell
.\limitshift.ps1 -ValidateOnly      # Windows
```
```bash
./limitshift.sh --validate-only     # Mac / Linux
```

`Config OK` means you're ready.

**Run the queue:**

```powershell
.\limitshift.ps1                    # Windows
```
```bash
./limitshift.sh                     # Mac / Linux
```

LimitShift prints each reply under a `--- agent response ---` header. It may sit quietly for a minute while the AI works — that's normal, not frozen. Press **Ctrl+C** to stop at any time; your progress is saved, so you can resume later and it picks up where it left off. You'll see `Task 1 completed` when a task finishes.

**Didn't go how you wanted?** Edit the task's `prompt` and run again — LimitShift notices the change and re-does just that task. Add a new task to refine further; finished tasks are skipped.

---

## When you hit your usage limit

This is the whole point. AI tools cap how much you can use per session or week. Normally, hitting that cap mid-task means you stop and lose your place.

LimitShift instead **notices the limit, works out when it resets, waits, and resumes the same conversation** — so the AI still remembers what it was doing.

Give a task a **list** of models and it switches to the next one the instant one is capped — no waiting at all (see [Model rotation](#model-rotation)).

> **Long overnight runs:** stop your computer from sleeping. Windows: Settings → System → Power → "put my device to sleep" → **Never**. Mac: `caffeinate -i ./limitshift.sh`. Linux: `systemd-inhibit ./limitshift.sh`.

---

## Features

Handy capabilities you can reach for when you need them. None are required for a basic run.

### Completion checking

With `completionCheck: true` (the default), LimitShift appends `[[TASK_COMPLETE]]` instructions to every prompt and keeps resuming the task until the **last non-empty line** of a reply contains that marker (or `[[TASK_BLOCKED]] <reason>` if the AI gets stuck). Write prompts with a concrete end state, e.g. *"write `docs/audit.md` and summarize the changes."* This is what lets a single task run for several rounds until it's genuinely finished.

With `completionCheck: false` ("simple mode"), the prompt runs once and the task is marked done after the first OK run — only a usage limit triggers a resume.

### Run with local models through Ollama

***Supported by `claude` and `codex` only*** (Gemini and Antigravity have no local-model path).

Run a task on a local [Ollama](https://ollama.com) model — handy when you've hit a usage limit, want to work offline, or want to keep a task on your own machine. Set `model` to the Ollama model name and add `["--oss", "--local-provider", "ollama"]` to `extraArgs`. Install Ollama and pull a model first (e.g. `ollama pull qwen3.5:9b`).

```json
{
  "tasks": [
    {
      "name": "Local Codex",
      "cli": "codex",
      "model": "nemotron-3-nano:4b",
      "projectPath": "C:/Users/you/my-project",
      "prompt": "Respond OK",
      "extraArgs": ["--oss", "--local-provider", "ollama"]
    }
  ]
}
```

Codex talks to Ollama natively; Claude has no Ollama flag, so LimitShift runs it via `ollama launch claude --model <model> --yes -- <claude args>` — so `model` is **required** for a local claude task and `ollama` must be on PATH. Local runs skip the cloud usage check. To edit files, still add a permission flag, e.g. `["--oss", "--local-provider", "ollama", "--permission-mode", "acceptEdits"]`.

### Model rotation

Set `model` to an **array** of names in preference order (most useful for Gemini, e.g. `["gemini-3-flash-preview", "gemini-2.5-flash", "gemini-2.5-pro"]`). On a usage limit, LimitShift switches to the next model and retries immediately in the same conversation — no waiting. Only once every listed model is capped does it fall back to waiting for a reset, then restarts from the first model. The current position is remembered per task.

### Turn off your PC when it finishes

Because LimitShift is just a terminal command, you can chain it with anything your operating system can do — for example, shut down one minute after the queue finishes:

```powershell
.\limitshift.ps1; shutdown /s /t 60             # Windows
```
```bash
./limitshift.sh; sudo shutdown -h +1            # macOS
./limitshift.sh; sleep 60; systemctl poweroff   # Linux
```

### Run multiple queues in parallel

Each queue file gets its own isolated state folder. The recommended workflow for multiple projects is **one queue JSON per project, one terminal per queue**:

```powershell
# terminal 1
.\limitshift.ps1 -QueuePath surgemesh-queue.json

# terminal 2
.\limitshift.ps1 -QueuePath papertrade-queue.json
```
```bash
# terminal 1
./limitshift.sh --queue-path surgemesh-queue.json

# terminal 2
./limitshift.sh --queue-path papertrade-queue.json
```

**Name resolution:** a bare filename (no path separators) is looked up next to the script, so `-QueuePath surgemesh-queue.json` and `-QueuePath C:\path\to\surgemesh-queue.json` are both valid.

**State isolation:** each queue's sessions, outputs, status markers, and log live in `.limitshift-<queue-name>/` next to its JSON file. Two queues never share state, even when run side by side.

**Concurrency lock:** if you accidentally start the same queue twice, the second run detects the lock file left by the first and exits immediately with an error naming the queue and the running PID. Once the first run finishes (or is killed), the lock is released and you can start again. To force-unlock a stale lock after an unexpected crash, delete `.limitshift-<queue-name>/limitshift.lock`.

**Mixed-project queues:** you can still put tasks for multiple projects inside one queue using per-task `projectPath` values — this remains fully supported. Separate queue files are recommended when you want parallel execution or clearer state separation.

---

## About the name

The name *is* the idea. Your usage limit normally stops being a speed bump and becomes a wall — you hit it mid-task and start over later. LimitShift **shifts** the work across that wall instead: it parks the queue the moment you run out of quota and slides it forward the instant the limit resets. You set the tasks once; the limit turns into a pause, not a full stop. ⏳

---

# Reference

Detail to come back to when you need a specific option. Everything above is enough to get real work done.

## Configuration

The queue file is `limitshift-queue.json` (copy an example and edit). `settings` apply to the whole list; `tasks[]` fields apply to one task.

| Field | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| `settings.stopOnError` | boolean | no | `true` | Stop the queue after an unrecoverable failure |
| `settings.maxRunsPerTask` | integer | no | `20` | Cap on new + resumed runs per task |
| `settings.maxRetriesOnError` | integer | no | `2` | Retries for non-limit failures |
| `settings.limitWaitMinutes` | integer | no | `30` | Fallback wait when the reset time can't be parsed |
| `settings.resetBufferMinutes` | integer | no | `2` | Extra buffer added after a parsed reset time |
| `settings.completionCheck` | boolean | no | `true` | See [Completion checking](#completion-checking) |
| `settings.maxStalls` | integer | no | `2` | Fail a task after this many identical no-marker replies in a row |
| `tasks[].name` | string | **yes** | — | Human-readable task name |
| `tasks[].cli` | string | **yes** | — | `claude`, `codex`, `gemini`, `agy`, or `copilot` |
| `tasks[].projectPath` | string | **yes** | — | Folder the CLI runs in (must exist) |
| `tasks[].prompt` | string | **yes** | — | The task prompt |
| `tasks[].model` | string or array | no | — | See [Models](#models) and [Model rotation](#model-rotation) |
| `tasks[].effort` | string or null | no | — | Reasoning effort (see [Models](#models)) |
| `tasks[].completionCheck` | boolean | no | inherits settings | Per-task override |
| `tasks[].extraArgs` | string or array | no | — | Extra CLI flags — where [permission](#permissions) and [Ollama](#run-with-local-models-through-ollama) flags go |

Windows paths in JSON need **doubled backslashes** (`"C:\\Users\\me\\repo"`) or forward slashes (`"C:/Users/me/repo"`). Keep the `$schema` line from an example file to get inline validation in editors that support it.

## Models

> **Tested with:** Claude Code **2.1.170** · Codex CLI **0.136.0** · Gemini CLI **0.46.0** · Antigravity `agy` **1.0.8**. These are the builds LimitShift has been verified against; other recent versions should work too.

Model aliases passed through to each CLI:

- **claude:** `opus`, `sonnet`, `haiku` (or full ids like `claude-opus-4-8`).
- **codex:** `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`.
- **gemini:** `gemini-3.*` (e.g. `gemini-3.1-pro-preview`, `gemini-3-flash-preview`), `gemini-2.5-*`.
- **agy:** run `agy models` to see what your account can use (e.g. `gemini-3.1-pro`, `gemini-3.5-flash`, `claude-sonnet`, `gpt-oss-120b`). agy has no headless output mode (it draws its reply on screen), so LimitShift reads agy's answer back from its own local conversation history; and it resumes only its most recent conversation, so keep agy work to one linear chain of tasks — LimitShift handles the rest. Just have agy installed and signed in.
- **copilot:** install the GitHub CLI extension (`gh extension install github/gh-copilot`), run `copilot login`, then `copilot models` to list what your account can use. LimitShift passes `model` through as `--model`, `effort` through as `--effort`, uses `--name` on the first run and `--resume` on resumed runs, sends the prompt via `-p`, forces `--output-format=json --stream=off --no-ask-user`, and parses the returned JSONL stream for assistant text, session ids, and usage-limit signals.

**Effort** (`tasks[].effort`): claude `low`/`medium`/`high`/`xhigh`/`max`; codex `minimal`/`low`/`medium`/`high`/`xhigh`; copilot `low`/`medium`/`high`/`xhigh`/`max`. Gemini, Antigravity (`agy`), and Claude Haiku have no effort flag — leave it `null`.

### Model validation

LimitShift validates model names at runtime against each CLI's own model list during `--validate-only` / `-ValidateOnly` — no new release is needed when a provider adds or renames a model.

**What gets checked:**

| Output prefix | Meaning |
|---|---|
| `ERROR:` | model not found in the CLI's discovered list — exits 2 (strict mode) |
| `WARNING:` | model not found but queue will still run (warn mode) |
| `INFO:` | model name could not be verified (CLI has no model-list command) |

**Discovery support:**
- `agy` and `copilot`: parse `agy models` / `copilot models`
- `claude`, `codex`, `gemini`: no scriptable model list — prints INFO, never fails

**Settings** (inside `"settings": {}`):

```json
"modelValidation": "strictWhenDiscoverable",
"capabilityCacheHours": 24,
"probeModels": false
```

- `modelValidation`: `"strictWhenDiscoverable"` (default) · `"warn"` · `"off"`
- `capabilityCacheHours`: how long to cache the discovered list; `0` = always refresh
- `probeModels`: run a cheap connectivity prompt per CLI when using `--validate-only`

**Flags:**
- `--refresh-capabilities` / `-RefreshCapabilities`: ignore cache and re-query
- `--probe-models` / `-ProbeModels`: opt-in connectivity probe (consumes a small amount of quota)

**Typo detection:** if a model is missing, LimitShift suggests the nearest known model names (edit distance ≤ 4).

**Cache location:** `.limitshift-<queue>/capabilities/<cli>.json` next to the queue file.

## Permissions

Headless runs can't answer permission prompts — set your choice in `extraArgs`, or **the AI runs read-only and changes nothing**:

- Claude: `--permission-mode acceptEdits` (or `--dangerously-skip-permissions`)
- Codex: `--sandbox workspace-write` (or `--dangerously-bypass-approvals-and-sandbox`)
- Gemini: `--approval-mode auto_edit` (or `--approval-mode yolo`)
- Antigravity (`agy`): `--dangerously-skip-permissions` (its only headless auto-approve)
- Copilot: recommended edit flags are `--allow-tool=read,write,shell(npm:*),shell(npx:*),shell(git:*) --deny-tool=shell(git push) --no-ask-user`; automation mode is `--allow-all --no-ask-user` and should be used only when you fully trust the task.

More autonomy means more risk — run only against Git-backed folders.

## Run options

| Flag (PowerShell / Bash) | Does |
| --- | --- |
| `-ValidateOnly` / `--validate-only` | Check the config; change nothing |
| `-DryRun` / `--dry-run` | Print the exact commands; don't run or mark tasks done |
| `-QueuePath <file>` / `--queue-path <file>` | Use a named or custom queue file (bare filename resolves from script folder) |
| `-ShowRawOutput` / `--show-raw` | Print the raw CLI output to the console |

## Where LimitShift saves state

Everything lives in `.limitshift-<queue-name>/` next to your queue (for the default file, `.limitshift-limitshift-queue/`): session ids (to resume the same conversation), `outputs/` (raw output per run), `status/` (`.done` / `.failed` markers), `runs.csv`, and a log.

Editing a task's `name`, `prompt`, `cli`, `projectPath`, `model`, `effort`, or `extraArgs` auto-invalidates its `.done` marker and re-runs it with a fresh session; untouched tasks stay skipped. Delete a single `status/task-NN.done` to re-run one task, or delete the whole folder to start over — it's rebuilt on the next run.

## Troubleshooting

| Message | Fix |
| --- | --- |
| `Config file is not valid JSON` | Check for trailing/missing commas or bad escaping (use forward slashes in paths) |
| `Task N is missing required JSON property` | Add the missing `name`, `cli`, `projectPath`, or `prompt` |
| `Allowed values: claude, codex, gemini, agy, copilot` | Fix the `cli` value |
| `Project path does not exist` | Fix the path or create the folder |
| `not found on PATH` | Install the named CLI and retry |
| `jq is required but not installed` | Install `jq` (`brew install jq` / `sudo apt install jq`) |
| `Task N exceeded maxRunsPerTask` | Inspect the prompt/output; raise the cap only if needed |
| `installed gemini rejects --resume` | Harmless — the runner retries with a continuation prompt |
| AI reported success but nothing changed | No permission flag — add the right `extraArgs` (see [Permissions](#permissions)) |

## Tests

```powershell
Invoke-Pester tests/limitshift.Tests.ps1
```
```bash
bash tests/test-limitshift.sh
```

## Glossary

- **Terminal** — the app where you type commands (PowerShell on Windows; Terminal on Mac/Linux).
- **CLI** — the command-line version of an AI tool (Claude Code, Codex, Gemini, Antigravity, Copilot).
- **Node.js / npm** — Node.js (from [nodejs.org](https://nodejs.org)) includes `npm`, used to install the claude/codex/gemini CLIs. LimitShift itself doesn't need Node, and Antigravity and Copilot install without it.
- **Headless / background** — running a tool with no one watching, so it can't ask questions — why you set permissions and trust folders ahead of time.
- **Queue / task** — your whole list (the `.json` file) / one item in it.
- **Session** — one ongoing conversation; resuming keeps the AI's memory.

## Documentation

| Doc | What's in it |
| --- | --- |
| [QUICKSTART.md](QUICKSTART.md) | The shortest path from zero to a first run |
| [AGENTS.md](AGENTS.md) | How to have an AI agent build your queue — fields, model choices, permissions |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |
| [`limitshift-queue.schema.json`](limitshift-queue.schema.json) | The full queue schema (gives inline validation in editors) |
| Examples | [simple](limitshift-queue.example-simple.json) · [workflow](limitshift-queue.example-workflow.json) · [advanced](limitshift-queue.example-advanced.json) |

## License

MIT — see [`LICENSE`](LICENSE).
