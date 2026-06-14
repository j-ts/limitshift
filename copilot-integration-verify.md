# Copilot Backend Integration — Verification Report

Date: 2026-06-14

## Scope Reviewed

- `AGENTS.md`
- `README.md`
- `QUICKSTART.md`
- `CHANGELOG.md`
- `limitshift-queue.schema.json`
- `limitshift-queue.example.json`
- `limitshift-queue.example-simple.json`
- `limitshift-queue.example-workflow.json`
- `limitshift-queue.example-advanced.json`
- `limitshift.ps1`
- `limitshift.sh`
- `tests/limitshift.Tests.ps1`
- `tests/test-limitshift.sh`

## Verification Commands

| Command | Result |
|---|---|
| `.\limitshift.ps1 -ValidateOnly` | PASS |
| `Invoke-Pester tests/limitshift.Tests.ps1` | PASS — 159/159 |
| `C:\Program Files\Git\bin\bash.exe tests/test-limitshift.sh` | PASS — 81/81 |
| `C:\Program Files\Git\bin\bash.exe ./limitshift.sh --validate-only` | PASS |

## Findings Resolved

### F-1 — Copilot model discovery docs were inaccurate

Resolved.

- `README.md`, `AGENTS.md`, `CHANGELOG.md`, and `limitshift-queue.schema.json` no longer tell users to run `copilot models`.
- Both runners now treat Copilot as having no scriptable model-list command and print INFO-style validation behavior instead of calling a non-existent subcommand.

### F-2 — Copilot resume flag shape was risky

Resolved.

- Both runners now emit `--resume=<session-id>` for Copilot resume runs.
- Arg-construction tests were updated to match.
- Both suites now include end-to-end Copilot resume-after-limit coverage.

### F-3 — Bash verification blockers

Resolved.

- The Bash suite no longer uses brittle `sed`-based shell-function extraction for runner helpers.
- `limitshift.sh` now supports `LIMITSHIFT_SOURCE_ONLY=1` so tests can source helper functions without executing the runner.
- The simple-mode resume assertion was tightened to check for the absence of the automation block rather than overmatching prompt text.

## Documentation Update

Changed docs/schema text now consistently describe:

- supported CLIs: `claude`, `codex`, `gemini`, `agy`, `copilot`
- Copilot recommended edit args:
  `["--allow-tool=read,write,shell(npm:*),shell(npx:*),shell(git:*)", "--deny-tool=shell(git push)", "--no-ask-user"]`
- Copilot full automation mode:
  `["--allow-all", "--no-ask-user"]`
- install/login guidance via `gh extension install github/gh-copilot` and `copilot login`
- prompt transport via `-p`
- JSONL parsing behavior
- session behavior via `--name` and `--resume=<session-id>`
- current model-validation reality: Copilot model names are passed through, not discovered from a CLI model list

## Files Changed In Closeout

- `README.md`
- `QUICKSTART.md`
- `AGENTS.md`
- `CHANGELOG.md`
- `limitshift-queue.schema.json`
- `limitshift.ps1`
- `limitshift.sh`
- `tests/limitshift.Tests.ps1`
- `tests/test-limitshift.sh`

## Residual Risk

- Copilot's live JSONL schema could still change in future CLI releases. The parsers remain intentionally tolerant and fall back to raw text when needed.
