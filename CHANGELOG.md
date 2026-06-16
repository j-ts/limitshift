# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-06-16

### Fixed
- **Claude usage printed once instead of twice (`limitshift.ps1`).** `Get-ClaudeUsage` contained leftover debug `Write-Host` lines that printed exit code, session %, and week % immediately after parsing; `Wait-UntilClaudeUsageReady` then printed the same numbers again as proper user-facing output. Removed the debug lines and consolidated into a single print that includes the reset times.
- **Usage-limit reset times are now honored instead of being silently dropped (`limitshift.ps1`).** `Get-ResetTimeFromErrorText` always failed to parse the `try again at <time>` form: the `-replace` written inside the `[datetime]::ParseExact(...)` call had its comma bound as a method-argument separator, producing a four-argument `ParseExact` with no matching overload. The exception was swallowed by an empty `catch`, so a precise reset time (e.g. codex's `try again at 7:21 PM`) was discarded and the runner always fell back to the configured `limitWaitMinutes` wait — surfacing as `no reset time in the error · waiting the configured 30 min` even when the error clearly stated the time.

### Added
- **Date-aware reset parsing (`limitshift.ps1`).** Reset extraction now accepts an optional date in front of the clock, so `try again at Jun 16, 7:21 PM`, `resets at June 16 7:21 PM`, `2026-06-16 19:21`, and `2026-06-16T19:21` all parse, in addition to bare clocks (`7:21 PM`, `19:21`, `7pm`). Parsing uses `TryParseExact` (no exceptions in the loop) plus a loose `TryParse` fallback; bare clocks already past roll to tomorrow, and dated times without a year that are already past roll to next year.
- **Regression tests** for `Get-ResetTimeFromErrorText` covering the original codex bug case (direct and end-to-end), the new date+time formats, clock roll-forward, the relative `try again in` / `reset after` / `retryDelay` branches, and the no-match case.

## [1.0.0] - 2026-06-15

### Added
- **Multi-CLI queue runner** for five coding-agent CLIs — Claude Code (`claude`), Codex (`codex`), Gemini CLI (`gemini`), Antigravity (`agy`), and GitHub Copilot CLI (`copilot`) — driven from one JSON queue. PowerShell (`limitshift.ps1`, Win PS 5.1+) and Bash (`limitshift.sh`, macOS/Linux, bash 3.2) with identical flags and behavior.
- **First-class multi-queue support** with `--queue-path` / `-QueuePath`, isolated `limitshift-<name>/` state folder per queue (sessions, outputs, status markers, transcripts, `runs.csv`), and a PID-based concurrency lock that prevents two runners from clobbering the same queue.
- **Resilient prompt + completion handling**: multi-line prompts delivered safely on every platform (stdin where supported, `-p` for `agy` / `copilot`), `[[TASK_COMPLETE]]` / `[[TASK_BLOCKED]] <reason>` marker detection (lenient — anywhere on the last non-empty line), resume always re-sends the original task so `/goal` and context survive, plus a no-progress stall guard so a stuck agent fails instead of burning every retry.
- **Per-task model rotation + dynamic model validation**: `tasks[].model` can be a list and the runner cycles on usage limits; a `--validate-only` pass discovers each CLI's model list where one exists, suggests close matches on typos via Levenshtein, caches results under `limitshift-<name>/capabilities/`, and supports `--refresh-capabilities` / `--probe-models` plus a tri-state `settings.modelValidation` (`strictWhenDiscoverable` / `warn` / `off`). Per-CLI effort validation rejects bad `effort` values at queue load.
- **Local models via Ollama** for `claude` and `codex` via the `["--oss", "--local-provider", "ollama"]` shape — `codex` natively, `claude` through an `ollama launch` wrapper. Local runs skip the cloud usage check.
- **Operational modes**: `--validate-only` / `-ValidateOnly` (parse, schema-check, binary-check, model-check, no runs), `--dry-run` / `-DryRun` (print every assembled command at column 0, no runs), `-ShowRawOutput` / `--show-raw` (full raw JSON/JSONL on console plus the command line), and `--demo` / `-Demo` (no-network walkthrough using the shipped workflow example).
- **Fingerprint-based done invalidation and self-documenting state**: every `.done`/`.failed` marker stores a SHA-256 fingerprint of the task definition, so editing prompt/model/effort/extraArgs auto-invalidates the marker and drops the stale session. Each state folder ships a `_README.txt` and a `runs.csv` of one row per CLI run.
- **Per-CLI plumbing for the awkward ones**: `agy`'s reply is recovered from its on-disk conversation transcript (since `-p` renders to a TTY) with `LIMITSHIFT_AGY_DATA_DIR` override; `copilot`'s JSONL parser drills into the `data.*` payload; on Windows, native-exe arguments are delivered as one canonical command-line string so multi-line prompts and spaces in paths survive `CreateProcess`.
- **Magenta-accent preview UI**: per-task header with a quoted prompt preview, animated working spinner (frames go to `/dev/tty` so they stay out of piped logs), past-tense usage-limit beat with a moon countdown and a >24h guard, dim separators between tasks, compact resume one-liners (no repeated header on within-run retries/resumes), and a multi-variant final summary that distinguishes all-done vs nothing-to-do vs partial-failure and includes a "delete the state folder to redo skipped tasks" hint.
- **User-facing docs and examples**: beginner-friendly README + QUICKSTART aimed at non-terminal users; `AGENTS.md` (plus `CLAUDE.md` / `GEMINI.md` pointers) so an AI agent can build the queue for you; three shipped example queues (`simple`, `workflow`, `advanced`).
- **Regression test suites**: Pester for PowerShell and a pure-bash harness for the Unix runner, end-to-end against stubbed CLI binaries — 159 + 81 tests, all green.
