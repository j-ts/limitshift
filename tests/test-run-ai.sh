#!/usr/bin/env bash
# Test harness for run-ai.sh. Run from bash/Git Bash: bash tests/test-run-ai.sh
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../run-ai.sh"
CONFIGS="$HERE/fixtures/configs"
PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/limitshift-shell-tests.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT" "$CONFIGS"/.ai-runner-*
}

trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  echo "ok   - $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL - $1"
  if [ $# -gt 1 ]; then
    printf '%s\n' "$2" | sed 's/^/       /'
  fi
}

check() { # check <description> <expected_exit> <grep_pattern> -- <cmd...>
  local desc="$1" want_exit="$2" pattern="$3"
  shift 4
  local out exit_code
  out=$("$@" 2>&1)
  exit_code=$?
  if [ "$exit_code" -eq "$want_exit" ] && printf '%s' "$out" | grep -qiE "$pattern"; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code (wanted $want_exit)
$out"
  fi
}

assert_no_done_files() {
  local dir="$1"
  if find "$dir" -name '*.done' -print -quit 2>/dev/null | grep -q .; then
    return 1
  fi
  return 0
}

reset_fixture_state() {
  rm -rf "$CONFIGS"/.ai-runner-*
}

run_dry_run_state_test() {
  local desc="dry run prints commands without persisting done markers"
  reset_fixture_state

  local out exit_code state_dir
  out=$(bash "$SCRIPT" --queue "$CONFIGS/valid-full.json" --dry-run 2>&1)
  exit_code=$?
  state_dir="$CONFIGS/.ai-runner-valid-full"

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Command: claude' &&
     printf '%s' "$out" | grep -q 'Command: codex' &&
     printf '%s' "$out" | grep -q 'Command: gemini' &&
     assert_no_done_files "$state_dir"; then
    pass "$desc"
  else
    fail "$desc" "$out"
  fi
}

write_fake_codex() {
  local bin_dir="$1" log_file="$2"
  cat > "$bin_dir/codex" <<EOF
#!/usr/bin/env bash
set -u
cat > /dev/null
printf '%q ' "\$@" >> "$log_file"
printf '\n' >> "$log_file"
if [ "\${1:-}" = "exec" ] && [ "\${2:-}" = "resume" ]; then
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"done\\n\\n[[TASK_COMPLETE]]"}}'
  exit 0
fi
printf '%s\n' '{"type":"thread.started","thread_id":"thr-limit"}'
printf '%s\n' '{"type":"error","message":"You have hit your usage limit. Try again in 0s."}'
printf '%s\n' '{"type":"turn.failed","error":{"message":"You have hit your usage limit. Try again in 0s."}}'
exit 1
EOF
  chmod +x "$bin_dir/codex"
}

run_codex_limit_resume_test() {
  local desc="codex limit detection resumes without -C or sandbox flags"
  local root="$TMP_ROOT/codex-limit"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local log_file="$root/codex-args.log"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_codex "$bin_dir" "$log_file"

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 3,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0
  },
  "tasks": [
    {
      "name": "codex limit task",
      "cli": "codex",
      "projectPath": "$project_dir",
      "model": "gpt-5-codex",
      "effort": "high",
      "extraArgs": ["--sandbox", "workspace-write", "--skip-git-repo-check"],
      "prompt": "finish the work"
    }
  ]
}
EOF

  local out exit_code
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    fail "$desc" "$out"
    return
  fi

  local first_call second_call
  first_call="$(sed -n '1p' "$log_file")"
  second_call="$(sed -n '2p' "$log_file")"

  if printf '%s' "$out" | grep -q 'paused by a usage limit on codex' &&
     printf '%s' "$out" | grep -q 'Task 1 completed' &&
     printf '%s' "$first_call" | grep -q -- '--sandbox workspace-write' &&
     ! printf '%s' "$first_call" | grep -q -- ' -C ' &&
     printf '%s' "$second_call" | grep -q '^exec resume thr-limit --json -m gpt-5-codex -c model_reasoning_effort=high --skip-git-repo-check ' &&
     ! printf '%s' "$second_call" | grep -q -- '--sandbox' &&
     ! printf '%s' "$second_call" | grep -q -- ' -C '; then
    pass "$desc"
  else
    fail "$desc" "output:
$out
first call:
$first_call
second call:
$second_call"
  fi
}

write_fake_claude_success() {
  local bin_dir="$1"
  cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-p" ] && [ "${2:-}" = "/usage" ]; then
  printf '%s\n' 'Current session: 0% used'
  printf '%s\n' 'Current week (all models): 0% used'
  exit 0
fi
prompt=$(cat)
if [ -z "$prompt" ]; then
  printf '%s\n' '{"result":"no prompt arrived on stdin","session_id":"fake-claude-session","is_error":true}'
  exit 1
fi
printf '%s\n' '{"result":"done\n\n[[TASK_COMPLETE]]","session_id":"fake-claude-session","is_error":false}'
exit 0
EOF
  chmod +x "$bin_dir/claude"
}

run_duplicate_name_test() {
  local desc="duplicate task names create distinct indexed state files"
  local root="$TMP_ROOT/duplicate-names"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local status_dir="$root/.ai-runner-queue/status"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_success "$bin_dir"

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 1,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0
  },
  "tasks": [
    {
      "name": "same name",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "first"
    },
    {
      "name": "same name",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "second"
    }
  ]
}
EOF

  local out exit_code
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     [ -f "$status_dir/task-01.done" ] &&
     [ -f "$status_dir/task-02.done" ]; then
    pass "$desc"
  else
    fail "$desc" "$out"
  fi
}

write_fake_claude_failure() {
  local bin_dir="$1"
  cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-p" ] && [ "${2:-}" = "/usage" ]; then
  printf '%s\n' 'Current session: 0% used'
  printf '%s\n' 'Current week (all models): 0% used'
  exit 0
fi
cat > /dev/null
printf '%s\n' '{"result":"plain failure","session_id":"fake-claude-session","is_error":true}'
exit 7
EOF
  chmod +x "$bin_dir/claude"
}

run_stdin_prompt_roundtrip_test() {
  local desc="multi-line prompt with quotes round-trips intact via stdin"
  local root="$TMP_ROOT/stdin-roundtrip"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received-prompt.txt"

  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-p" ] && [ "\${2:-}" = "/usage" ]; then
  printf '%s\n' 'Current session: 0% used'
  printf '%s\n' 'Current week (all models): 0% used'
  exit 0
fi
cat > "$received_file"
printf '%s\n' '{"result":"done\n\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'
exit 0
EOF
  chmod +x "$bin_dir/claude"

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 1,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0
  },
  "tasks": [
    {
      "name": "stdin roundtrip",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "line one with \"double quotes\"\nline two\n[[TASK_COMPLETE]] should survive as literal text"
    }
  ]
}
EOF

  local out exit_code
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -ne 0 ] || [ ! -f "$received_file" ]; then
    fail "$desc" "exit=$exit_code
$out"
    return
  fi

  local prompt expected received
  prompt=$(printf 'line one with "double quotes"\nline two\n[[TASK_COMPLETE]] should survive as literal text')
  expected=$(printf '%s\n\nIMPORTANT AUTOMATION INSTRUCTIONS:\n1. When and only when this task is fully complete, end your final response with exactly this as the very last line:\n%s\n2. If and only if you cannot complete this task, end your final response with this as the very last line instead, plus a one-line reason:\n%s <one-line reason>\n' "$prompt" "[[TASK_COMPLETE]]" "[[TASK_BLOCKED]]")
  received=$(cat "$received_file")

  if [ "$received" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc" "expected:
$expected
received:
$received"
  fi
}

run_exit_code_propagation_test() {
  local desc="runner exits non-zero when the queue fails"
  local root="$TMP_ROOT/exit-code"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_failure "$bin_dir"

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 1,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0
  },
  "tasks": [
    {
      "name": "failing task",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "fail"
    }
  ]
}
EOF

  local out exit_code
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 1 ] &&
     printf '%s' "$out" | grep -q 'failed after 0 retries'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

check "valid minimal config validates"           0 "Config OK"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-minimal.json" --validate-only
check "valid full config validates"              0 "Config OK"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-full.json" --validate-only
check "trailing comma rejected with explanation" 2 "not valid JSON"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-trailing-comma.json" --validate-only
check "missing field rejected naming the field"  2 "Task 1.*prompt"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-missing-field.json" --validate-only
check "unknown cli rejected listing allowed"     2 "claude, codex, gemini" -- bash "$SCRIPT" --queue "$CONFIGS/broken-bad-cli.json" --validate-only
check "missing project path rejected"            2 "does not exist"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-missing-path.json" --validate-only
check "missing queue file gives copy hint"       2 "ai-run-queue.example.json" -- bash "$SCRIPT" --queue "$HERE/nope.json" --validate-only
run_dry_run_state_test
run_codex_limit_resume_test
run_duplicate_name_test
run_stdin_prompt_roundtrip_test
run_exit_code_propagation_test

echo
echo "passed: $PASS  failed: $FAIL"
exit "$FAIL"
