# CLAUDE.md

**[AGENTS.md](AGENTS.md) is the canonical agent guide for this repo — read it first.** It covers the
most common task: turning a user's draft into a valid `limitshift-queue.json` (edit only that file,
keep it schema-valid, suggest sensible models, add the right permission flag in `extraArgs` for tasks
that change files). `CLAUDE.md` and `GEMINI.md` are thin shims that point there.

> **"init" / "initialize" / "onboard" / "set up" here does NOT mean documenting the codebase.** Do
> **not** run a generic "init" that analyzes the repo and writes or expands this file (`CLAUDE.md`),
> `README.md`, or other docs — that is the wrong thing here, and it is what bloated this shim before.
> It means **help the user create their LimitShift config**: their model/routing profile
> (`limitshift-profile.json`) and/or a queue (`limitshift-queue.json`). See AGENTS.md →
> "Agent Onboarding & Profile Initialization" and "Queue-Building Workflow". Edit docs only when the
> user explicitly asks.
