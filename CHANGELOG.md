# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Example queues**: ship `limitshift-queue.example-simple.json` (one task, required fields only, `completionCheck: false`) and `limitshift-queue.example-advanced.json` (3 tasks exercising every optional field). The legacy `limitshift-queue.example.json` is now a copy of the simple example. A regression test in both suites validates all three shipped examples with `-ValidateOnly` / `--validate-only`.
- **Beginner-friendly README**: top-down rewrite (what it is, expectations callout, simple example, advanced example) with the reference material moved under a `## Reference` heading.

### Changed
- **Naming alignment**: renamed the runner scripts to `limitshift.ps1` / `limitshift.sh`, the default queue file to `limitshift-queue.json`, the shipped example/schema to `limitshift-queue.example.json` / `limitshift-queue.schema.json`, and the per-queue state folder to `.limitshift-<queue-name>/` (was `.ai-runner-<queue-name>/`).
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
