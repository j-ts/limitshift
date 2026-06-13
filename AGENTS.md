# AGENTS.md — instructions for AI agents working in this repo

This file tells an AI coding agent (Codex, Claude Code, Gemini, etc.) how to help a user build a
**LimitShift queue**. Agents read this file automatically when the user opens this folder.

**Your most common job:** the user gives you a rough draft of what they want done to *their* project
and asks you to turn it into runnable tasks. Do exactly that, and **edit only `limitshift-queue.json`**
unless the user explicitly asks for more.

A typical request looks like:

> "Read this folder and create prompts for my project based on the draft below. Change only
> `limitshift-queue.json`. Suggest appropriate models and use codex."

## What you are producing

`limitshift-queue.json` is a JSON file with an optional `settings` object and a `tasks` array. LimitShift
runs each task in order through one AI CLI (`claude`, `codex`, or `gemini`), and waits out usage limits.
The authoritative shape is [`limitshift-queue.schema.json`](limitshift-queue.schema.json) — **read it and
keep your output valid against it.** Validate your result with `limitshift.ps1 -ValidateOnly` (Windows) or
`./limitshift.sh --validate-only` before telling the user you're done.

### Required fields, per task

- `name` — short human label.
- `cli` — `"claude"`, `"codex"`, or `"gemini"`. Use what the user asked for (default to `"codex"` only if they say so).
- `projectPath` — the absolute folder the CLI runs in. **On Windows, escape backslashes** (`"C:\\Users\\me\\project"`); forward slashes also work (`"C:/Users/me/project"`). Use the user's actual project path.
- `prompt` — a clear, self-contained instruction. Rewrite the user's draft into a concrete prompt that names files and states what "done" looks like.

### Useful optional fields

- `model` — a string, or an **array** of strings in preference order (rotation: on a usage limit LimitShift switches to the next model). Suggest a sensible model for the CLI (see below).
- `effort` — reasoning effort. **Rules (enforced at validation):** claude `low|medium|high|xhigh|max`; codex `minimal|low|medium|high|xhigh`; **gemini must be `null` or omitted**; claude + a **haiku** model must be `null`. Never use `ultracode` or codex `none`.
- `completionCheck` — `true` (default) makes LimitShift append a `[[TASK_COMPLETE]]` instruction and keep resuming until the agent emits that marker; `false` ("simple mode") just runs the prompt once. Use `true` for multi-step work, `false` for one-shot prompts.
- `extraArgs` — array of extra CLI flags. **Headless runs cannot answer permission prompts, so if the task should edit files you MUST add a permission flag:** claude `["--permission-mode","acceptEdits"]`; codex `["--sandbox","workspace-write"]`; gemini `["--approval-mode","auto_edit"]`. Without it the AI runs read-only and changes nothing.

### Settings (optional, top-level)

`stopOnError` (bool), `maxRunsPerTask` (int), `maxRetriesOnError` (int), `limitWaitMinutes` (int),
`resetBufferMinutes` (int), `completionCheck` (bool, queue-wide default), `maxStalls` (int).

## Suggesting models

- **codex**: `gpt-5.5` or `gpt-5.4` for substantive coding/reasoning; `gpt-5.4-mini` for quick or repetitive tasks. (`gpt-5-codex`, `gpt-5.2` are deprecated — don't use.)
- **claude**: `opus` for the hardest work, `sonnet` for everyday tasks, `haiku` for cheap/simple ones (haiku takes no `effort`).
- **gemini**: `gemini-3-flash-preview` or `gemini-2.5-flash` for speed, `gemini-2.5-pro`/`gemini-3.1-pro-preview` for depth. Gemini takes no `effort`. A model **array** is especially handy for gemini to dodge limits.

Match the model to the task: heavier reasoning → stronger model; bulk/cheap edits → a mini/flash model.

## Rules of engagement

1. **Edit only `limitshift-queue.json`** unless the user says otherwise. Do not modify the scripts, schema, or their project files.
2. **Keep it valid JSON** and schema-compliant. Run `-ValidateOnly` / `--validate-only` and fix any error before finishing.
3. **Turn vague drafts into concrete prompts** — name the files, describe the end state. Chain multi-step work into separate tasks (e.g. find → fix → verify), because each task is its own CLI run and tasks run in order.
4. **Add the right permission flag** in `extraArgs` whenever a task is meant to change files.
5. **Use the user's real `projectPath`.** If you don't know it, ask, or use the current folder.
6. Briefly tell the user which models you chose and why.

## Example: turning a draft into a queue

User draft: *"go through my project, find bugs, fix them, then double-check. use codex."*

A good `limitshift-queue.json`:

```json
{
  "$schema": "./limitshift-queue.schema.json",
  "settings": { "stopOnError": true, "completionCheck": true },
  "tasks": [
    {
      "name": "Find bugs",
      "cli": "codex",
      "projectPath": "C:\\Users\\me\\my-project",
      "model": "gpt-5.4",
      "effort": "high",
      "extraArgs": ["--sandbox", "workspace-write"],
      "prompt": "Review the code in src/ and write every bug or issue you find to bugs.md — one numbered item per bug, each with its file path and a short description. Do not fix anything yet."
    },
    {
      "name": "Fix bugs",
      "cli": "codex",
      "projectPath": "C:\\Users\\me\\my-project",
      "model": "gpt-5.4",
      "effort": "high",
      "extraArgs": ["--sandbox", "workspace-write"],
      "prompt": "Read bugs.md and fix each listed issue one by one. After fixing an item, append ' — FIXED' to its line in bugs.md."
    },
    {
      "name": "Verify fixes",
      "cli": "codex",
      "projectPath": "C:\\Users\\me\\my-project",
      "model": "gpt-5.4",
      "effort": "high",
      "extraArgs": ["--sandbox", "workspace-write"],
      "prompt": "Read bugs.md, review the current implementation against each item, and mark each line 'Verified fixed' or 'Still broken: <why>'."
    }
  ]
}
```

Then validate it and report which models you used.
