See [AGENTS.md](AGENTS.md) for how to work in this repo — in particular, how to build a
`limitshift-queue.json` from a user's draft (edit only that file, keep it schema-valid, suggest
sensible models, and add the right permission flag in `extraArgs` for tasks that change files).

**"init" / "initialize" / "onboard" / "set up" here does NOT mean documenting the codebase.** Do not
analyze the repo or write/expand this file, `README.md`, or other docs. It means **help the user
create their LimitShift config** — their model/routing profile (`limitshift-profile.json`) and/or a
queue (`limitshift-queue.json`). See AGENTS.md → "Agent Onboarding & Profile Initialization" and
"Queue-Building Workflow". Edit docs only when the user explicitly asks.
