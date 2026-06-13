# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-12

### Added
- **Multi-CLI Support**: Native integration for Claude Code (`claude`), Codex (`codex`), and Gemini CLI (`gemini`).
- **Cross-Platform Runners**: Added PowerShell `run-ai.ps1` (Windows PowerShell 5.1+) and Bash `run-ai.sh` (macOS/Linux compatible down to Bash 3.2).
- **Validation Modes**: Added configuration validation checks (`-ValidateOnly` / `--validate-only`) to check JSON syntax, task schema requirements, folder existence, and tool bin availability at startup.
- **Dry-run Execution**: Support for dry-run simulation (`-DryRun` / `--dry-run`) to preview command line construction.
- **Structured JSON Parsing**: Replaced regex console scraping with structured JSON/JSONL output parsing and automated limit wait recovery.
- **Regression Tests**: Added a Pester 5 suite for PowerShell and a pure Bash test harness for the Unix runner.
