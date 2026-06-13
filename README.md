# LimitShift

**Give your AI coding assistant a to-do list and walk away. LimitShift works through it one task at a time — and when you hit your usage limit, it waits for the limit to reset and picks up right where it left off.**

Maybe you use **Codex, Claude, or Gemini** as an app — or in your code editor, like Antigravity — and you've never opened a terminal in your life. You line up a few tasks, then you hit your usage limit and **everything just stops.** The queues built into those apps don't wait for your limit to reset; they stall, and you lose your place.

LimitShift is a tiny **terminal app** that fixes exactly that. You write your tasks down in one list, start it, and walk away. It runs each one for you. When the AI says "you've used up your quota for now," LimitShift doesn't give up — it **sleeps until your quota comes back and then continues the same conversation.** You wake up to the work done (or as far as it could get).

Think of it like a queue at a coffee shop: you hand over a list of orders, and they get made one by one. If the machine needs to cool down, the barista waits and then keeps going — they don't throw out your list.

> 🔰 **New to words like *terminal*, *npm*, or *Git*?** Don't worry — there's a plain-language [glossary at the bottom](#a-few-words-explained), and the steps below explain each thing as you reach it.

> **⚠️ Read this before you start — set your expectations.**
> There is **no guarantee** a task comes out exactly how you pictured it. The result depends on the AI model, how clearly you wrote the request, and the project itself. Treat the first run as a **rough draft**. You steer it by adding more tasks afterward or by editing a request and running again. **Only point LimitShift at a folder that's backed up with Git** (version control) so you can look at what changed and undo anything you don't like.

---

## Is this for me?

You'll get value from LimitShift if:

- You use **Codex, Claude, or Gemini** and sometimes hand it a series of related jobs.
- You wish you didn't have to babysit each one and re-start after every usage limit.
- You keep hitting usage limits mid-session and lose your place, because the app's queue can't pause and wait.

You do **not** need to be a programmer. You **do** need to be willing to open a terminal (I show you how just below) and edit a small text file. Every step is spelled out.

> **One heads-up if you've only used the app.** LimitShift drives the *command-line* version of these tools — the `claude` / `codex` / `gemini` program you run in a terminal. If you've only ever used the desktop app or editor, you'll install the matching CLI once (a single command, shown below). It signs in with the same account.

---

## The one skill you need: opening a terminal

A **terminal** is an app already on your computer where you type commands instead of clicking buttons. Everything below happens in one.

- **Windows:** press the Start button, type **PowerShell**, and open **Windows PowerShell**.
- **Mac:** press `Cmd+Space`, type **Terminal**, and press Enter.
- **Linux:** open your **Terminal** app.

Most commands also need your terminal to be "pointed at" a specific folder. The easiest way:

- **Windows:** in File Explorer, open the folder, then right-click an empty area inside it and choose **"Open in Terminal"** (or hold Shift while right-clicking → "Open PowerShell window here").
- **Mac:** open the **Terminal**, type `cd ` (with a space), then drag the folder from Finder onto the Terminal window and press Enter.

If a command ever fails with "cannot find path" or "file not found," it almost always means your terminal isn't pointed at the right folder yet — redo the step above.

---

## What you need before you start

| You need... | Why | How to check |
| --- | --- | --- |
| A **Windows, Mac, or Linux** computer | LimitShift is a small script that runs on all three | — |
| At least one **AI coding terminal tool (CLI)**: `claude`, `codex`, or `gemini` | LimitShift drives one of these CLIs to do the actual work — it doesn't talk to the AI itself | Type the tool's name (e.g. `codex`). If it starts up, you have it (press `Ctrl+C` to leave). If you see "not recognized" or "command not found," install it below |
| Each tool **signed in and trusted** in your project folder, once | LimitShift runs the tools silently in the background, where they can't stop to ask "do you trust this folder?" — so you answer that ahead of time | Open your project once, normally, in the tool (e.g. run `claude` inside the folder and let it start) |
| (Mac/Linux only) a small helper called **`jq`** | The Mac/Linux version uses it to read the tool's output | Type `jq --version`. If it's missing: Mac `brew install jq`, Linux `sudo apt install jq` |
| A project folder that's **tracked by Git** | So you can review and undo anything the AI changes | Type `git status` inside the folder. If it says "not a git repository," the folder isn't backed up yet — the simplest fix is the free [GitHub Desktop](https://desktop.github.com) app (buttons, no typing): use it to "create a repository" from your folder |

Don't have the command-line version of your tool yet? Type the matching line into your terminal:

```text
claude  →  npm install -g @anthropic-ai/claude-code
codex   →  npm install -g @openai/codex
gemini  →  npm install -g @google/gemini-cli
```

(These use `npm`, which comes with [Node.js](https://nodejs.org) — **LimitShift itself doesn't need Node**, it's only how you install the AI CLIs. If `npm` isn't found, install Node.js, version "LTS", first. Some tools also offer a standalone installer; either way is fine.)

> **Important, one-time step:** because LimitShift runs the tools in the background, they can't answer first-time "do you trust this folder?" prompts. **Open each project once, normally, in the tool before automating it.**

---

## Install LimitShift

There's nothing to build.

1. **Download the files.** On this project's web page, click the green **Code** button → **Download ZIP**. Unzip it somewhere you'll remember, like your **Documents** folder. (You'll now have a folder containing `limitshift.ps1`, `limitshift.sh`, and the examples.)
2. **Open a terminal in that folder** using the trick from ["The one skill you need"](#the-one-skill-you-need-opening-a-terminal) above.
3. **Run the one setup command for your system:**

**Windows:**

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Unblock-File .\limitshift.ps1
```

The first line lets your computer run scripts you've explicitly allowed — it's a standard, safe setting that doesn't lower your overall security, and you can undo it later. **If it asks you to confirm, type `Y` and press Enter.** The second line clears the "downloaded from the internet" block on the script.

**Mac / Linux:**

```bash
chmod +x limitshift.sh
```

(This marks the script as runnable.)

---

## Your first run, step by step

### Step 1 — Write your to-do list

Your to-do list is a small text file in **JSON** format (a structured way of writing a list that the computer can read). Each item is one **task**.

> **Edit it in a plain-text editor** — Notepad on Windows, or TextEdit in *plain text* mode on Mac — **not Microsoft Word**, which adds hidden formatting that breaks the file. Keep every quote, comma, and brace exactly as shown; they all matter.

Here is the simplest useful list — one task:

```json
{
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

What each line means:

- **`name`** — any short label so you can recognize the task. It's for you.
- **`cli`** — which AI tool to use: `"claude"`, `"codex"`, or `"gemini"`.
- **`projectPath`** — the folder the AI should work in. **On Windows, write each backslash twice:** `"C:\\Users\\you\\my-project"`. In JSON a single `\` is a special character, so a real Windows path needs doubled `\\` or it won't load. (A forward-slash path like `"C:/Users/you/my-project"` also works if you find it easier.)
- **`prompt`** — what you're actually asking for, in plain words. This is the part that matters most.
- **`completionCheck: false`** — keeps things simple: run the prompt once and stop (it only waits if you hit a usage limit). Leave this in while you're learning; the other mode is explained [later](#doing-more-the-advanced-example).
- **`extraArgs`** — gives the AI permission to actually edit files. This matters: because LimitShift runs the tool in the background, the AI **can't stop to ask "may I edit this file?"** Without a permission line it runs read-only and changes nothing — even though it reports success. The `["--permission-mode", "acceptEdits"]` shown here lets Claude make edits. (Codex uses `["--sandbox", "workspace-write"]`; Gemini uses `["--approval-mode", "auto_edit"]`.)

The first four fields (`name`, `cli`, `projectPath`, `prompt`) are required. The rest are optional — but you'll almost always want the permission line if you expect the AI to change anything.

### Step 2 — Save it

Save your file as **`limitshift-queue.json`** — that's the name LimitShift looks for automatically. Save it in the **LimitShift folder** (the one with `limitshift.ps1` / `limitshift.sh` that you unzipped). Note this is usually **not** the same folder as your `projectPath`, which points at the project you want the AI to work on.

> **Notepad trap:** when saving, set **"Save as type"** to **"All Files"** — otherwise Notepad silently adds `.txt` and you get `limitshift-queue.json.txt`, which LimitShift won't find.

(A ready-made copy ships as [`limitshift-queue.example-simple.json`](limitshift-queue.example-simple.json) — you can copy that and edit it. Change `projectPath` to a real folder of yours and write your own `prompt`.)

> ### 🤖 Shortcut: let your agent write the queue for you
>
> Writing JSON by hand isn't your thing? You don't have to. This folder ships an [`AGENTS.md`](AGENTS.md) file, so your AI coding tool already knows how to fill in `limitshift-queue.json` for you.
>
> Open **this LimitShift folder** in Codex (or Claude, or your editor's agent) and just ask, in plain words — for example:
>
> > *"Read this folder and create prompts for my project at `C:\Users\me\my-project` based on the draft below. Change only `limitshift-queue.json`. Suggest appropriate models and use codex.*
> > *Draft: review the code and list the bugs, then fix them one by one, then double-check the fixes."*
>
> The agent reads `AGENTS.md`, writes a valid `limitshift-queue.json` with sensible models and the right permission flags, and validates it for you. Then you just run it (Steps 3–5 below). You never touch the JSON.

### Step 3 — Check it before running

This catches typos (a missing comma, a wrong tool name, a folder that doesn't exist) **before** anything runs. Nothing is changed; it just looks.

**Windows:**
```powershell
.\limitshift.ps1 -ValidateOnly
```
**Mac / Linux:**
```bash
./limitshift.sh --validate-only
```

(The `.\` at the front just means "the script here in this folder" — type it exactly.) If you see `Config OK`, you're ready. If you get an error you don't understand, the [Troubleshooting table](#troubleshooting) near the bottom lists the common ones and their fixes.

### Step 4 — Run it

**Windows:**
```powershell
.\limitshift.ps1
```
**Mac / Linux:**
```bash
./limitshift.sh
```

### Step 5 — Watch what happens

LimitShift prints the AI's reply in plain text under a clear header — not a wall of technical data:

```text
--- agent response ---
Added an "Installation" section to README.md with clone, dependency, and build steps.
```

It may sit quietly for a minute or more while the AI works — that's normal, not frozen. To stop it at any time, press **`Ctrl+C`**; your progress is saved, so you can start again later and it picks up where it left off. When a task finishes you'll see `Task 1 completed`. That's it — you ran your first queue.

(The full technical output is quietly saved to a file too — see [Where LimitShift keeps its notes](#where-limitshift-keeps-its-notes).)

---

## Steering the results

Remember the expectations note up top: the first run is a draft. You shape the outcome **with follow-up requests**, not by getting the one perfect prompt. A few easy ways:

- **Didn't go how you wanted?** Edit the task's `prompt` and run again. LimitShift notices the change and re-does that task automatically — you don't have to delete anything.
- **Want to refine it?** Add another task to the list ("Now also add a Troubleshooting section") and run again. Finished tasks are skipped; only the new one runs.
- **Want to be more specific?** The clearer and more concrete your `prompt` (name the file, describe what "done" looks like), the closer the result lands.

---

## A real workflow: review → fix → verify

Queues really shine when one task feeds the next. Here's a three-step pipeline — find problems, fix them, then check the fixes — that ships as [`limitshift-queue.example-workflow.json`](limitshift-queue.example-workflow.json):

```json
{
  "settings": { "stopOnError": true, "completionCheck": true },
  "tasks": [
    {
      "name": "Find bugs",
      "cli": "codex",
      "projectPath": "C:\\Users\\you\\Documents\\my-project",
      "model": "gpt-5.4",
      "effort": "high",
      "extraArgs": ["--sandbox", "workspace-write"],
      "prompt": "Review the code in src/ and write every bug or issue you find to bugs.md - one numbered item per bug, each with its file path and a short description. Do not fix anything yet."
    },
    {
      "name": "Fix bugs",
      "cli": "codex",
      "projectPath": "C:\\Users\\you\\Documents\\my-project",
      "model": "gpt-5.4",
      "effort": "high",
      "extraArgs": ["--sandbox", "workspace-write"],
      "prompt": "Read bugs.md and fix each listed issue one by one. After fixing an item, append ' - FIXED' to its line in bugs.md."
    },
    {
      "name": "Verify fixes",
      "cli": "codex",
      "projectPath": "C:\\Users\\you\\Documents\\my-project",
      "model": "gpt-5.4",
      "effort": "high",
      "extraArgs": ["--sandbox", "workspace-write"],
      "prompt": "Read bugs.md, review the current implementation against each item, and mark each line 'Verified fixed' or 'Still broken: <why>'."
    }
  ]
}
```

The three tasks run in order, each in its own conversation:

1. **Find** — review the code and write every bug to `bugs.md`.
2. **Fix** — read `bugs.md` and fix each item, marking it `FIXED`.
3. **Verify** — read `bugs.md`, check each fix really landed, and mark it `Verified fixed` or `Still broken`.

`completionCheck: true` keeps LimitShift nudging each step until the AI signals it's finished. The `extraArgs` line gives Codex permission to edit files. And if you hit a usage limit anywhere in the middle, LimitShift waits and picks the pipeline back up — you don't lose your place. (Don't want to write this by hand? [Ask your agent](#-shortcut-let-your-agent-write-the-queue-for-you) to build it from a one-line draft.)

---

## What happens when you hit your usage limit

This is the whole reason LimitShift exists. AI tools cap how much you can use in a session or a week. Normally, hitting that cap mid-task means you stop and lose your place.

LimitShift instead **notices the limit, figures out when it resets, waits that long, and then continues the same conversation** — so the AI still remembers what it was doing. You can start a big list before bed and find it further along (or finished) in the morning.

If you give a task a **list** of models instead of one, LimitShift can switch to the next model the moment one hits its limit, so it doesn't even have to wait. That's covered in [Model rotation](#model-rotation-on-usage-limits).

> **Tip for long overnight runs:** stop your computer from going to sleep. On Windows: Settings → System → Power → set "When plugged in, put my device to sleep" to **Never**. On Mac: run with `caffeinate -i ./limitshift.sh`. On Linux: `systemd-inhibit ./limitshift.sh`.

---

## Doing more: the advanced example

When you're comfortable, you can use the optional fields: pick a specific model, give a model a rotation list, set how hard the AI should think (`effort`), pass extra options to the tool, and turn on "completion checking" (where LimitShift keeps nudging the AI until it explicitly says the task is done).

A full 3-task example using every option ships as [`limitshift-queue.example-advanced.json`](limitshift-queue.example-advanced.json):

```json
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 20,
    "maxStalls": 2,
    "limitWaitMinutes": 30,
    "completionCheck": true
  },
  "tasks": [
    {
      "name": "Implement fixes with Codex",
      "cli": "codex",
      "projectPath": "C:\\Users\\you\\Documents\\my-project",
      "model": "gpt-5.4",
      "effort": "medium",
      "extraArgs": ["--sandbox", "workspace-write"],
      "prompt": "Implement the fixes listed in docs/audit.md, run the tests, and summarize what changed."
    },
    {
      "name": "Write release notes with Gemini",
      "cli": "gemini",
      "projectPath": "C:\\Users\\you\\Documents\\my-project",
      "model": ["gemini-3-flash-preview", "gemini-2.5-flash", "gemini-2.5-pro"],
      "effort": null,
      "extraArgs": ["--approval-mode", "auto_edit"],
      "prompt": "Read the git log since the last tag and write RELEASE_NOTES.md."
    },
    {
      "name": "Audit the project with Claude",
      "cli": "claude",
      "projectPath": "C:\\Users\\you\\Documents\\my-project",
      "model": "sonnet",
      "extraArgs": ["--permission-mode", "acceptEdits"],
      "completionCheck": true,
      "prompt": "Read the codebase and write a code-quality audit to docs/audit.md. List concrete issues with file paths. End with [[TASK_COMPLETE]] on its own line when done, or [[TASK_BLOCKED]] <reason> if you cannot finish."
    }
  ]
}
```

In plain terms:

- **`settings`** are options for the whole list. `stopOnError` halts everything if a task fails badly. `maxRunsPerTask` is a safety cap on how many tries one task gets. `maxStalls` gives up on a task that keeps repeating itself without finishing. `limitWaitMinutes` is a fallback wait time. `completionCheck` turns on the "keep going until the AI says it's done" behavior for the whole list (individual tasks can override it).
- **Task 1 (Codex)** picks the `gpt-5.4` model, tells it to think at `medium` effort, and uses `extraArgs` to let it edit files inside the workspace without asking each time.
- **Task 2 (Gemini)** gives a **list** of models (rotation — see below). Gemini has no "effort" setting, so `effort` must be `null`.
- **Task 3 (Claude)** turns on `completionCheck`, so LimitShift keeps resuming until the AI ends its reply with the special marker `[[TASK_COMPLETE]]` (or `[[TASK_BLOCKED]] <reason>` if it gets stuck).

Don't worry about memorizing these — the full list of options is in the [Reference](#reference) below, and you can ignore all of them until you need one.

---

## A few words explained

- **Terminal** — an app already on your computer where you type commands instead of clicking. On Windows it's **PowerShell**; on Mac and Linux it's **Terminal**.
- **CLI / AI tool** — the AI coding assistant you run in your terminal (Claude Code, Codex, or Gemini). "CLI" means "command-line interface" — a program you type commands to.
- **Node.js / npm** — Node.js is a free runtime you install once from [nodejs.org](https://nodejs.org); it includes **npm**, the installer used to add the AI tools (`npm install -g ...`).
- **Download / clone** — "download" is the ZIP method in [Install](#install-limitshift). "Clone" is the Git way of copying a project; if you don't use Git, just download the ZIP.
- **PATH** — the list of places your computer looks to find a program by name. "Not found on PATH" just means it can't find that tool — usually because it isn't installed yet.
- **Headless / in the background** — running a tool silently with no one watching, so it can't stop to ask questions. That's how LimitShift runs the AI, which is why you trust the folder (and set a permission flag) ahead of time.
- **Flag / argument** — an extra option you add to a command, like `--permission-mode acceptEdits`. In your queue these go in `extraArgs`.
- **Prompt** — your request to the AI, written in plain language.
- **Task** — one item on your to-do list (one prompt for one tool in one folder).
- **Queue** — your whole to-do list (the `.json` file).
- **`AGENTS.md`** — a file in this folder that teaches AI coding tools how to fill in your queue, so you can *ask your agent* to write `limitshift-queue.json` for you instead of editing it by hand.
- **Session** — one ongoing conversation with the AI. "Resuming the same session" means the AI still remembers the earlier part.
- **Usage limit / quota** — the cap on how much you can use the AI in a window of time. It resets after a while.
- **Git / version control** — a system that tracks every change to your files so you can review or undo them. Running only in a Git folder is your safety net.
- **JSON** — a plain-text format for writing structured lists. Your queue file is JSON.
- **`[[TASK_COMPLETE]]`** — a marker the AI is asked to put at the end of its reply to signal "this task is finished," used in completion-checking mode.

---

# Reference

Everything below is detail you can come back to when you need a specific option. The sections above are enough to get real work done.

## How it works

1. Read a JSON queue file containing `name`, `cli`, `projectPath`, `prompt`, and optional per-task settings.
2. Validate the JSON, required fields, project paths, and CLI binaries.
3. Start the task in the target project folder using structured JSON/JSONL output.
4. Parse the output to decide whether the task finished, blocked, hit a limit, or failed.
5. On limit, wait until the reset time or fall back to `limitWaitMinutes`.
6. Resume the same Claude/Codex/Gemini session when supported.
7. Mark only completed real runs as done so re-runs skip finished work.

```text
run -> parse output -> complete?
                   |-> yes: mark done, next task
                   |-> limit: wait, resume same session
                   |-> error: retry or stop
                   |-> no marker yet: resume same session
```

## Configuration reference

The queue file is `limitshift-queue.json` by default. Copy one of the example files and edit it. (The old default name `ai-run-queue.json` is still accepted as a fallback for one release — the runner uses it if `limitshift-queue.json` is absent and prints a warning telling you to rename it.)

| Field | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| `settings.stopOnError` | boolean | no | `true` | Stop the queue after an unrecoverable task failure |
| `settings.maxRunsPerTask` | integer | no | `20` | Cap new + resumed runs per task |
| `settings.maxRetriesOnError` | integer | no | `2` | Retries for non-limit failures |
| `settings.limitWaitMinutes` | integer | no | `30` | Fallback wait when reset time cannot be parsed |
| `settings.resetBufferMinutes` | integer | no | `2` | Extra buffer added after parsed reset time |
| `settings.completionCheck` | boolean | no | `true` | `true` injects the `[[TASK_COMPLETE]]` instructions and resumes until the marker appears; `false` ("simple mode") sends the prompt verbatim and marks the task done after the first OK run (only a usage limit triggers a resume) |
| `settings.maxStalls` | integer | no | `2` | When `completionCheck` is `true`, fail the task after this many identical no-marker responses in a row |
| `tasks[].name` | string | yes | none | Human-readable task name |
| `tasks[].cli` | string | yes | none | `claude`, `codex`, or `gemini` |
| `tasks[].projectPath` | string | yes | none | Folder the CLI runs inside (must exist) |
| `tasks[].prompt` | string | yes | none | Task prompt |
| `tasks[].model` | string or array of strings | no | none | Passed through where supported. An array lists models in preference order; on a usage limit the runner rotates to the next model (see below). Primarily useful for gemini |
| `tasks[].effort` | string or null | no | none | Reasoning effort, allowed values per CLI (enforced at validation): **claude** `low`, `medium`, `high`, `xhigh`, `max`; **codex** `minimal`, `low`, `medium`, `high`, `xhigh`; **gemini** must be `null` (it has no effort flag — use `thinkingLevel`/`thinkingBudget` via gemini settings instead). Claude Haiku supports no effort, so claude + a haiku model must also be `null`. `ultracode` (claude's interactive `/effort` menu) and codex `none` (plan-mode only) are rejected |
| `tasks[].completionCheck` | boolean | no | inherits `settings.completionCheck` | Per-task override of completion checking |
| `tasks[].extraArgs` | string or array | no | none | Extra CLI flags (this is where permission flags go — see [Permissions](#permissions-warning)) |

`model` aliases (passed through to each CLI):

- **claude**: `fable`, `opus`, `sonnet`, `haiku` (or the full ids, e.g. `claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5`).
- **codex**: `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`. (`gpt-5-codex` and `gpt-5.2` are deprecated.)
- **gemini**: `gemini-3.*` (e.g. `gemini-3.1-pro-preview`, `gemini-3-flash-preview`) and `gemini-2.5-*` (e.g. `gemini-2.5-pro`, `gemini-2.5-flash`).

`extraArgs` rules:

- Array form is safest when a flag value contains spaces.
- String form is split on whitespace.
- The runner filters `-C` / `--cd`, `--sandbox`, and `--add-dir` from `codex exec resume` because current Codex resume commands reject them.

Windows paths in JSON — **double every backslash** (`\\`), because a single backslash has a special meaning in JSON:

```json
{ "projectPath": "C:\\Users\\me\\repo" }   // correct
{ "projectPath": "C:\Users\me\repo" }       // wrong — will fail to parse
```

If you'd rather not deal with escaping, **forward slashes also work** on Windows:

```json
{ "projectPath": "C:/Users/me/repo" }
```

If your editor supports JSON Schema, keep the `$schema` line from the example file to get inline validation as you type.

## Per-CLI behavior

| CLI | Run mode | Resume mode | Limit detection |
| --- | --- | --- | --- |
| Claude | `claude -p --output-format json` | Native `--resume <session-id>` | Parses `claude -p "/usage"` for session and weekly resets |
| Codex | `codex exec --json` | `codex exec resume <thread-id> --json` | Parses JSONL error events and error text |
| Gemini | `gemini -p --output-format json` | Uses `--resume <session-id>` when supported by the installed CLI, otherwise falls back to a continuation prompt | Parses JSON error text / 429s, then falls back to `limitWaitMinutes` |

### Model rotation on usage limits

Set `tasks[].model` to an array of model names in preference order (most useful for gemini, e.g. `["gemini-3-flash-preview", "gemini-2.5-flash", "gemini-2.5-pro"]`). When a run hits a usage limit, LimitShift switches to the **next** model in the list and retries immediately in the same session (a resume) — no waiting. Only once **every** listed model has been limit-exhausted does it fall back to the normal wait-for-reset path, after which it restarts from model #1. The current position is remembered per task across restarts. A single-string `model` behaves exactly as before (limit → wait → resume the same model).

Switching models mid-session relies on gemini/claude resume. If a CLI rejects a model mid-resume, the existing error-retry path covers it.

## Permissions warning

Headless runs cannot answer permission prompts. Decide your risk posture explicitly through `extraArgs`. **If you leave these out, the AI runs read-only and won't change any files.**

Examples:

- Claude: `--permission-mode acceptEdits` or `--dangerously-skip-permissions`
- Codex: `--sandbox workspace-write` or `--dangerously-bypass-approvals-and-sandbox`
- Gemini: `--approval-mode auto_edit` or `--approval-mode yolo`

More autonomy means more risk. Run this only against version-controlled project folders.

## Running

Validate first:

```powershell
.\limitshift.ps1 -ValidateOnly
```

```bash
./limitshift.sh --validate-only
```

Dry run prints the exact commands and does not mark tasks done:

```powershell
.\limitshift.ps1 -DryRun
```

```bash
./limitshift.sh --dry-run
```

Run the default queue file:

```powershell
.\limitshift.ps1
```

```bash
./limitshift.sh
```

Use a custom queue path:

```powershell
.\limitshift.ps1 -QueuePath .\my-queue.json
```

```bash
./limitshift.sh --queue ./my-queue.json
```

The console shows only the agent's response text (under a `--- agent response ---` header); the full raw CLI JSON is still written to `outputs/task-NN-<slug>-output.txt`. To print the raw JSON to the console instead (useful for debugging), use:

```powershell
.\limitshift.ps1 -ShowRawOutput
```

```bash
./limitshift.sh --show-raw
```

Keep the machine awake for long runs:

- Windows: adjust sleep settings (Settings → System → Power) or use `presentationsettings`
- macOS: `caffeinate -i ./limitshift.sh`
- Linux: `systemd-inhibit ./limitshift.sh`

## Where LimitShift keeps its notes

LimitShift keeps everything it remembers in one folder, `.limitshift-<queue-name>/`, created next to your queue file. For the default queue file `limitshift-queue.json`, that folder is literally named `.limitshift-limitshift-queue/`. It is built and maintained automatically, and a plain-language `_README.txt` explaining the layout is dropped inside it on every run.

Where state lives and what is in it:

- `sessions/` — saved CLI session / thread ids so a task can resume the **same** conversation.
- `outputs/` — the full raw output of every run, one file per task named `task-NN-<slug>-output.txt` (zero-padded task number plus a slug of the task name).
- `status/` — per-task markers: `task-NN.done` when a task finished, `task-NN.failed` when it blocked or failed.
- `runs.csv` — one row per CLI run with `timestamp, task, run, mode (New/Resume), exit, status`. Open it in any spreadsheet to see what happened across the whole queue.
- `limitshift-log.txt` — the full runner transcript.
- `_README.txt` — the same explanation, right next to the data.

Editing a task auto-invalidates its done marker. When you change a task's `name`, `prompt`, `cli`, `projectPath`, `model`, `effort`, or `extraArgs` and run again, LimitShift notices the change (it stores a fingerprint of those fields inside the `.done` file), throws away the stale `.done` marker and the old session id, and **re-runs that task with a fresh session**. Tasks you did not touch keep being skipped.

To re-run **one** finished task by hand, delete its `status/task-NN.done` file. To start **completely over**, delete the whole `.limitshift-<queue-name>/` folder. The entire state folder is safe to delete at any time — LimitShift recreates whatever it needs on the next run.

## Completion marker

When `completionCheck` is `true`, the runner appends `[[TASK_COMPLETE]]` instructions to every prompt automatically. A task is marked done when the **last non-empty line of the response contains** `[[TASK_COMPLETE]]` — so a line like `OK[[TASK_COMPLETE]]` or the marker on its own both count. The marker only counts on that final line, so the agent can mention it earlier in its reply without accidentally completing the task.

If the agent cannot finish, it should end with:

```text
[[TASK_BLOCKED]] <one-line reason>
```

Prompts should therefore describe concrete end conditions such as "write `docs/audit.md` and summarize the changes".

## Troubleshooting

| Message | Meaning | Fix |
| --- | --- | --- |
| `Config file is not valid JSON` | Broken JSON syntax | Check for trailing commas, missing commas, or bad escaping (use forward slashes in paths) |
| `Task N is missing required JSON property` | A task is missing `name`, `cli`, `projectPath`, or `prompt` | Fix the named field |
| `Allowed values: claude, codex, gemini` | Unsupported `cli` value | Use one of the supported CLIs |
| `Project path does not exist` | `projectPath` is wrong | Fix the path or create the folder |
| `not found on PATH` | Required CLI is not installed or not on PATH | Install the CLI and retry |
| `jq is required but not installed` | Unix runner cannot parse JSON without `jq` | Install `jq` (Mac `brew install jq`, Linux `sudo apt install jq`) |
| `Task N exceeded maxRunsPerTask` | The task never finished or kept resuming | Inspect the prompt/output and raise the cap only if needed |
| `installed gemini rejects --resume` | Your Gemini CLI build does not support headless resume | The runner will retry with a continuation prompt |
| The AI reported success but nothing changed | No permission flag, so it ran read-only | Add the right `extraArgs` permission flag (see [Permissions](#permissions-warning)) |

## Running the tests

PowerShell regression suite (requires Pester 5):

```powershell
Invoke-Pester tests/limitshift.Tests.ps1
```

Install Pester 5 if needed:

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
```

Bash regression suite:

```bash
bash tests/test-limitshift.sh
```

On Windows, run the bash suite from Git Bash, or from PowerShell with:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' tests/test-limitshift.sh
```

## License

MIT. See [`LICENSE`](LICENSE).
