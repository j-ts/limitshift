#!/usr/bin/env bash
# Test harness for run-ai.sh. Run: bash tests/test-run-ai.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../run-ai.sh"
CONFIGS="$HERE/fixtures/configs"
PASS=0; FAIL=0

# Clean up state directories from previous dry-runs/tests
rm -rf "$CONFIGS"/.ai-runner-*

check() { # check <description> <expected_exit> <grep_pattern> -- <cmd...>
  local desc="$1" want_exit="$2" pattern="$3"; shift 4
  rm -rf "$CONFIGS"/.ai-runner-*
  local out exit_code
  out=$("$@" 2>&1); exit_code=$?
  if [ "$exit_code" -eq "$want_exit" ] && printf '%s' "$out" | grep -qiE "$pattern"; then
    PASS=$((PASS+1)); echo "ok   - $desc"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $desc (exit=$exit_code, wanted $want_exit)"; printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

check "valid minimal config validates"           0 "Config OK"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-minimal.json" --validate-only
check "valid full config validates"              0 "Config OK"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-full.json" --validate-only
check "trailing comma rejected with explanation" 2 "not valid JSON"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-trailing-comma.json" --validate-only
check "missing field rejected naming the field"  2 "Task 1.*prompt"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-missing-field.json" --validate-only
check "unknown cli rejected listing allowed"     2 "claude, codex, gemini" -- bash "$SCRIPT" --queue "$CONFIGS/broken-bad-cli.json" --validate-only
check "missing project path rejected"            2 "does not exist"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-missing-path.json" --validate-only
check "dry run prints claude command"            0 "claude .*--output-format json" -- bash "$SCRIPT" --queue "$CONFIGS/valid-full.json" --dry-run
check "dry run prints codex command"             0 "codex exec --json"     -- bash "$SCRIPT" --queue "$CONFIGS/valid-full.json" --dry-run
check "dry run prints gemini command"            0 "gemini -p"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-full.json" --dry-run
check "missing queue file gives copy hint"       2 "ai-run-queue.example.json" -- bash "$SCRIPT" --queue "$HERE/nope.json" --validate-only

echo
echo "passed: $PASS  failed: $FAIL"
exit "$FAIL"
