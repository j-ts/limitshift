# Strategies

Practical guidance for getting the best results from LimitShift — especially when using CLI rotation.

---

## Writing high-quality prompts

The quality of LimitShift's results depends almost entirely on how you write prompts. Each task is one isolated CLI run; the model has no memory of your past sessions, so everything the agent needs must be in the prompt.

**Match detail to difficulty.** A capable model with a precise task can work from a short prompt. A broad or fuzzy goal, or a smaller/cheaper model, needs step-by-step detail, named files, and an explicit definition of "done." Don't pad a clear task, and don't under-specify a vague one.

**Name files and artifacts explicitly.** "Audit the codebase" is vague. "Read every `.ts` file under `src/` and write a list of security issues to `docs/security-audit.md`, one issue per line with file path and line number" is actionable.

**Define "done" in the prompt.** The agent decides when a task is complete. Without a concrete endpoint ("all tests pass," "the file `docs/audit.md` exists and has at least five entries"), the agent may stop early or loop indefinitely.

**Use `/goal` for broad tasks (claude, codex only).** Begin the prompt with `/goal <your goal>` so the agent sets its own success criteria and tracks them. Gemini has no `/goal` command.

**Split multi-stage work into separate tasks.** Each task is its own CLI run. "Audit the code, then fix the issues, then write release notes" should be three tasks in sequence, where each reads the output of the previous one.

**Chain outputs intentionally.** Write task N so its output is the input to task N+1. For example: task 1 writes `bugs.md`, task 2 fixes the entries in `bugs.md`, task 3 verifies and marks each entry resolved.

**End completion-check prompts with the marker sentence.** When `completionCheck: true`, the prompt should say: *"End with `[[TASK_COMPLETE]]` on its own line when the task is fully done, or `[[TASK_BLOCKED]] <reason>` if you cannot finish."* This is what the runner looks for to decide the task is done.

**Ask the agent to summarize what it changed.** Useful in the final response for auditing and for the next task in a chain.

---

## Commit a baseline before rotation tasks

**Why git is required.** When a runner switch happens, the new tool starts a fresh session with no memory of what the previous tool did. The only reliable record of partial progress is the working tree. LimitShift prepends a handoff note that tells the incoming tool to inspect `git status` (new/untracked files) and `git diff` (changes to tracked files) before starting.

**The problem without a baseline commit.** If the repo has no commits, `git diff` is empty even for new files (untracked files are not tracked by `git diff`). The handoff note covers this with `git status`, but the incoming tool gets less context.

**What to do:** before running a queue with rotation tasks, make sure the project has at least one commit. Ideally, commit the current state of every file the task will touch, so `git diff` cleanly shows only the partial progress from the interrupted tool.

```bash
git add -A && git commit -m "baseline before LimitShift rotation run"
```

LimitShift itself never commits, stashes, or modifies git history. The commit is yours to make.

---

## Choosing models and tools

**For the primary runner**, use your best model. If the task is complex, pick `opus` or `gpt-5.5`; if it is straightforward, `sonnet` or `gpt-5.4` is usually enough.

**For fallbacks**, think about what each tool brings:

- `claude` — strongest at reasoning and following complex instructions; Haiku is cheap for simple tasks.
- `codex` — strong at code; the `effort` flag (`minimal` through `xhigh`) controls how deeply it thinks.
- `gemini` — good general coding model; model arrays (e.g. `["gemini-3-flash-preview", "gemini-2.5-pro"]`) give you model rotation within that runner.
- `agy` — Antigravity (Google's successor to Gemini CLI for personal accounts); useful when Gemini CLI is unavailable or on personal AI Pro/Ultra plans. No session isolation between tasks; keep agy in a single linear chain.
- `copilot` — GitHub Copilot CLI; `effort` from `low` to `max`.

**Model arrays give model rotation within a runner.** A fallback with `"model": ["gemini-3-flash-preview", "gemini-2.5-pro"]` will try `gemini-3-flash-preview` first and switch to `gemini-2.5-pro` on a limit — all within one fresh session. Use model arrays when you have multiple tier quotas for the same tool.

**Same-tool variation → model array, not fallbacks.** If two runners share the same `cli` and `extraArgs`, a tool-level failure (bad flag, missing binary) will repeat on both. Express same-tool variation as a model array on one runner; reserve `fallbacks` for genuinely different tools that offer different access or different capabilities.

---

## Completion-check vs simple mode

**`completionCheck: true` (default)** — the runner keeps resuming the task until the agent emits `[[TASK_COMPLETE]]` or `[[TASK_BLOCKED]] <reason>`. Use this for:

- Multi-step work that may need several rounds (implement, run tests, fix failures, re-run).
- Tasks where "done" means a file was written or a condition was met — not just that the agent replied.
- Any rotation task where a handoff may interrupt progress mid-step.

**`completionCheck: false` (simple mode)** — the task is marked done after the first successful run. Use this for:

- One-shot prompts that produce a complete answer in one pass (e.g. "explain this function").
- Tasks where you just want the reply, not a tracked completion state.
- Throwaway or exploratory prompts.

For rotation tasks, `completionCheck: true` is almost always the right choice. The handoff note (which the incoming tool receives on a runner switch) explicitly asks it to continue from partial progress and end with `[[TASK_COMPLETE]]`.

---

## The `maxRunsPerTask` budget for rotation

`maxRunsPerTask` (default `20`) counts every CLI invocation — including limit-discovery runs, retries, and stall checks. Waits do not count.

A single-runner task with two models and two retries per model uses roughly `models × retries` runs per progress attempt. A rotation task multiplies that across runners:

> **rough budget = Σ over runners [ models × (retries + stalls + progress-resumes) ]**

As a practical rule of thumb: **set `maxRunsPerTask` to at least 10 × the number of runners** for a rotation task. For a 3-runner task (claude → codex → gemini), `30` is a reasonable starting point.

When the cap is reached on a rotation task, LimitShift marks the task failed and applies `stopOnError` — it does **not** abort the whole queue. Raise the cap if you see "exceeded maxRunsPerTask" before the task finishes genuine work.

---

## Example workflows

### Overnight rotation: fix everything

Queue a fix task with a full rotation roster. Start before bed, check in the morning.

```json
{
  "tasks": [
    {
      "name": "Fix all failing tests",
      "cli": "claude",
      "model": ["opus", "sonnet"],
      "projectPath": "C:/Users/you/my-project",
      "completionCheck": true,
      "extraArgs": ["--permission-mode", "acceptEdits"],
      "prompt": "Run the test suite. Fix every failing test. Re-run until all pass. End with [[TASK_COMPLETE]] when they all pass, or [[TASK_BLOCKED]] <reason> if genuinely stuck.",
      "fallbacks": [
        { "cli": "codex", "model": "gpt-5.5", "effort": "high", "extraArgs": ["--sandbox", "workspace-write"] },
        { "cli": "gemini", "model": ["gemini-3-flash-preview", "gemini-2.5-pro"], "extraArgs": ["--approval-mode", "auto_edit"] }
      ]
    }
  ],
  "settings": {
    "maxRunsPerTask": 40,
    "completionCheck": true
  }
}
```

Commit a baseline first, then run:

```powershell
.\limitshift.ps1     # Windows
```
```bash
./limitshift.sh      # Mac / Linux
```

### Review → fix → verify with rotation

Three tasks chained by a shared file. The first two have fallbacks; the final verify step does not need them.

```json
{
  "tasks": [
    {
      "name": "Audit security issues",
      "cli": "claude",
      "model": "sonnet",
      "projectPath": "C:/Users/you/my-project",
      "completionCheck": true,
      "extraArgs": ["--permission-mode", "acceptEdits"],
      "prompt": "Read every file under src/. Write a list of security issues to docs/security-audit.md, one per line with file path, line number, and description. End with [[TASK_COMPLETE]] when done.",
      "fallbacks": [
        { "cli": "codex", "model": "gpt-5.4", "extraArgs": ["--sandbox", "workspace-write"] }
      ]
    },
    {
      "name": "Fix security issues from audit",
      "cli": "claude",
      "model": ["opus", "sonnet"],
      "projectPath": "C:/Users/you/my-project",
      "completionCheck": true,
      "extraArgs": ["--permission-mode", "acceptEdits"],
      "prompt": "Read docs/security-audit.md. Fix each issue listed. Mark each entry done by prefixing the line with [FIXED]. End with [[TASK_COMPLETE]] when every entry is marked [FIXED].",
      "fallbacks": [
        { "cli": "codex", "model": "gpt-5.5", "effort": "high", "extraArgs": ["--sandbox", "workspace-write"] },
        { "cli": "gemini", "model": "gemini-2.5-pro", "extraArgs": ["--approval-mode", "auto_edit"] }
      ]
    },
    {
      "name": "Verify all fixes",
      "cli": "claude",
      "model": "sonnet",
      "projectPath": "C:/Users/you/my-project",
      "completionCheck": true,
      "extraArgs": ["--permission-mode", "acceptEdits"],
      "prompt": "Read docs/security-audit.md. For each [FIXED] entry, confirm the fix is present in the code. Run the test suite. Report any entry that is NOT actually fixed. End with [[TASK_COMPLETE]] when all entries are confirmed fixed."
    }
  ],
  "settings": {
    "maxRunsPerTask": 30,
    "stopOnError": true
  }
}
```
