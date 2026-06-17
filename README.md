<h1 align="center">LimitShift</h1>

<p align="center">
  <strong>English</strong> · <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <strong>Give your agentic CLI a to-do list and walk away. Different CLIs, one queue, quota aware.</strong>
</p>

<p align="center">
  <a href="#what-is-limitshift">What is it</a> ·
  <a href="#supported-tools">Supported tools</a> ·
  <a href="#why-limitshift">Why</a> ·
  <a href="#who-is-limitshift-for">Who it's for</a> ·
  <a href="#key-features">Features</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="#write-your-to-do-list">Write your list</a> ·
  <a href="#run-it">Run it</a> ·
  <a href="#reference">Reference</a>
</p>

---

## What is LimitShift?

LimitShift is a tiny terminal app that runs [five agentic CLIs](#supported-tools) through a list of tasks, one at a time. It drives the *command-line* version of those tools. If you've only ever used the app, you install the matching CLI once and sign in with the same account.

You write your tasks in one list and start it. When a tool says *"you're out of quota,"* LimitShift doesn't quit. It **sleeps until your quota resets, then continues the same conversation.** Start a long list and let it work unattended. How far it gets depends on your quota, how many prompts, and how large the tasks are.

You don't need to be a programmer. You do need to open a terminal once or twice. Every step is spelled out.

> ⚠️ **Treat first runs as rough drafts.** The result depends on the model, your wording, and the project. Only point LimitShift at a folder backed up with **Git**, so you can review and undo anything you don't like.

---

## Supported tools

| CLI | Install | Tested with |
| --- | --- | --- |
| [Claude Code](https://www.npmjs.com/package/@anthropic-ai/claude-code) (`claude`) | `npm install -g @anthropic-ai/claude-code` | 2.1.170 |
| [Codex CLI](https://www.npmjs.com/package/@openai/codex) (`codex`) | `npm install -g @openai/codex` | 0.136.0 |
| [Gemini CLI](https://www.npmjs.com/package/@google/gemini-cli) (`gemini`) | `npm install -g @google/gemini-cli` | 0.46.0 |
| [Antigravity](https://antigravity.google) (`agy`) | **Win** `irm https://antigravity.google/cli/install.ps1 \| iex`<br>**Mac/Linux** `curl -fsSL https://antigravity.google/cli/install.sh \| bash` | 1.0.8 |
| [GitHub Copilot CLI](https://github.com/github/copilot-cli) (`copilot`) | `npm install -g @github/copilot` | 1.0.62 |

These are the builds LimitShift has been verified against; other recent versions should work too. Antigravity is Google's replacement for Gemini CLI on personal Google AI Pro/Ultra accounts (Gemini CLI stays for enterprise).

---

## Why LimitShift?

Each of these is a spot where the normal workflow breaks down, and what LimitShift does instead.

- **You hit a usage limit mid-task.** Normally you stop and lose your pace. LimitShift waits for the reset and resumes the *same* conversation, so the AI keeps its memory of what it was doing.
- **You have a long list of changes.** Your options are to babysit each one by hand, or queue them, but a plain queue stops the moment you hit the limit. LimitShift queues them *and* keeps going across the reset.
- **You use more than one AI tool.** Switching by hand means opening loads of windows at once and remembering which one is on which task. LimitShift runs `claude`, `codex`, `gemini`, `agy`, and `copilot` from one list, one task at a time.
- **You want overnight or unattended runs.** Queue the tasks and walk away. Just know they only run while you have quota. Once the limit is reached, the queue pauses until it resets, so how far it gets by morning depends on how many prompts and how large the tasks are.
- **Want to try a local model?** `claude` and `codex` can already talk to [Ollama](#run-with-local-models-through-ollama). LimitShift lets you queue those local tasks and run them unattended too.

---

## Who is LimitShift for?

Anyone who uses an AI coding app or agent CLI with a subscription or tier (Claude Code, Codex, Gemini, Antigravity, or GitHub Copilot) and hits usage limits. Instead of stopping and starting over, LimitShift waits for the reset and picks up where you left off.

- **Anyone who wants unattended runs**: queue your tasks and walk away, whether overnight or while you work on something else.
- **Users who orchestrate more than one tool** and want one queue instead of juggling windows.
- **Ollama users** who want to queue local-model tasks through `claude` or `codex` and let them run hands-free.

---

## Key Features

- **Extremely light, nothing to install** — LimitShift itself is a single script you run in place: no package to install, no dependencies of its own (just the AI CLIs you already use, plus `jq` on Mac/Linux).
- **Usage-limit aware** — detects the cap, works out when it resets, waits, and resumes the *same* session so the AI keeps its memory.
- **Mix and match CLIs** — `claude`, `codex`, `gemini`, Antigravity (`agy`), and `copilot` in one queue, mixable task by task.
- **Resumable & safe** — press Ctrl+C anytime; progress is saved, and it's built for Git-backed folders so nothing is lost.
- **Cross-platform, no build step** — one PowerShell script for Windows, one Bash script for Mac/Linux.
- **[Block recovery](#block-recovery)** — if the AI decides a task is impossible, LimitShift can resume with the failure reason and nudge it to try again.
- **[Model rotation](#model-rotation)** — give a task a list of models and it switches the instant one is capped, with no waiting.
- **[CLI rotation](#cli-rotation)** — list backup tools per task; if one hits its limit or fails persistently, LimitShift hands the same task to the next tool without waiting.
- **[Completion checking](#completion-checking)** — keeps nudging a task across several rounds until the AI signals it's genuinely done.
- **[Local models via Ollama](#run-with-local-models-through-ollama)** — run `claude` or `codex` against a model on your own machine.

---

## Get started

You need a **Windows, Mac, or Linux** computer, at least one [supported CLI](#supported-tools), and a project folder tracked by **Git**. Pick the path that sounds like you:

### 🐣 New to the terminal

No command-line experience needed. This uses buttons, links, and copy-paste.

1. **Open a terminal** (where you type commands instead of clicking):
   - **Windows:** Start button → type **PowerShell** → open **Windows PowerShell**.
   - **Mac:** `Cmd+Space` → type **Terminal** → Enter.
   - **Linux:** open your **Terminal** app.
2. **Install Node.js** (the "LTS" version) from [nodejs.org](https://nodejs.org). This gives you `npm`, used to install most of the AI tools.
3. **Install your AI tool.** Pick one from the [supported tools](#supported-tools) table and paste its install command.
4. **Get LimitShift's files without Git** using the free [GitHub Desktop](https://desktop.github.com) app: **File → Clone repository → URL**, paste `https://github.com/j-ts/limitshift`, and clone it somewhere you'll remember. (Or click the green **Code → Download ZIP** on the project page and unzip it.)
5. **Open that folder in a terminal:** in File Explorer (Windows), right-click inside the folder → **"Open in Terminal"**. On Mac, type `cd ` in Terminal then drag the folder onto the window.
6. **Unblock the script (one time):**
   - **Windows:** `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (type `Y` if asked), then `Unblock-File .\limitshift.ps1`
   - **Mac / Linux:** `chmod +x limitshift.sh`. If `jq --version` is missing, install it (`brew install jq` / `sudo apt install jq`).
7. **Open each project once, normally, in your AI tool** so it remembers you trust the folder. LimitShift runs the tool in the background, where it can't answer first-time "do you trust this folder?" prompts.

Now skip to [Write your to-do list](#write-your-to-do-list).

### ⚡ At home in a terminal

```bash
gh repo clone j-ts/limitshift
cd limitshift

# install whichever CLIs you use:
npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli
# GitHub Copilot CLI (https://github.com/github/copilot-cli):
npm install -g @github/copilot

# Antigravity (agy) — Google's Gemini CLI successor — installs separately (no npm):
#   Windows:   irm https://antigravity.google/cli/install.ps1 | iex
#   Mac/Linux: curl -fsSL https://antigravity.google/cli/install.sh | bash
```

Then make the script runnable:

- **Windows:** `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned; Unblock-File .\limitshift.ps1`
- **Mac / Linux:** `chmod +x limitshift.sh` and `brew install jq` (or `sudo apt install jq`)

Sign in to each CLI once inside a real project folder. Headless runs can't answer "trust this folder?" prompts.

---

## Write your to-do list

Your list is a file named **`limitshift-queue.json`**, saved in the LimitShift folder. Each entry is one **task**. You can let an AI agent write it for you, or write it by hand.

### Option 1: Let your AI agent help you

You don't have to write any JSON yourself, but the agent does its best work when it actually understands your code. So **open your own project in your agent app** (Codex, Claude, Gemini, or your editor's agent), then point it at the LimitShift folder and your rough draft:

> *"Read the files in `C:\path\to\limitshift` (where you unzipped LimitShift) and create a `limitshift-queue.json` there, with prompts for **this** project based on my draft below. Use codex and suggest good models.*
> *Draft: review the code and list the bugs in `bugs.md`, fix them one by one, then double-check the fixes."*

Because the agent already understands your project, it can turn a vague draft into concrete, well-scoped prompts. The LimitShift folder ships an [`AGENTS.md`](AGENTS.md) that teaches it the exact fields, sensible model choices, and the permission flag each task needs, and it validates the result for you. Then just [run it](#run-it).

### Option 2: Write it yourself

Edit it in a plain-text editor (Notepad, or TextEdit in *plain text* mode), **not Microsoft Word**, which adds hidden formatting that breaks the file.

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

**Give it permission to edit files.** Because LimitShift runs in the background, the AI can't stop to ask *"may I edit this?"*. Without a permission flag it runs read-only and changes nothing, even though it reports success. Add the matching `extraArgs`:

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

LimitShift prints each reply under a `✦ response` header. It may sit quietly for a minute while the AI works; that's normal, not frozen.

**To stop:**
- **Ctrl+C** stops immediately, even in the middle of a task.
- **Press `s` (or `S`)** to stop cleanly after the current step finishes. This ensures you don't lose in-flight work. A reminder line shows your stop request at the bottom while it finishes.

Your progress is saved, so you can resume later and it picks up where it left off. You'll see `Task N done` when a task finishes.

**Didn't go how you wanted?** Edit the task's `prompt` and run again. LimitShift notices the change and re-does just that task. Add a new task to refine further; finished tasks are skipped.

---

## When you hit your usage limit

This is the whole point. AI tools cap how much you can use per session or week. Normally, hitting that cap mid-task means you stop and lose your place.

LimitShift instead **notices the limit, works out when it resets, waits, and resumes the same conversation**, so the AI still remembers what it was doing.

Give a task a **list** of models and it switches to the next one the instant one is capped, no waiting at all (see [Model rotation](#model-rotation)).

> **Long overnight runs:** stop your computer from sleeping. Windows: Settings → System → Power → "put my device to sleep" → **Never**. Mac: `caffeinate -i ./limitshift.sh`. Linux: `systemd-inhibit ./limitshift.sh`.

---

## Features

Handy capabilities you can reach for when you need them. None are required for a basic run.

### Completion checking

With `completionCheck: true` (the default), LimitShift appends `[[TASK_COMPLETE]]` instructions to every prompt and keeps resuming the task until the **last non-empty line** of a reply contains that marker (or `[[TASK_BLOCKED]] <reason>` if the AI gets stuck). Write prompts with a concrete end state, e.g. *"write `docs/audit.md` and summarize the changes."* This is what lets a single task run for several rounds until it's genuinely finished.

With `completionCheck: false` ("simple mode"), the prompt runs once and the task is marked done after the first OK run; only a usage limit triggers a resume.

### Block recovery

When an AI tool decides a task is impossible and ends with `[[TASK_BLOCKED]] <reason>`, LimitShift can automatically nudge it to reconsider. Set `recoveryAttempts` to a number greater than 0 in either `settings` or on individual tasks, but not both:

```json
{
  "settings": { "recoveryAttempts": 2 },
  "tasks": [
    {
      "name": "Hard refactor",
      "cli": "claude",
      "completionCheck": true,
      "prompt": "Refactor the entire auth system safely."
    }
  ]
}
```

If a task is blocked, LimitShift:
1. Resumes the same session with the newest block reason.
2. Nudges the AI to find another way to finish the task.
3. If exhausted, flags the task for human review with `status/task-NN.needs-human` and stops.

A block reason starting with `HUMAN:` (e.g. `[[TASK_BLOCKED]] HUMAN: I need the production API key`) always stops immediately without recovery. Recovery requires `completionCheck: true`.

### Run with local models through Ollama

***Supported by `claude` and `codex` only.*** Gemini and Antigravity have no local-model path.

Handy when you've hit a usage limit, want to work offline, or want to keep a task on your own machine. Install [Ollama](https://docs.ollama.com/quickstart) and pull a model first (e.g. `ollama pull qwen3.5:9b`), set `model` to that model's name, and add `["--oss", "--local-provider", "ollama"]` to `extraArgs`. The same config works for both CLIs:

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

`model` is **required** and `ollama` must be on your PATH. Codex talks to Ollama natively; for Claude, LimitShift routes through `ollama launch claude` automatically.

To edit files, add a [permission flag](REFERENCE.md#permissions) alongside the Ollama flags, e.g. `["--oss", "--local-provider", "ollama", "--permission-mode", "acceptEdits"]` for Claude.

### Model rotation

Set `model` to an **array** of names in preference order (e.g. `["gemini-3-flash-preview", "gemini-2.5-flash", "gemini-2.5-pro"]`). On a usage limit, LimitShift switches to the next model and retries immediately in the same conversation, no waiting. Only once every listed model is capped does it fall back to waiting for a reset, then restarts from the first model. The current position is remembered per task.

Model rotation is not limited by CLI tool, but in practice it is most useful on Gemini and Antigravity because they have separate usage limits for different model tiers.

### CLI rotation

When the tool running a task hits a usage limit or fails persistently, LimitShift can automatically hand the **same task** to a backup tool instead of waiting. Add a `fallbacks` list to any task:

```json
{
  "name": "Fix the failing tests",
  "cli": "claude",
  "model": ["opus", "sonnet"],
  "projectPath": "C:/Users/you/my-project",
  "completionCheck": true,
  "extraArgs": ["--permission-mode", "acceptEdits"],
  "prompt": "Fix all failing tests until they pass.",
  "fallbacks": [
    { "cli": "codex", "model": "gpt-5.5", "extraArgs": ["--sandbox", "workspace-write"] },
    { "cli": "gemini", "model": ["gemini-3-flash-preview", "gemini-2.5-pro"], "extraArgs": ["--approval-mode", "auto_edit"] }
  ]
}
```

Each fallback carries its **own** permission flag, because the flag differs per tool. The task's `name`, `projectPath`, `prompt`, and `completionCheck` are shared across all runners.

When LimitShift switches tools:

- **Usage limit** (all models on the current tool are capped) → switch to the next tool, fresh session.
- **Persistent failure** (failed past `maxRetriesOnError`) → set the tool aside and switch.
- **`[[TASK_BLOCKED]]`** → the agent decided the task is impossible; **no switch happens**.

If every listed tool is temporarily capped, LimitShift waits for the **soonest reset** (within 24 hours) and resumes that tool. The incoming tool starts a fresh session and receives a **handoff note** telling it to inspect `git status` and `git diff` before starting.

**Git is required.** A fallbacks task's `projectPath` must be a git working tree — LimitShift checks this at validation time. The handoff note tells the incoming tool to inspect both `git status` (for new/untracked files) and `git diff` (for changes to tracked files). For the cleanest handoff, **commit a baseline before running a rotation task** so the diff clearly shows the partial progress.

See [STRATEGIES.md](STRATEGIES.md) for prompt-writing tips, model and tool choice guidance, and example workflows using CLI rotation.

### Turn off your PC when it finishes

Because LimitShift is just a terminal command, you can chain it with anything your operating system can do. For example, shut down one minute after the queue finishes:

```powershell
.\limitshift.ps1; shutdown /s /t 60             # Windows
```
```bash
./limitshift.sh; sudo shutdown -h +1            # macOS
./limitshift.sh; sleep 60; systemctl poweroff   # Linux
```

### Run multiple queues in parallel

> ⚠️ Each queue runs its own CLI process. Even API-backed agents need RAM, and local Ollama models need significantly more. Only run as many parallel queues as your machine can handle.

Each queue file gets its own isolated state folder. The recommended workflow for multiple projects is **one queue JSON per project, one terminal per queue**:

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

**Name resolution:** a bare filename (no path separators) is looked up next to the script, so `-QueuePath project-a-queue.json` and `-QueuePath C:\path\to\project-a-queue.json` are both valid.

**State isolation:** each queue's sessions, outputs, status markers, and log live in `limitshift-<queue-name>/` next to its JSON file. Two queues never share state, even when run side by side.

**Concurrency lock:** if you accidentally start the same queue twice, the second run detects the lock file left by the first and exits immediately with an error naming the queue and the running PID. Once the first run finishes (or is killed), the lock is released and you can start again. To force-unlock a stale lock after an unexpected crash, delete `limitshift-<queue-name>/limitshift.lock`.

**Mixed-project queues:** you can still put tasks for multiple projects inside one queue using per-task `projectPath` values; this remains fully supported. Separate queue files are recommended when you want parallel execution or clearer state separation.

---

# Reference

Configuration, models, permissions, run options, state, and troubleshooting → **[REFERENCE.md](REFERENCE.md)**.

## Roadmap

- [x] **CLI rotation on usage limits.** When you hit a limit on one CLI (e.g. `claude`), automatically switch to another (e.g. `codex`) for the same task. Like [model rotation](#model-rotation), but across different tools.

## Glossary

- **Terminal** — the app where you type commands (PowerShell on Windows; Terminal on Mac/Linux).
- **CLI** — the command-line version of an AI tool (Claude Code, Codex, Gemini, Antigravity, Copilot).
- **Node.js / npm** — Node.js (from [nodejs.org](https://nodejs.org)) includes `npm`, used to install the claude/codex/gemini CLIs. LimitShift itself doesn't need Node, and Antigravity and Copilot install without it.
- **Headless / background** — running a tool with no one watching, so it can't ask questions, which is why you set permissions and trust folders ahead of time.
- **Queue / task** — your whole list (the `.json` file) / one item in it.
- **Session** — one ongoing conversation; resuming keeps the AI's memory.

## Documentation

| Doc | What's in it |
| --- | --- |
| [REFERENCE.md](REFERENCE.md) | Configuration, models, permissions, run options, state, troubleshooting |
| [QUICKSTART.md](QUICKSTART.md) | The shortest path from zero to a first run |
| [AGENTS.md](AGENTS.md) | How to have an AI agent build your queue: fields, model choices, permissions |
| [STRATEGIES.md](STRATEGIES.md) | Prompt quality, commit-before-rotation, model/tool choice, completion-check vs simple mode, `maxRunsPerTask` budget, example workflows |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |
| [`limitshift-queue.schema.json`](limitshift-queue.schema.json) | The full queue schema (gives inline validation in editors) |
| Examples | [simple](limitshift-queue.example-simple.json) · [workflow](limitshift-queue.example-workflow.json) · [advanced](limitshift-queue.example-advanced.json) |

## License

MIT — see [`LICENSE`](LICENSE).
