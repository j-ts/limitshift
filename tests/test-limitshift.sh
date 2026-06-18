#!/usr/bin/env bash
# Test harness for limitshift.sh. Run from bash/Git Bash: bash tests/test-limitshift.sh
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../limitshift.sh"
CONFIGS="$HERE/fixtures/configs"
PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/limitshift-shell-tests.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT" "$CONFIGS"/limitshift-* "$CONFIGS"/.limitshift-*
  # State folders are now named after the config (no limitshift- prefix), e.g. valid-full/.
  # Remove any directories created next to the fixture configs, keeping the .json files.
  find "$CONFIGS" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
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
  rm -rf "$CONFIGS"/limitshift-* "$CONFIGS"/.limitshift-*
  find "$CONFIGS" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
}

source_runner_functions() {
  local root="$1"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{
  "tasks": [
    { "name": "load funcs", "cli": "claude", "projectPath": "$project_dir", "prompt": "p" }
  ]
}
EOF
  LIMITSHIFT_SOURCE_ONLY=1 source "$SCRIPT" --queue "$queue_path"
}

run_dry_run_state_test() {
  local desc="dry run prints commands without persisting done markers"
  reset_fixture_state

  local out exit_code state_dir
  out=$(bash "$SCRIPT" --queue "$CONFIGS/valid-full.json" --dry-run 2>&1)
  exit_code=$?
  state_dir="$CONFIGS/valid-full"

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

run_total_time_unit_test() {
  local desc="session total time line formats a fixed number of seconds"
  local root="$TMP_ROOT/total-time-unit"
  mkdir -p "$root/project"
  source_runner_functions "$root"

  UI_SESSION_TOTAL_SECONDS=3661
  UI_SESSION_TOTAL_PRINTED=0

  local out
  out=$(ui_print_session_total_time 2>&1)

  if printf '%s' "$out" | grep -q 'Total time: 1 hour 1 minute'; then
    pass "$desc"
  else
    fail "$desc" "$out"
  fi
}

run_total_time_e2e_test() {
  local desc="normal run prints a total time line"
  local root="$TMP_ROOT/total-time-e2e"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_gemini_success "$bin_dir"

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 5,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0
  },
  "tasks": [
    {
      "name": "total time",
      "cli": "gemini",
      "projectPath": "$project_dir",
      "prompt": "do it",
      "model": "m",
      "completionCheck": false
    }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] && printf '%s' "$out" | grep -q 'Total time:'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
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
      "model": "gpt-5.4",
      "effort": "high",
      "extraArgs": ["--sandbox", "workspace-write", "--skip-git-repo-check"],
      "prompt": "finish the work"
    }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    fail "$desc" "$out"
    return
  fi

  local first_call second_call
  first_call="$(sed -n '1p' "$log_file")"
  second_call="$(sed -n '2p' "$log_file")"

  if printf '%s' "$out" | grep -q 'Hit a usage limit on codex' &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     printf '%s' "$first_call" | grep -q -- '--sandbox workspace-write' &&
     ! printf '%s' "$first_call" | grep -q -- ' -C ' &&
     printf '%s' "$second_call" | grep -q '^exec resume thr-limit --json -m gpt-5.4 -c model_reasoning_effort=high --skip-git-repo-check ' &&
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

write_fake_gemini_success() {
  local bin_dir="$1"
  cat > "$bin_dir/gemini" <<'EOF'
#!/usr/bin/env bash
set -u
cat > /dev/null
printf '%s\n' '{"session_id":"g-1","response":"done"}'
exit 0
EOF
  chmod +x "$bin_dir/gemini"
}

run_duplicate_name_test() {
  local desc="duplicate task names create distinct indexed state files"
  local root="$TMP_ROOT/duplicate-names"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local status_dir="$root/queue/status"

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
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
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
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -ne 0 ] || [ ! -f "$received_file" ]; then
    fail "$desc" "exit=$exit_code
$out"
    return
  fi

  local prompt expected received
  prompt=$(printf 'line one with "double quotes"\nline two\n[[TASK_COMPLETE]] should survive as literal text')
  expected=$(printf '%s\n\nIMPORTANT AUTOMATION INSTRUCTIONS:\n1. When and only when this task is fully complete, end your final response with %s as (or at the end of) the very last line:\n%s\n2. If and only if you cannot complete this task, end your final response with this as (or at the end of) the very last line instead, plus a one-line reason:\n%s <one-line reason>\n' "$prompt" "[[TASK_COMPLETE]]" "[[TASK_COMPLETE]]" "[[TASK_BLOCKED]]")
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
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 1 ] &&
     printf '%s' "$out" | grep -q 'failed after 0 retries'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

write_fake_claude_response() {
  # Writes a claude stub that records the stdin prompt and replies with a fixed body.
  local bin_dir="$1" received_file="$2" response_json="$3"
  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-p" ] && [ "\${2:-}" = "/usage" ]; then
  printf '%s\n' 'Current session: 0% used'
  printf '%s\n' 'Current week (all models): 0% used'
  exit 0
fi
cat > "$received_file"
printf '%s\n' '$response_json'
exit 0
EOF
  chmod +x "$bin_dir/claude"
}

run_simple_mode_verbatim_test() {
  local desc="simple mode (completionCheck:false) sends prompt verbatim and completes in one run"
  local root="$TMP_ROOT/simple-mode"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"
  local status_dir="$root/queue/status"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"I did the thing, no marker","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 5,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0,
    "completionCheck": false
  },
  "tasks": [
    {
      "name": "simple verbatim",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "just do this verbatim"
    }
  ]
}
EOF

  local out exit_code received
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  received=$(cat "$received_file" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
     [ -f "$status_dir/task-01.done" ] &&
     [ "$received" = "just do this verbatim" ] &&
     ! printf '%s' "$received" | grep -q 'IMPORTANT AUTOMATION INSTRUCTIONS'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
received=[$received]
$out"
  fi
}

run_simple_mode_override_test() {
  local desc="per-task completionCheck:true override re-enables marker checking"
  local root="$TMP_ROOT/simple-override"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"
  local status_dir="$root/queue/status"

  mkdir -p "$bin_dir" "$project_dir"
  # Reply WITHOUT a marker so completion-check mode would NOT mark done on the first run.
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"ready, no marker here","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": false,
    "maxRunsPerTask": 1,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0,
    "completionCheck": false
  },
  "tasks": [
    {
      "name": "override true",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "do it",
      "completionCheck": true
    }
  ]
}
EOF

  local out exit_code received
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  received=$(cat "$received_file" 2>/dev/null)

  # With completionCheck forced true, the prompt MUST carry the instruction block and the
  # task must NOT be marked done after one no-marker run (it exhausts maxRunsPerTask=1 instead).
  if printf '%s' "$received" | grep -q 'IMPORTANT AUTOMATION INSTRUCTIONS' &&
     [ ! -f "$status_dir/task-01.done" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
received=[$received]
$out"
  fi
}

run_loose_marker_test() {
  local desc="loosened marker detection: OK[[TASK_COMPLETE]] on the last line marks done"
  local root="$TMP_ROOT/loose-marker"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"
  local status_dir="$root/queue/status"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"OK[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 2,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0
  },
  "tasks": [
    {
      "name": "loose marker",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "respond OK then the marker"
    }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     [ -f "$status_dir/task-01.done" ] &&
     printf '%s' "$out" | grep -q 'Task 1 done'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_stall_guard_test() {
  local desc="stall guard fails the task after maxStalls identical no-marker responses"
  local root="$TMP_ROOT/stall-guard"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"
  local status_dir="$root/queue/status"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"I am ready to help. What would you like me to work on?","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 20,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0,
    "maxStalls": 2
  },
  "tasks": [
    {
      "name": "stalling task",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "respond OK only"
    }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 1 ] &&
     printf '%s' "$out" | grep -q 'no progress: agent repeated the same response without a completion marker' &&
     [ -f "$status_dir/task-01.failed" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_clean_output_test() {
  local desc="console shows the agent response text, not raw JSON"
  local root="$TMP_ROOT/clean-output"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"
  local output_file="$root/queue/outputs/task-01-clean-output-output.txt"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"Here is the clean answer\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 2,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0
  },
  "tasks": [
    {
      "name": "clean output",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "answer cleanly"
    }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q -- '✦ response' &&
     printf '%s' "$out" | grep -q 'Here is the clean answer' &&
     ! printf '%s' "$out" | grep -q '"session_id"' &&
     [ -f "$output_file" ] &&
     grep -q '"session_id"' "$output_file"; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_show_raw_test() {
  local desc="--show-raw prints the raw JSON to the console"
  local root="$TMP_ROOT/show-raw"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"answer\n[[TASK_COMPLETE]]","session_id":"s-raw","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 2,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0
  },
  "tasks": [
    {
      "name": "raw output",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "answer"
    }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" --show-raw 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q '"session_id"'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_resume_repeats_prompt_test() {
  local desc="resume prompt repeats the original task (incl. /goal) and the continue sentence"
  local root="$TMP_ROOT/resume-repeats"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_dir="$root/received"
  local status_dir="$root/queue/status"

  mkdir -p "$bin_dir" "$project_dir" "$received_dir"

  # A claude stub that records each run's stdin into a separate, numbered file. The first run
  # answers WITHOUT a marker (forcing a resume); the second run answers WITH the marker (done).
  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-p" ] && [ "\${2:-}" = "/usage" ]; then
  printf '%s\n' 'Current session: 0% used'
  printf '%s\n' 'Current week (all models): 0% used'
  exit 0
fi
count_file="$received_dir/count"
n=0
if [ -f "\$count_file" ]; then n=\$(cat "\$count_file"); fi
n=\$((n + 1))
printf '%s' "\$n" > "\$count_file"
cat > "$received_dir/run-\$n.txt"
if [ "\$n" = "1" ]; then
  printf '%s\n' '{"result":"made some progress, no marker yet","session_id":"resume-sess","is_error":false}'
else
  printf '%s\n' '{"result":"all done\n\n[[TASK_COMPLETE]]","session_id":"resume-sess","is_error":false}'
fi
exit 0
EOF
  chmod +x "$bin_dir/claude"

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 5,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0,
    "maxStalls": 5
  },
  "tasks": [
    {
      "name": "resume repeats",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "/goal ship the widget\nImplement the feature end to end."
    }
  ]
}
EOF

  local out exit_code resume_prompt
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  resume_prompt=$(cat "$received_dir/run-2.txt" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
     [ -f "$status_dir/task-01.done" ] &&
     printf '%s' "$resume_prompt" | grep -q 'Continue the previous task in this same session from where you stopped. Do not restart from scratch.' &&
     printf '%s' "$resume_prompt" | grep -q '/goal ship the widget' &&
     printf '%s' "$resume_prompt" | grep -q 'Implement the feature end to end.'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
resume prompt (run 2):
$resume_prompt
$out"
  fi
}

run_resume_simple_mode_test() {
  local desc="simple-mode resume repeats the original prompt but omits the marker block"
  local root="$TMP_ROOT/resume-simple"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_dir="$root/received"

  mkdir -p "$bin_dir" "$project_dir" "$received_dir"

  # In simple mode the first OK run completes the task, so a resume only happens after a pause.
  # Force run 1 to hit a usage limit so the runner pauses and resumes; the resume run then records
  # its prompt, letting us assert the simple-mode resume prompt. We keep completionCheck:false.
  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-p" ] && [ "\${2:-}" = "/usage" ]; then
  printf '%s\n' 'Current session: 0% used'
  printf '%s\n' 'Current week (all models): 0% used'
  exit 0
fi
count_file="$received_dir/count"
n=0
if [ -f "\$count_file" ]; then n=\$(cat "\$count_file"); fi
n=\$((n + 1))
printf '%s' "\$n" > "\$count_file"
cat > "$received_dir/run-\$n.txt"
if [ "\$n" = "1" ]; then
  printf '%s\n' '{"result":"You have hit your usage limit. Try again in 0s.","session_id":"simple-sess","is_error":true}'
  exit 1
fi
printf '%s\n' '{"result":"finished it","session_id":"simple-sess","is_error":false}'
exit 0
EOF
  chmod +x "$bin_dir/claude"

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 5,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0,
    "completionCheck": false
  },
  "tasks": [
    {
      "name": "simple resume",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "/goal ship it\ndo the simple task"
    }
  ]
}
EOF

  local out exit_code resume_prompt
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  resume_prompt=$(cat "$received_dir/run-2.txt" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$resume_prompt" | grep -q 'Continue the previous task in this same session from where you stopped. Do not restart from scratch.' &&
     printf '%s' "$resume_prompt" | grep -q '/goal ship it' &&
     printf '%s' "$resume_prompt" | grep -q 'do the simple task' &&
     ! printf '%s' "$resume_prompt" | grep -q 'IMPORTANT AUTOMATION INSTRUCTIONS'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
resume prompt (run 2):
$resume_prompt
$out"
  fi
}

write_fake_codex_success() {
  local bin_dir="$1"
  cat > "$bin_dir/codex" <<'EOF'
#!/usr/bin/env bash
set -u
cat > /dev/null
printf '%s\n' '{"type":"thread.started","thread_id":"thr-1"}'
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"did it\n\n[[TASK_COMPLETE]]"}}'
exit 0
EOF
  chmod +x "$bin_dir/codex"
}

run_state_layout_test() {
  local desc="state dir gets _README.txt, runs.csv (with header + a Done row), and slugged output file"
  local root="$TMP_ROOT/state-layout"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"
  local state_dir="$root/queue"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"did it\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 2,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0
  },
  "tasks": [
    {
      "name": "Layout Task",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "do the layout work"
    }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     [ -f "$state_dir/_README.txt" ] &&
     grep -qi 'delete this whole folder' "$state_dir/_README.txt" &&
     [ -f "$state_dir/runs.csv" ] &&
     [ "$(sed -n '1p' "$state_dir/runs.csv")" = "timestamp,task,run,mode,exit,status,cli,model" ] &&
     grep -q ',Done,' "$state_dir/runs.csv" &&
     [ -f "$state_dir/outputs/task-01-Layout-Task-output.txt" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out
--- runs.csv ---
$(cat "$state_dir/runs.csv" 2>/dev/null)
--- outputs ---
$(ls "$state_dir/outputs" 2>/dev/null)"
  fi
}

run_done_marker_format_test() {
  local desc=".done file stores two lines: timestamp then a 64-hex fingerprint"
  local root="$TMP_ROOT/done-format"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"
  local done_file="$root/queue/status/task-01.done"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"did it\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "fp", "cli": "claude", "projectPath": "$project_dir", "prompt": "do it" } ]
}
EOF

  local out exit_code line_count fp_line
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  line_count=$(wc -l < "$done_file" 2>/dev/null | tr -d ' ')
  fp_line=$(sed -n '2p' "$done_file" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
     [ "$line_count" = "2" ] &&
     printf '%s' "$fp_line" | grep -qE '^[0-9a-f]{64}$'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code line_count=$line_count fp=[$fp_line]
$out"
  fi
}

run_stale_done_reruns_test() {
  local desc="changing the prompt invalidates the done marker (task re-runs)"
  local root="$TMP_ROOT/stale-done"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"did it\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "fp", "cli": "claude", "projectPath": "$project_dir", "prompt": "original prompt" } ]
}
EOF

  PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" >/dev/null 2>&1

  # Change the prompt, then re-run.
  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "fp", "cli": "claude", "projectPath": "$project_dir", "prompt": "a completely different prompt" } ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'changed since last run' &&
     ! printf '%s' "$out" | grep -q 'already marked as done'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_unchanged_done_skips_test() {
  local desc="unchanged task keeps skipping when the fingerprint matches"
  local root="$TMP_ROOT/unchanged-done"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"did it\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "fp", "cli": "claude", "projectPath": "$project_dir", "prompt": "unchanged prompt" } ]
}
EOF

  PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" >/dev/null 2>&1

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'already marked as done' &&
     ! printf '%s' "$out" | grep -q 'changed since last run'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_legacy_done_reruns_test() {
  local desc="legacy single-line .done (no fingerprint) re-runs once, then gains a fingerprint"
  local root="$TMP_ROOT/legacy-done"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"
  local done_file="$root/queue/status/task-01.done"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"did it\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "fp", "cli": "claude", "projectPath": "$project_dir", "prompt": "unchanged prompt" } ]
}
EOF

  # Seed a legacy marker: a single timestamp line with no fingerprint (older format).
  mkdir -p "$root/queue/status"
  printf '%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$done_file"

  local out exit_code line_count fp_line
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  line_count=$(wc -l < "$done_file" 2>/dev/null | tr -d ' ')
  fp_line=$(sed -n '2p' "$done_file" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'changed since last run' &&
     ! printf '%s' "$out" | grep -q 'already marked as done' &&
     [ "$line_count" = "2" ] &&
     printf '%s' "$fp_line" | grep -qE '^[0-9a-f]{64}$'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code line_count=$line_count fp=[$fp_line]
$out"
  fi
}

run_cli_change_reruns_test() {
  local desc="changing the cli invalidates the done marker (task re-runs)"
  local root="$TMP_ROOT/cli-change"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local received_file="$root/received.txt"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"did it\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'
  write_fake_codex_success "$bin_dir"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "fp", "cli": "claude", "projectPath": "$project_dir", "prompt": "same prompt" } ]
}
EOF

  PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" >/dev/null 2>&1

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "fp", "cli": "codex", "projectPath": "$project_dir", "prompt": "same prompt", "extraArgs": ["--skip-git-repo-check"] } ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'changed since last run'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_state_naming_test() {
  local desc="state folder is named after the queue file (no limitshift- prefix); old prefixed folders left untouched"
  local root="$TMP_ROOT/state-naming"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  # queue.json -> queue/ (NOT queue/).
  local new_state_dir="$root/queue"
  local old_prefixed_dir="$root/limitshift-queue"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_success "$bin_dir"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "naming task", "cli": "claude", "projectPath": "$project_dir", "prompt": "do it" } ]
}
EOF

  # Forward-only: seed the OLD prefixed folder; the runner must NOT touch or migrate it.
  mkdir -p "$old_prefixed_dir"
  printf '%s' 'leave me alone' > "$old_prefixed_dir/marker.txt"

  local out exit_code gitignore old_marker
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  gitignore=$(cat "$new_state_dir/.gitignore" 2>/dev/null)
  old_marker=$(cat "$old_prefixed_dir/marker.txt" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
      [ -f "$new_state_dir/status/task-01.done" ] &&
      [ "$gitignore" = "*" ] &&
      [ "$old_marker" = "leave me alone" ] &&
      [ ! -f "$old_prefixed_dir/status/task-01.done" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code gitignore=[$gitignore] old_marker=[$old_marker]
$out"
  fi
}

run_handoff_note_test() {
  local desc="CLI rotation — handoff note prepended correctly"
  local root="$TMP_ROOT/handoff"
  mkdir -p "$root/project"
  local queue_path="$root/queue.json"
  cat > "$queue_path" <<EOF
{ "tasks": [ { "name": "t", "cli": "claude", "projectPath": "$root/project", "prompt": "do the thing" } ] }
EOF

  # Source functions
  # shellcheck disable=SC1090
  LIMITSHIFT_SOURCE_ONLY=1 source "$SCRIPT" --queue "$queue_path"
  
  local p
  
  # Completion-check mode
  p=$(build_prompt_with_handoff 0 "true")
  local expected_cc="A previous AI tool started this task and was interrupted (usage limit or failure). Partial work may already exist in the working tree. Before doing anything, inspect both \`git status\` (for new/untracked files) and \`git diff\` (for changes to tracked files) to see what has already been done. Continue from there; do not redo finished work. End your final response with \`[[TASK_COMPLETE]]\` when the task is fully done, or \`[[TASK_BLOCKED]] <reason>\` if it genuinely cannot be completed."
  
  if [[ "$p" != "$expected_cc"* ]]; then
     fail "$desc (CC mode)" "Prompt does not start with expected note.
Got: $p"
     return 1
  fi
  
  if [[ "$p" != *"do the thing"* ]]; then
     fail "$desc (CC mode)" "Prompt missing original prompt text."
     return 1
  fi

  # Simple mode
  p=$(build_prompt_with_handoff 0 "false")
  local expected_simple="A previous AI tool started this task and was interrupted (usage limit or failure). Partial work may already exist in the working tree. Before doing anything, inspect both \`git status\` (for new/untracked files) and \`git diff\` (for changes to tracked files) to see what has already been done. Continue from there; do not redo finished work."
  
  if [[ "$p" != "$expected_simple"* ]]; then
     fail "$desc (Simple mode)" "Prompt does not start with expected note."
     return 1
  fi

  if [[ "$p" == *"[[TASK_COMPLETE]]"* ]]; then
     fail "$desc (Simple mode)" "Marker instruction leaked into simple mode prompt."
     return 1
  fi

  pass "$desc"
}

run_reset_time_test() {
  local desc="CLI rotation — reset time capture"
  local root="$TMP_ROOT/reset-time"
  mkdir -p "$root/project"
  local queue_path="$root/queue.json"
  echo '{ "tasks": [ { "name": "t", "cli": "claude", "projectPath": ".", "prompt": "p" } ] }' > "$queue_path"
  
  # Source functions
  # shellcheck disable=SC1090
  LIMITSHIFT_SOURCE_ONLY=1 source "$SCRIPT" --queue "$queue_path"

  local r now
  now=$(date +%s)

  # Parse "try again in" from error text — works the same for every CLI as of 1.2.x.
  r=$(get_runner_reset_epoch "gemini" "Quota exceeded. Try again in 2h 0m." 30)
  if (( r < now + 7000 )); then
    fail "$desc (parsed from error)" "Expected reset > 2h from now, got $r (now=$now)"
    return 1
  fi

  # Fallback to limitWaitMinutes when the error text has no reset hint.
  r=$(get_runner_reset_epoch "codex" "rate limit, no time here" 30)
  if (( r < now + 1700 || r > now + 1900 )); then
    fail "$desc (limitWaitMinutes fallback)" "Expected reset ~30m (1800s) from now, got $r (now=$now)"
    return 1
  fi

  # Claude uses the same path as every other CLI (the legacy `/usage`-driven branch was removed in 1.2.x).
  r=$(get_runner_reset_epoch "claude" "You've hit your usage limit. Try again in 5s." 30)
  if (( r < now + 3 || r > now + 30 )); then
    fail "$desc (claude reset parsed from error)" "Expected reset ~5s from now, got $r (now=$now)"
    return 1
  fi

  pass "$desc"
  }

  run_runner_selection_test() {
  local desc="CLI rotation â€” runner selection rule"
  local root="$TMP_ROOT/runner-selection"
  mkdir -p "$root/project"
  local queue_path="$root/queue.json"
  echo '{ "tasks": [ { "name": "t", "cli": "claude", "projectPath": ".", "prompt": "p" } ] }' > "$queue_path"
  LIMITSHIFT_SOURCE_ONLY=1 source "$SCRIPT" --queue "$queue_path"

  # select_next_runner <startIndex> <nowEpoch> <statesJson>
  # Returns "Action Index WaitUntil"

  # 1. Picks first runnable (not set aside, not limited), scanning from startIndex
  local states='[{"setAside":true,"limitedUntil":null},{"setAside":false,"limitedUntil":1000},{"setAside":false,"limitedUntil":null}]'
  local r
  r=$(select_next_runner 0 500 "$states")
  if [ "$r" = "Run 2 " ]; then
    pass "$desc (picks first runnable)"
  else
    fail "$desc (picks first runnable)" "Got '$r', wanted 'Run 2 '"
  fi

  # 1b. Wraps around from a non-zero start index to find an earlier runnable runner.
  # start=2 (set aside) -> scan 2,0,1 -> runner0 (null) is first runnable.
  states='[{"setAside":false,"limitedUntil":null},{"setAside":false,"limitedUntil":100000},{"setAside":true,"limitedUntil":null}]'
  r=$(select_next_runner 2 500 "$states")
  if [ "$r" = "Run 0 " ]; then
    pass "$desc (wraps from non-zero start index)"
  else
    fail "$desc (wraps from non-zero start index)" "Got '$r', wanted 'Run 0 '"
  fi

  # 2. Returns Wait with soonest within-24h reset when nothing is runnable
  # now=500. runner0 resets at 800 (in 300s), runner1 at 600 (in 100s).
  states='[{"setAside":false,"limitedUntil":800},{"setAside":false,"limitedUntil":600}]'
  r=$(select_next_runner 0 500 "$states")
  if [ "$r" = "Wait 1 600" ]; then
    pass "$desc (returns wait for soonest)"
  else
    fail "$desc (returns wait for soonest)" "Got '$r', wanted 'Wait 1 600'"
  fi

  # 2b. Skips a >24h runner and waits for a within-24h runner when both are limited.
  # now=500. runner0 resets at 500+90000 (>24h), runner1 at 7700 (in ~2h, <=24h).
  states='[{"setAside":false,"limitedUntil":90500},{"setAside":false,"limitedUntil":7700}]'
  r=$(select_next_runner 0 500 "$states")
  if [ "$r" = "Wait 1 7700" ]; then
    pass "$desc (skips >24h, waits within-24h)"
  else
    fail "$desc (skips >24h, waits within-24h)" "Got '$r', wanted 'Wait 1 7700'"
  fi

  # 3. Returns Fail when every live runner resets > 24h out
  # now=500. runner0 resets at 500 + 86401 = 86901.
  states='[{"setAside":false,"limitedUntil":86901}]'
  r=$(select_next_runner 0 500 "$states")
  if [ "$r" = "Fail  " ]; then
    pass "$desc (fails when resets > 24h)"
  else
    fail "$desc (fails when resets > 24h)" "Got '$r', wanted 'Fail  '"
  fi

  # 4. Returns Fail when all are set aside
  states='[{"setAside":true,"limitedUntil":null},{"setAside":true,"limitedUntil":null}]'
  r=$(select_next_runner 0 500 "$states")
  if [ "$r" = "Fail  " ]; then
    pass "$desc (fails when all set aside)"
  else
    fail "$desc (fails when all set aside)" "Got '$r', wanted 'Fail  '"
  fi
  }

  run_legacy_queue_fallback_test() {
  local desc="legacy ai-run-queue.json is used (with a warning) when no new-name queue and no --queue"
  local root="$TMP_ROOT/legacy-queue-fallback"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  # Default-queue resolution keys off the SCRIPT dir, so run a COPY of the runner from a temp dir
  # that contains ONLY ai-run-queue.json (no limitshift-queue.json) and pass no --queue.
  local script_copy="$root/limitshift.sh"
  local legacy_queue="$root/ai-run-queue.json"

  mkdir -p "$bin_dir" "$project_dir"
  cp "$SCRIPT" "$script_copy"
  write_fake_claude_success "$bin_dir"

  cat > "$legacy_queue" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "legacy queue task", "cli": "claude", "projectPath": "$project_dir", "prompt": "do it" } ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$script_copy" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Using legacy queue filename ai-run-queue.json' &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     [ -f "$root/ai-run-queue/status/task-01.done" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

# Task 6: model may be a non-empty array of strings. Reject an empty array / non-string element.
run_model_empty_array_rejected_test() {
  local desc="empty model array is rejected naming the task"
  local root="$TMP_ROOT/model-empty"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{
  "tasks": [ { "name": "g", "cli": "gemini", "projectPath": "$project_dir", "prompt": "p", "model": [] } ]
}
EOF
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1)
  exit_code=$?
  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qiE 'Task 1.*model'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_model_non_string_rejected_test() {
  local desc="non-string element in model array is rejected naming the task"
  local root="$TMP_ROOT/model-nonstring"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{
  "tasks": [ { "name": "g", "cli": "gemini", "projectPath": "$project_dir", "prompt": "p", "model": ["ok", 5] } ]
}
EOF
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1)
  exit_code=$?
  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qiE 'Task 1.*model'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

# Task 6b: per-CLI effort rules enforced at config validation. Each helper writes a one-task queue
# with the given cli/effort/model and asserts validate-only exits 2 with a task-numbered message.
write_effort_queue() {
  # write_effort_queue <queue_path> <project_dir> <cli> <effort-json> [model-json]
  local queue_path="$1" project_dir="$2" cli="$3" effort="$4" model="${5:-}"
  local model_line=""
  if [ -n "$model" ]; then
    model_line="\"model\": $model,"
  fi
  cat > "$queue_path" <<EOF
{
  "tasks": [ { "name": "t", "cli": "$cli", "projectPath": "$project_dir", $model_line "effort": $effort, "prompt": "p" } ]
}
EOF
}

run_effort_gemini_rejected_test() {
  local desc="effort on gemini is rejected naming the task"
  local root="$TMP_ROOT/effort-gemini"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "gemini" '"high"'
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qE 'Task 1: gemini has no effort flag'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_effort_gemini_null_ok_test() {
  local desc="gemini with effort null validates"
  local root="$TMP_ROOT/effort-gemini-null"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "gemini" 'null'
  check "$desc" 0 "Config OK" -- bash "$SCRIPT" --queue "$queue_path" --validate-only
}

run_effort_agy_rejected_test() {
  local desc="effort on agy is rejected naming the task"
  local root="$TMP_ROOT/effort-agy"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "agy" '"high"'
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qE 'Task 1: agy .Antigravity CLI. has no --effort flag'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_effort_agy_null_ok_test() {
  local desc="agy with effort null validates"
  local root="$TMP_ROOT/effort-agy-null"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  local bin_dir="$root/bin"
  mkdir -p "$project_dir" "$bin_dir"
  # agy is not installed on most CI PATHs, and --validate-only checks the binary; provide a stub.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/agy"; chmod +x "$bin_dir/agy"
  write_effort_queue "$queue_path" "$project_dir" "agy" 'null'
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 0 ] && printf '%s' "$out" | grep -qE 'Config OK'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

# A fake agy that takes the prompt from the -p VALUE (agy does not read stdin), records each run's
# flags + stdin length, and replies on stdout with the completion marker.
write_fake_agy() {
  local bin_dir="$1" log_file="$2"
  cat > "$bin_dir/agy" <<EOF
#!/usr/bin/env bash
set -u
prompt=""; cont=0; model=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -c) cont=1; shift ;;
    -p) prompt="\$2"; shift 2 ;;
    --model) model="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
sin=\$(cat)
{
  printf 'RUN cont=%s model=%s stdin_len=%s\n' "\$cont" "\$model" "\${#sin}"
  printf 'PROMPT1=%s\n' "\$(printf '%s' "\$prompt" | head -1)"
} >> "$log_file"
printf '%s\n' 'Antigravity did the work.'
printf '%s\n' 'OK [[TASK_COMPLETE]]'
exit 0
EOF
  chmod +x "$bin_dir/agy"
}

run_agy_prompt_as_arg_test() {
  local desc="agy receives the prompt as the -p value (not stdin), model passes, task completes"
  local root="$TMP_ROOT/agy-arg"; local bin_dir="$root/bin"; local project_dir="$root/project"
  local queue_path="$root/queue.json"; local log_file="$root/agy.log"
  mkdir -p "$bin_dir" "$project_dir"
  write_fake_agy "$bin_dir" "$log_file"
  cat > "$queue_path" <<EOF
{ "tasks": [ {
  "name": "agy task",
  "cli": "agy",
  "projectPath": "$project_dir",
  "model": "gemini-3.1-pro",
  "prompt": "Write hello to a file.",
  "extraArgs": ["--dangerously-skip-permissions"]
} ] }
EOF
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1); exit_code=$?
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     printf '%s' "$out" | grep -q 'Antigravity did the work.' &&
     grep -q 'cont=0 model=gemini-3.1-pro stdin_len=0' "$log_file" &&
     grep -q 'PROMPT1=Write hello to a file.' "$log_file"; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
--- console ---
$out
--- agy.log ---
$(cat "$log_file" 2>/dev/null)"
  fi
}

# A fake agy whose first run (no -c) returns NO marker (forcing a resume), and whose second run
# (with -c) returns the completion marker. Lets us assert that resume adds -c.
write_fake_agy_tworun() {
  local bin_dir="$1" log_file="$2"
  cat > "$bin_dir/agy" <<EOF
#!/usr/bin/env bash
set -u
cont=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -c) cont=1; shift ;;
    -p) shift 2 ;;
    --model) shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
printf 'RUN cont=%s\n' "\$cont" >> "$log_file"
if [ "\$cont" = "1" ]; then
  printf '%s\n' 'Finished now.'
  printf '%s\n' '[[TASK_COMPLETE]]'
else
  printf '%s\n' 'Still working, no marker yet.'
fi
exit 0
EOF
  chmod +x "$bin_dir/agy"
}

run_agy_resume_continue_test() {
  local desc="agy resume run adds -c (continue) after a no-marker first run"
  local root="$TMP_ROOT/agy-resume"; local bin_dir="$root/bin"; local project_dir="$root/project"
  local queue_path="$root/queue.json"; local log_file="$root/agy.log"
  mkdir -p "$bin_dir" "$project_dir"
  write_fake_agy_tworun "$bin_dir" "$log_file"
  cat > "$queue_path" <<EOF
{ "settings": { "maxRunsPerTask": 4, "maxStalls": 5 },
  "tasks": [ {
    "name": "agy resume",
    "cli": "agy",
    "projectPath": "$project_dir",
    "prompt": "do a multi-step thing",
    "extraArgs": ["--dangerously-skip-permissions"]
} ] }
EOF
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1); exit_code=$?
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     [ "$(grep -c 'RUN cont=0' "$log_file")" = "1" ] &&
     [ "$(grep -c 'RUN cont=1' "$log_file")" = "1" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
--- console ---
$out
--- agy.log ---
$(cat "$log_file" 2>/dev/null)"
  fi
}

run_agy_limit_keyword_not_misread_test() {
  local desc="agy success mentioning a limit keyword (429) is not misread as a usage limit"
  local root="$TMP_ROOT/agy-limitword"; local bin_dir="$root/bin"; local project_dir="$root/project"
  local queue_path="$root/queue.json"; local log_file="$root/agy.log"
  mkdir -p "$bin_dir" "$project_dir"; : > "$log_file"
  # Exit 0, marker present, response text mentions limit keywords. Must complete in ONE run.
  cat > "$bin_dir/agy" <<EOF
#!/usr/bin/env bash
set -u
while [ \$# -gt 0 ]; do case "\$1" in -c) shift ;; -p) shift 2 ;; --model) shift 2 ;; *) shift ;; esac; done
cat >/dev/null
echo run >> "$log_file"
printf '%s\n' 'Implemented retry-on-429 and rate limit handling in client.py.'
printf '%s\n' '[[TASK_COMPLETE]]'
exit 0
EOF
  chmod +x "$bin_dir/agy"
  cat > "$queue_path" <<EOF
{ "settings": { "maxRunsPerTask": 3, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "agy 429", "cli": "agy", "projectPath": "$project_dir", "prompt": "fix retries", "extraArgs": ["--dangerously-skip-permissions"] } ] }
EOF
  local out exit_code runs
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1); exit_code=$?
  runs=$(grep -c '^run$' "$log_file")
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     [ "$runs" = "1" ] &&
     ! printf '%s' "$out" | grep -qi 'Hit a usage limit'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code runs=$runs
$out"
  fi
}

run_agy_transcript_capture_test() {
  local desc="agy reply recovered from the transcript store when stdout is empty"
  local root="$TMP_ROOT/agy-transcript"
  local bin_dir="$root/bin" project_dir="$root/project" data_dir="$root/agydata" queue_path="$root/queue.json"
  mkdir -p "$bin_dir" "$project_dir"
  # Stub agy prints NOTHING to stdout (like real agy under output redirection); instead it writes the
  # conversation store LimitShift reads: last_conversations.json (workspace -> id) and the transcript
  # whose last PLANNER_RESPONSE holds the reply (+ completion marker).
  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
set -u
dd="${LIMITSHIFT_AGY_DATA_DIR:?}"
key="${AGY_STUB_PROJKEY:?}"
cid="testconv1"
mkdir -p "$dd/cache" "$dd/brain/$cid/.system_generated/logs"
printf '{"%s":"%s"}\n' "$key" "$cid" > "$dd/cache/last_conversations.json"
{
  printf '%s\n' '{"type":"USER_INPUT","content":"do it"}'
  printf '%s\n' '{"type":"PLANNER_RESPONSE","content":"Recovered via transcript. [[TASK_COMPLETE]]"}'
} > "$dd/brain/$cid/.system_generated/logs/transcript.jsonl"
exit 0
EOF
  chmod +x "$bin_dir/agy"
  cat > "$queue_path" <<EOF
{ "tasks": [ { "name": "agy tx", "cli": "agy", "projectPath": "$project_dir", "prompt": "do it", "extraArgs": ["--dangerously-skip-permissions"] } ] }
EOF
  local out exit_code
  out=$(LIMITSHIFT_AGY_DATA_DIR="$data_dir" AGY_STUB_PROJKEY="$project_dir" PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1); exit_code=$?
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     printf '%s' "$out" | grep -q 'Recovered via transcript'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
--- console ---
$out
--- store ---
$(cat "$data_dir/cache/last_conversations.json" 2>/dev/null)"
  fi
}

run_effort_claude_ultracode_rejected_test() {
  local desc="claude ultracode is rejected with an interactive-only hint naming the task"
  local root="$TMP_ROOT/effort-ultracode"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "claude" '"ultracode"'
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qF "Task 1: 'ultracode' is only available from the interactive /effort menu"; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_effort_claude_xhigh_ok_test() {
  local desc="claude with effort xhigh validates (passthrough)"
  local root="$TMP_ROOT/effort-xhigh"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "claude" '"xhigh"' '"claude-opus-4-8"'
  check "$desc" 0 "Config OK" -- bash "$SCRIPT" --queue "$queue_path" --validate-only
}

run_effort_claude_outofset_rejected_test() {
  local desc="out-of-set claude effort is rejected listing allowed values"
  local root="$TMP_ROOT/effort-claude-bad"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "claude" '"minimal"'
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qE 'Task 1: claude effort must be one of low, medium, high, xhigh, max'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_effort_claude_haiku_rejected_test() {
  local desc="claude haiku with effort is rejected naming the task"
  local root="$TMP_ROOT/effort-haiku"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "claude" '"high"' '"claude-haiku-4-5"'
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qE 'Task 1: claude model haiku does not support effort'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_effort_claude_haiku_in_list_rejected_test() {
  local desc="claude effort rejected when haiku is one of several models in the list"
  local root="$TMP_ROOT/effort-haiku-list"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "claude" '"high"' '["claude-opus-4-8", "claude-haiku-4-5"]'
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qE 'Task 1: claude model haiku does not support effort'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_model_claude_dot_rejected_test() {
  local desc="claude model with a dot is rejected at validation (claude-opus-4.6)"
  local root="$TMP_ROOT/model-claude-dot"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{ "tasks": [ { "name": "t", "cli": "claude", "model": "claude-opus-4.6", "projectPath": "$project_dir", "prompt": "p" } ] }
EOF
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 2 ] && \
     printf '%s' "$out" | grep -qE 'Task 1: claude model "claude-opus-4\.6" contains a dot' && \
     printf '%s' "$out" | grep -qF 'claude-opus-4-6'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_model_claude_dot_in_list_rejected_test() {
  local desc="claude rejects a dotted model anywhere in the rotation list"
  local root="$TMP_ROOT/model-claude-dot-list"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{ "tasks": [ { "name": "t", "cli": "claude", "model": ["claude-opus-4-6", "claude-sonnet-4.6"], "projectPath": "$project_dir", "prompt": "p" } ] }
EOF
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 2 ] && \
     printf '%s' "$out" | grep -qE 'Task 1: claude model "claude-sonnet-4\.6" contains a dot'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_model_claude_hyphen_ok_test() {
  local desc="claude with a hyphenated model id validates"
  local root="$TMP_ROOT/model-claude-hyphen"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{ "tasks": [ { "name": "t", "cli": "claude", "model": "claude-opus-4-6", "projectPath": "$project_dir", "prompt": "p" } ] }
EOF
  check "$desc" 0 "Config OK" -- bash "$SCRIPT" --queue "$queue_path" --validate-only
}

run_model_claude_alias_ok_test() {
  local desc="claude with a bare alias (opus) validates"
  local root="$TMP_ROOT/model-claude-alias"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{ "tasks": [ { "name": "t", "cli": "claude", "model": "opus", "projectPath": "$project_dir", "prompt": "p" } ] }
EOF
  check "$desc" 0 "Config OK" -- bash "$SCRIPT" --queue "$queue_path" --validate-only
}

run_model_claude_ollama_dot_ok_test() {
  local desc="claude in Ollama mode allows a dotted model (qwen3.5:9b) because it goes to ollama launch --model"
  local root="$TMP_ROOT/model-claude-ollama-dot"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{ "tasks": [ { "name": "t", "cli": "claude", "model": "qwen3.5:9b", "projectPath": "$project_dir", "prompt": "p", "extraArgs": ["--oss", "--local-provider", "ollama"] } ] }
EOF
  check "$desc" 0 "Config OK" -- bash "$SCRIPT" --queue "$queue_path" --validate-only
}

run_effort_claude_haiku_null_ok_test() {
  local desc="claude haiku with effort null validates"
  local root="$TMP_ROOT/effort-haiku-null"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "claude" 'null' '"claude-haiku-4-5"'
  check "$desc" 0 "Config OK" -- bash "$SCRIPT" --queue "$queue_path" --validate-only
}

run_effort_codex_none_rejected_test() {
  local desc="codex effort none is rejected with a plan-mode-only hint naming the task"
  local root="$TMP_ROOT/effort-codex-none"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "codex" '"none"'
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 2 ] && \
     printf '%s' "$out" | grep -qE 'Task 1: codex effort must be one of minimal, low, medium, high, xhigh' && \
     printf '%s' "$out" | grep -qF "'none' is plan-mode only"; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_effort_codex_high_ok_test() {
  local desc="codex with effort high validates"
  local root="$TMP_ROOT/effort-codex-high"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "codex" '"high"'
  check "$desc" 0 "Config OK" -- bash "$SCRIPT" --queue "$queue_path" --validate-only
}

run_effort_empty_string_normalized_test() {
  local desc="empty-string effort is treated as no effort (gemini validates)"
  local root="$TMP_ROOT/effort-empty"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "gemini" '""'
  check "$desc" 0 "Config OK" -- bash "$SCRIPT" --queue "$queue_path" --validate-only
}

run_effort_copilot_rejected_test() {
  local desc="invalid effort on copilot is rejected naming the task"
  local root="$TMP_ROOT/effort-copilot"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "copilot" '"minimal"'
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qE 'Task 1: copilot effort must be one of low, medium, high, xhigh, max'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_effort_copilot_ok_test() {
  local desc="copilot with effort high validates"
  local root="$TMP_ROOT/effort-copilot-high"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  write_effort_queue "$queue_path" "$project_dir" "copilot" '"high"'
  check "$desc" 0 "Config OK" -- bash "$SCRIPT" --queue "$queue_path" --validate-only
}

# A fake copilot that takes the prompt from the -p VALUE, records flags, and replies with JSONL.
write_fake_copilot() {
  local bin_dir="$1" log_file="$2"
  cat > "$bin_dir/copilot" <<EOF
#!/usr/bin/env bash
set -u
prompt=""; sid=""; mode="new"
while [ \$# -gt 0 ]; do
  case "\$1" in
    --name) sid="\$2"; mode="new"; shift 2 ;;
    --resume) sid="\$2"; mode="resume"; shift 2 ;;
    --resume=*) sid="\${1#--resume=}"; mode="resume"; shift ;;
    -p) prompt="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
sin=\$(cat)
{
  printf 'RUN mode=%s sid=%s stdin_len=%s\n' "\$mode" "\$sid" "\${#sin}"
  printf 'PROMPT1=%s\n' "\$(printf '%s' "\$prompt" | head -1)"
} >> "$log_file"
printf '{"type":"assistant.message","content":"Copilot reply.","interactionId":"%s"}\n' "\$sid"
printf '{"type":"assistant.message","content":" [[TASK_COMPLETE]]","interactionId":"%s"}\n' "\$sid"
exit 0
EOF
  chmod +x "$bin_dir/copilot"
}

run_copilot_prompt_as_arg_test() {
  local desc="copilot receives prompt via -p, model/effort pass, JSONL parsed, task completes"
  local root="$TMP_ROOT/copilot-arg"; local bin_dir="$root/bin"; local project_dir="$root/project"
  local queue_path="$root/queue.json"; local log_file="$root/copilot.log"
  mkdir -p "$bin_dir" "$project_dir"
  write_fake_copilot "$bin_dir" "$log_file"
  cat > "$queue_path" <<EOF
{ "tasks": [ {
  "name": "copilot task",
  "cli": "copilot",
  "projectPath": "$project_dir",
  "model": "gpt-4o",
  "effort": "high",
  "prompt": "Hello Copilot",
  "extraArgs": ["--allow-all"]
} ] }
EOF
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1); exit_code=$?
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     printf '%s' "$out" | grep -qF 'Copilot reply. [[TASK_COMPLETE]]' &&
     grep -q 'RUN mode=new sid=.* stdin_len=0' "$log_file" &&
     grep -q 'PROMPT1=Hello Copilot' "$log_file"; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
--- console ---
$out
--- copilot.log ---
$(cat "$log_file" 2>/dev/null)"
  fi
}

run_copilot_limit_detection_test() {
  local desc="copilot limit detection identifies usage limit from JSONL error"
  local root="$TMP_ROOT/copilot-limit"; local bin_dir="$root/bin"; local project_dir="$root/project"
  local queue_path="$root/queue.json"
  mkdir -p "$bin_dir" "$project_dir"
  cat > "$bin_dir/copilot" <<EOF
#!/usr/bin/env bash
printf '{"type":"error","message":"Usage limit reached.","interactionId":"cp-lim"}\n'
exit 1
EOF
  chmod +x "$bin_dir/copilot"
  cat > "$queue_path" <<EOF
{ "settings": { "maxRunsPerTask": 1, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "copilot limit", "cli": "copilot", "projectPath": "$project_dir", "prompt": "p" } ] }
EOF
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1); exit_code=$?
  if printf '%s' "$out" | grep -qi 'Hit a usage limit on copilot'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_copilot_resume_test() {
  local desc="copilot usage-limit resume reuses extracted interactionId via --resume"
  local root="$TMP_ROOT/copilot-resume"; local bin_dir="$root/bin"; local project_dir="$root/project"
  local queue_path="$root/queue.json"; local log_file="$root/copilot.log"; local counter_file="$root/count"
  mkdir -p "$bin_dir" "$project_dir"
  cat > "$bin_dir/copilot" <<EOF
#!/usr/bin/env bash
set -u
prompt=""; sid=""; mode="new"
while [ \$# -gt 0 ]; do
  case "\$1" in
    --name) sid="\$2"; mode="new"; shift 2 ;;
    --resume) sid="\$2"; mode="resume"; shift 2 ;;
    --resume=*) sid="\${1#--resume=}"; mode="resume"; shift ;;
    -p) prompt="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
sin=\$(cat)
{
  printf 'RUN mode=%s sid=%s stdin_len=%s\n' "\$mode" "\$sid" "\${#sin}"
  printf 'PROMPT1=%s\n' "\$(printf '%s' "\$prompt" | head -1)"
} >> "$log_file"
n=0
if [ -f "$counter_file" ]; then n=\$(cat "$counter_file"); fi
n=\$((n + 1))
printf '%s' "\$n" > "$counter_file"
if [ "\$n" = "1" ]; then
  printf '{"type":"error","message":"Usage limit reached.","interactionId":"cp-resume"}\n'
  exit 1
fi
printf '{"type":"assistant.message","content":"resumed ok [[TASK_COMPLETE]]","interactionId":"cp-resume"}\n'
exit 0
EOF
  chmod +x "$bin_dir/copilot"
  cat > "$queue_path" <<EOF
{ "settings": { "stopOnError": true, "maxRunsPerTask": 3, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "copilot resume", "cli": "copilot", "projectPath": "$project_dir", "prompt": "do it", "extraArgs": ["--allow-all"] } ] }
EOF
  local out exit_code first_call second_call
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1); exit_code=$?
  first_call="$(sed -n '1p' "$log_file" 2>/dev/null)"
  second_call="$(sed -n '3p' "$log_file" 2>/dev/null)"
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -qi 'Hit a usage limit on copilot' &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     printf '%s' "$first_call" | grep -q 'RUN mode=new sid=' &&
     printf '%s' "$second_call" | grep -q 'RUN mode=resume sid=cp-resume stdin_len=0'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
--- console ---
$out
--- copilot.log ---
$(cat "$log_file" 2>/dev/null)"
  fi
}

run_unknown_cli_rejected_test() {
  local desc="unknown cli rejected listing allowed"
  local root="$TMP_ROOT/unknown-cli"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{
  "tasks": [
    { "name": "bad", "cli": "unknown-cli", "projectPath": "$project_dir", "prompt": "p" }
  ]
}
EOF
  check "$desc" 2 "claude, codex, gemini, agy, copilot" -- bash "$SCRIPT" --queue "$queue_path" --validate-only
}

# Local-model (Ollama) support.
run_ollama_claude_dryrun_test() {
  local desc="claude local-Ollama task is launched via 'ollama launch claude --model ... --yes -- ...'"
  local root="$TMP_ROOT/ollama-claude"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{
  "tasks": [
    { "name": "Claude local", "cli": "claude", "model": "qwen3.5:9b", "projectPath": "$project_dir", "prompt": "p", "completionCheck": false, "extraArgs": ["--oss", "--local-provider", "ollama"] }
  ]
}
EOF
  local out exit_code cmd
  out=$(bash "$SCRIPT" --queue "$queue_path" --dry-run 2>&1); exit_code=$?
  cmd=$(printf '%s' "$out" | grep '^Command:')
  if [ "$exit_code" -eq 0 ] && \
     printf '%s' "$cmd" | grep -qE '^Command: ollama launch claude --model qwen3\.5:9b --yes -- -p ' && \
     printf '%s' "$cmd" | grep -q -- '--output-format json' && \
     ! printf '%s' "$cmd" | grep -q -- '--oss' && \
     ! printf '%s' "$cmd" | grep -q -- '--local-provider'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_ollama_claude_passthrough_extra_test() {
  local desc="claude local-Ollama task keeps non-ollama extraArgs after the -- and drops the ollama tokens"
  local root="$TMP_ROOT/ollama-claude-extra"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{
  "tasks": [
    { "name": "Claude local", "cli": "claude", "model": "qwen3.5:9b", "projectPath": "$project_dir", "prompt": "p", "completionCheck": false, "extraArgs": ["--oss", "--local-provider", "ollama", "--permission-mode", "acceptEdits"] }
  ]
}
EOF
  local out exit_code cmd tail
  out=$(bash "$SCRIPT" --queue "$queue_path" --dry-run 2>&1); exit_code=$?
  cmd=$(printf '%s' "$out" | grep '^Command:')
  # Everything after the ' -- ' separator is what claude itself receives.
  tail=$(printf '%s' "$cmd" | sed 's/^.* -- //')
  if [ "$exit_code" -eq 0 ] && \
     printf '%s' "$tail" | grep -q -- '--permission-mode acceptEdits' && \
     ! printf '%s' "$tail" | grep -q -- '--oss' && \
     ! printf '%s' "$tail" | grep -q -- '--local-provider' && \
     ! printf '%s' "$tail" | grep -q -- '--model'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_ollama_codex_passthrough_test() {
  local desc="codex local-Ollama task passes --oss/--local-provider through unchanged (no ollama launch)"
  local root="$TMP_ROOT/ollama-codex"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{
  "tasks": [
    { "name": "Codex local", "cli": "codex", "model": "nemotron-3-nano:4b", "projectPath": "$project_dir", "prompt": "p", "completionCheck": false, "extraArgs": ["--oss", "--local-provider", "ollama"] }
  ]
}
EOF
  local out exit_code cmd
  out=$(bash "$SCRIPT" --queue "$queue_path" --dry-run 2>&1); exit_code=$?
  cmd=$(printf '%s' "$out" | grep '^Command:')
  if [ "$exit_code" -eq 0 ] && \
     printf '%s' "$cmd" | grep -qE '^Command: codex exec --json -m nemotron-3-nano:4b ' && \
     printf '%s' "$cmd" | grep -q -- '--oss --local-provider ollama' && \
     ! printf '%s' "$cmd" | grep -q -- 'ollama launch'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_ollama_claude_no_model_rejected_test() {
  local desc="local-Ollama claude task without a model is rejected at validation"
  local root="$TMP_ROOT/ollama-nomodel"; local project_dir="$root/project"; local queue_path="$root/queue.json"
  mkdir -p "$project_dir"
  cat > "$queue_path" <<EOF
{
  "tasks": [
    { "name": "Claude local", "cli": "claude", "projectPath": "$project_dir", "prompt": "p", "completionCheck": false, "extraArgs": ["--oss", "--local-provider", "ollama"] }
  ]
}
EOF
  local out exit_code
  out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qF 'a local Ollama claude task needs a model'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

write_rotation_gemini() {
  # A gemini stub that logs the -m model on each run. Runs whose model is in $1 (space-separated
  # list, e.g. "m-first") return a quota limit; all others succeed with the completion marker.
  local bin_dir="$1" model_log="$2" limit_models="$3"
  cat > "$bin_dir/gemini" <<EOF
#!/usr/bin/env bash
cat > /dev/null
model=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-m" ]; then model="\$a"; fi
  prev="\$a"
done
printf '%s\n' "\$model" >> "$model_log"
for lm in $limit_models; do
  if [ "\$model" = "\$lm" ]; then
    printf '%s\n' '{"session_id":"g-1","error":{"message":"Quota exceeded. Try again in 0s.","code":"429"}}'
    exit 1
  fi
done
printf '%s\n' '{"session_id":"g-1","response":"done\n\n[[TASK_COMPLETE]]"}'
exit 0
EOF
  chmod +x "$bin_dir/gemini"
}

run_model_rotation_switch_test() {
  local desc="model rotation: limit on first model switches to the next immediately, no wait"
  local root="$TMP_ROOT/rotate-switch"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local model_log="$root/models.txt"
  local idx_file="$root/queue/sessions/task-01-model-index.txt"

  mkdir -p "$bin_dir" "$project_dir"
  write_rotation_gemini "$bin_dir" "$model_log" "m-first"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "rotate", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it", "model": ["m-first", "m-second"] } ]
}
EOF

  local out exit_code first second saved_idx
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  first=$(sed -n '1p' "$model_log" 2>/dev/null)
  second=$(sed -n '2p' "$model_log" 2>/dev/null)
  saved_idx=$(cat "$idx_file" 2>/dev/null | tr -d ' \r\n')

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'switching to m-second' &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     [ "$first" = "m-first" ] &&
     [ "$second" = "m-second" ] &&
     [ "$saved_idx" = "1" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code first=[$first] second=[$second] idx=[$saved_idx]
$out"
  fi
}

run_model_rotation_exhaust_test() {
  local desc="model rotation: after the last model limits, wait then restart from model #1"
  local root="$TMP_ROOT/rotate-exhaust"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local model_log="$root/models.txt"

  mkdir -p "$bin_dir" "$project_dir"
  # Both models limit on the first pass; on the second pass (after the wait) model #1 succeeds.
  cat > "$bin_dir/gemini" <<EOF
#!/usr/bin/env bash
cat > /dev/null
model=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-m" ]; then model="\$a"; fi
  prev="\$a"
done
printf '%s\n' "\$model" >> "$model_log"
count_file="$root/counter"
n=0
if [ -f "\$count_file" ]; then n=\$(cat "\$count_file"); fi
n=\$((n + 1))
printf '%s' "\$n" > "\$count_file"
if [ "\$n" -le 2 ]; then
  printf '%s\n' '{"session_id":"g-1","error":{"message":"Quota exceeded. Try again in 0s.","code":"429"}}'
  exit 1
fi
printf '%s\n' '{"session_id":"g-1","response":"done\n\n[[TASK_COMPLETE]]"}'
exit 0
EOF
  chmod +x "$bin_dir/gemini"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "rotate-exhaust", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it", "model": ["m-first", "m-second"] } ]
}
EOF

  local out exit_code m1 m2 m3
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  m1=$(sed -n '1p' "$model_log" 2>/dev/null)
  m2=$(sed -n '2p' "$model_log" 2>/dev/null)
  m3=$(sed -n '3p' "$model_log" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Hit a usage limit' &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     [ "$m1" = "m-first" ] && [ "$m2" = "m-second" ] && [ "$m3" = "m-first" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code m1=[$m1] m2=[$m2] m3=[$m3]
$out"
  fi
}

run_model_single_string_test() {
  local desc="single-string model: limit -> wait -> resume same model (no rotation)"
  local root="$TMP_ROOT/single-model"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local model_log="$root/models.txt"

  mkdir -p "$bin_dir" "$project_dir"
  cat > "$bin_dir/gemini" <<EOF
#!/usr/bin/env bash
cat > /dev/null
model=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-m" ]; then model="\$a"; fi
  prev="\$a"
done
printf '%s\n' "\$model" >> "$model_log"
count_file="$root/counter"
n=0
if [ -f "\$count_file" ]; then n=\$(cat "\$count_file"); fi
n=\$((n + 1))
printf '%s' "\$n" > "\$count_file"
if [ "\$n" -eq 1 ]; then
  printf '%s\n' '{"session_id":"g-1","error":{"message":"Quota exceeded. Try again in 0s.","code":"429"}}'
  exit 1
fi
printf '%s\n' '{"session_id":"g-1","response":"done\n\n[[TASK_COMPLETE]]"}'
exit 0
EOF
  chmod +x "$bin_dir/gemini"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "single", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it", "model": "only-model" } ]
}
EOF

  local out exit_code m1 m2
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  m1=$(sed -n '1p' "$model_log" 2>/dev/null)
  m2=$(sed -n '2p' "$model_log" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Hit a usage limit' &&
     ! printf '%s' "$out" | grep -q 'switching to' &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     [ "$m1" = "only-model" ] && [ "$m2" = "only-model" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code m1=[$m1] m2=[$m2]
$out"
  fi
}

run_levenshtein_test() {
  local desc="levenshtein distance helper returns correct distances"
  local root="$TMP_ROOT/levenshtein"
  mkdir -p "$root"
  source_runner_functions "$root"

  local ok=1
  [ "$(_levenshtein "gpt-5" "gpt-5")" = "0" ]   || { echo "same string should be 0"; ok=0; }
  [ "$(_levenshtein "got-5" "gpt-5")" = "1" ]    || { echo "one substitution should be 1"; ok=0; }
  [ "$(_levenshtein "" "abc")" = "3" ]            || { echo "empty vs abc should be 3"; ok=0; }
  [ "$(_levenshtein "abc" "")" = "3" ]            || { echo "abc vs empty should be 3"; ok=0; }

  if [ "$ok" -eq 1 ]; then pass "$desc"; else fail "$desc"; fi
}

run_capability_discovery_test() {
  local desc="capability discovery: agy with model-list command returns supportsModelDiscovery true"
  local root="$TMP_ROOT/cap-discovery"
  local bin_dir="$root/bin"
  local caps_dir="$root/caps"
  mkdir -p "$bin_dir" "$caps_dir"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then
  printf 'gemini-3.1-pro\ngemini-3.5-flash\nclaude-sonnet\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$bin_dir/agy"

  source_runner_functions "$root"

  local caps; caps=$(PATH="$bin_dir:$PATH" discover_cli_models "agy")
  local supports; supports=$(printf '%s' "$caps" | jq -r '.supportsModelDiscovery')
  local model_count; model_count=$(printf '%s' "$caps" | jq '.models | length')

  if [ "$supports" = "true" ] && [ "$model_count" -eq 3 ]; then
    pass "$desc"
  else
    fail "$desc" "supports=$supports model_count=$model_count caps=$caps"
  fi
}

run_capability_cache_test() {
  local desc="capability cache: write then read back within TTL returns cached data"
  local root="$TMP_ROOT/cap-cache"
  local caps_dir="$root/caps"
  mkdir -p "$caps_dir"

  source_runner_functions "$root"

  local ts; ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  local caps_json; caps_json=$(jq -n --arg ts "$ts" \
    '{cli:"agy",supportsModelDiscovery:true,models:["m-1","m-2"],source:"agy models",discoveredAt:$ts,error:""}')

  save_capability_cache "agy" "$caps_dir" "$caps_json"
  local loaded; loaded=$(load_capability_cache "agy" "$caps_dir" 24)
  local loaded_count; loaded_count=$(printf '%s' "$loaded" | jq '.models | length')

  if [ "$loaded_count" = "2" ]; then
    pass "$desc"
  else
    fail "$desc" "loaded_count=$loaded_count loaded=$loaded"
  fi
}

run_capability_cache_stale_test() {
  local desc="capability cache: stale cache (0h TTL) is ignored"
  local root="$TMP_ROOT/cap-stale"
  local caps_dir="$root/caps"
  mkdir -p "$caps_dir"

  source_runner_functions "$root"

  local ts; ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  local caps_json; caps_json=$(jq -n --arg ts "$ts" \
    '{cli:"agy",supportsModelDiscovery:true,models:["m-1"],source:"agy models",discoveredAt:$ts,error:""}')

  save_capability_cache "agy" "$caps_dir" "$caps_json"
  local loaded; loaded=$(load_capability_cache "agy" "$caps_dir" 0)

  if [ -z "$loaded" ]; then
    pass "$desc"
  else
    fail "$desc" "expected empty (stale) but got: $loaded"
  fi
}

run_model_validation_strict_test() {
  local desc="model validation: strict mode fails when discovered model is absent"
  local root="$TMP_ROOT/model-strict"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then printf 'real-model-1\nreal-model-2\n'; exit 0; fi
exit 1
EOF
  chmod +x "$bin_dir/agy"

  cat > "$queue_path" <<EOF
{
  "settings": { "modelValidation": "strictWhenDiscoverable" },
  "tasks": [ {
    "name": "t",
    "cli": "agy",
    "projectPath": "$project_dir",
    "model": "typo-model",
    "prompt": "p",
    "extraArgs": ["--dangerously-skip-permissions"]
  } ]
}
EOF
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?

  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qi 'not available'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_model_validation_suggestion_test() {
  local desc="model validation: typo suggestion appears in strict-mode error"
  local root="$TMP_ROOT/model-suggest"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then printf 'gpt-5.4\ngpt-5.5\n'; exit 0; fi
exit 1
EOF
  chmod +x "$bin_dir/agy"

  cat > "$queue_path" <<EOF
{
  "tasks": [ {
    "name": "t", "cli": "agy", "projectPath": "$project_dir",
    "model": "gpt-5", "prompt": "p",
    "extraArgs": ["--dangerously-skip-permissions"]
  } ]
}
EOF
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?

  if printf '%s' "$out" | grep -q 'did you mean'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_model_validation_warn_test() {
  local desc="model validation: warn mode continues despite unknown model"
  local root="$TMP_ROOT/model-warn"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then printf 'known-model\n'; exit 0; fi
exit 1
EOF
  chmod +x "$bin_dir/agy"

  cat > "$queue_path" <<EOF
{
  "settings": { "modelValidation": "warn" },
  "tasks": [ {
    "name": "t", "cli": "agy", "projectPath": "$project_dir",
    "model": "unknown-model", "prompt": "p",
    "extraArgs": ["--dangerously-skip-permissions"]
  } ]
}
EOF
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?

  if [ "$exit_code" -eq 0 ] && printf '%s' "$out" | grep -qi 'warning' && printf '%s' "$out" | grep -q 'Config OK'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_model_validation_off_test() {
  local desc="model validation: off mode skips model checks entirely"
  local root="$TMP_ROOT/model-off"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then printf 'known-model\n'; exit 0; fi
exit 1
EOF
  chmod +x "$bin_dir/agy"

  cat > "$queue_path" <<EOF
{
  "settings": { "modelValidation": "off" },
  "tasks": [ {
    "name": "t", "cli": "agy", "projectPath": "$project_dir",
    "model": "anything-goes", "prompt": "p",
    "extraArgs": ["--dangerously-skip-permissions"]
  } ]
}
EOF
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?

  if [ "$exit_code" -eq 0 ] && printf '%s' "$out" | grep -q 'Config OK'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_model_validation_undiscoverable_test() {
  local desc="model validation: undiscoverable CLI prints INFO and does not fail"
  local root="$TMP_ROOT/model-nodisc"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local bin_dir="$root/bin"
  mkdir -p "$project_dir" "$bin_dir"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/claude"; chmod +x "$bin_dir/claude"

  cat > "$queue_path" <<EOF
{
  "tasks": [ {
    "name": "t", "cli": "claude", "projectPath": "$project_dir",
    "model": "claude-opus-4-8", "prompt": "p",
    "extraArgs": ["--permission-mode", "acceptEdits"]
  } ]
}
EOF
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?

  if [ "$exit_code" -eq 0 ] && printf '%s' "$out" | grep -qi 'INFO' && printf '%s' "$out" | grep -q 'Config OK'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_refresh_capabilities_test() {
  local desc="--refresh-capabilities ignores stale cache and re-discovers"
  local root="$TMP_ROOT/refresh-caps"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local caps_dir="$root/queue/capabilities"
  mkdir -p "$bin_dir" "$project_dir" "$caps_dir"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then printf 'fresh-model\n'; exit 0; fi
exit 1
EOF
  chmod +x "$bin_dir/agy"

  printf '%s\n' '{"cli":"agy","supportsModelDiscovery":true,"models":["stale-model"],"source":"agy models","discoveredAt":"2000-01-01T00:00:00Z","error":""}' \
    > "$caps_dir/agy.json"

  cat > "$queue_path" <<EOF
{
  "tasks": [ {
    "name": "t", "cli": "agy", "projectPath": "$project_dir",
    "model": "fresh-model", "prompt": "p",
    "extraArgs": ["--dangerously-skip-permissions"]
  } ]
}
EOF
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" --validate-only --refresh-capabilities 2>&1); exit_code=$?

  if [ "$exit_code" -eq 0 ] && printf '%s' "$out" | grep -q 'Config OK'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_probe_models_optin_test() {
  local desc="probe models is opt-in and not triggered by normal --validate-only"
  local root="$TMP_ROOT/probe-optin"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local probe_log="$root/probe-log.txt"
  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-p" ] && [ "\${2:-}" = "/usage" ]; then
  printf 'Current session: 0%% used\nCurrent week (all models): 0%% used\n'; exit 0
fi
printf 'PROBE_RAN' >> "$probe_log"
printf '{"result":"OK","session_id":"s1","is_error":false}'; exit 0
EOF
  chmod +x "$bin_dir/claude"

  cat > "$queue_path" <<EOF
{
  "tasks": [ {
    "name": "t", "cli": "claude", "projectPath": "$project_dir",
    "prompt": "p", "extraArgs": ["--permission-mode", "acceptEdits"]
  } ]
}
EOF
  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?

  if [ "$exit_code" -eq 0 ] && [ ! -f "$probe_log" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code probe_ran=$(cat "$probe_log" 2>/dev/null)
$out"
  fi
}

run_queue_path_filename_resolves_from_script_dir_test() {
  local desc="bare filename with --queue-path resolves from the script's directory"
  local root="$TMP_ROOT/queue-path-filename"
  local project_dir="$root/project"
  # Copy the runner to a temp dir so its SCRIPT_DIR is $root, then place a queue next to it.
  local script_copy="$root/limitshift.sh"
  local queue_name="myproject-queue.json"

  mkdir -p "$root/bin" "$project_dir"
  cp "$SCRIPT" "$script_copy"
  write_fake_claude_success "$root/bin"

  cat > "$root/$queue_name" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 1, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "bare filename task", "cli": "claude", "projectPath": "$project_dir", "prompt": "do it" } ]
}
EOF

  local out exit_code state_dir
  out=$(PATH="$root/bin:$PATH" bash "$script_copy" --queue-path "$queue_name" 2>&1)
  exit_code=$?
  state_dir="$root/myproject-queue"

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     [ -f "$state_dir/status/task-01.done" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code state_dir=$state_dir
$out"
  fi
}

run_queue_path_absolute_test() {
  local desc="absolute path with --queue-path works regardless of cwd"
  local root="$TMP_ROOT/queue-path-absolute"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/abs-queue.json"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_success "$bin_dir"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 1, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "absolute path task", "cli": "claude", "projectPath": "$project_dir", "prompt": "do it" } ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue-path "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] && printf '%s' "$out" | grep -q 'Task 1 done'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_queue_separate_state_dirs_test() {
  local desc="two different queue files produce separate state folders named after each queue"
  local root="$TMP_ROOT/separate-state-dirs"
  local bin_dir="$root/bin"
  local project_dir="$root/project"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_success "$bin_dir"

  local make_queue
  make_queue() {
    local path="$1" task_name="$2"
    cat > "$path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 1, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "$task_name", "cli": "claude", "projectPath": "$project_dir", "prompt": "do it" } ]
}
EOF
  }

  make_queue "$root/alpha-queue.json" "alpha task"
  make_queue "$root/beta-queue.json" "beta task"

  PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue-path "$root/alpha-queue.json" >/dev/null 2>&1
  PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue-path "$root/beta-queue.json" >/dev/null 2>&1

  if [ -f "$root/alpha-queue/status/task-01.done" ] &&
     [ -f "$root/beta-queue/status/task-01.done" ]; then
    pass "$desc"
  else
    fail "$desc" "done markers or state dirs missing; found: $(ls -d "$root"/limitshift-* 2>/dev/null | tr '\n' ' ')"
  fi
}

run_queue_lock_stale_pid_proceeds_test() {
  local desc="stale lock file (dead PID) does not block a new run"
  local root="$TMP_ROOT/lock-stale"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local state_dir="$root/queue"
  local lock_path="$state_dir/limitshift.lock"

  mkdir -p "$bin_dir" "$project_dir" "$state_dir"
  write_fake_claude_success "$bin_dir"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 1, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "stale lock task", "cli": "claude", "projectPath": "$project_dir", "prompt": "do it" } ]
}
EOF

  # Write a lock file with a guaranteed-dead PID
  echo "99999999" > "$lock_path"

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue-path "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] && printf '%s' "$out" | grep -q 'Task 1 done'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_queue_lock_live_pid_blocks_test() {
  local desc="lock file with live PID blocks a concurrent run with exit 2"
  local root="$TMP_ROOT/lock-live"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local state_dir="$root/queue"
  local lock_path="$state_dir/limitshift.lock"

  mkdir -p "$bin_dir" "$project_dir" "$state_dir"
  write_fake_claude_success "$bin_dir"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 1, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "lock live task", "cli": "claude", "projectPath": "$project_dir", "prompt": "do it" } ]
}
EOF

  # Write a lock file with a live PID (a background sleep process)
  sleep 5 &
  local mock_pid=$!
  echo "$mock_pid" > "$lock_path"

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue-path "$queue_path" 2>&1)
  exit_code=$?

  kill "$mock_pid" 2>/dev/null || true
  wait "$mock_pid" 2>/dev/null || true

  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -qiE 'already running|Another LimitShift|PID'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code (expected 2)
$out"
  fi
}

run_shipped_examples_validate_test() {
  local repo_root="$HERE/.."
  local root="$TMP_ROOT/shipped-examples"
  local project_dir="$root/project"
  mkdir -p "$project_dir"
  # The advanced example carries a CLI-rotation (fallbacks) task, which requires its projectPath to
  # be a git working tree; init the temp dir so that check passes here.
  git -C "$project_dir" init -q

  local example
  for example in \
    limitshift-queue.example.json \
    limitshift-queue.example-simple.json \
    limitshift-queue.example-advanced.json \
    limitshift-queue.example-workflow.json; do
    local src="$repo_root/$example"
    local dst="$root/$example"
    local desc="shipped example $example passes --validate-only"

    if [ ! -f "$src" ]; then
      fail "$desc" "missing example file: $src"
      continue
    fi
    if ! jq --arg pp "$project_dir" '(.tasks[].projectPath) = $pp' "$src" > "$dst" 2>/dev/null; then
      fail "$desc" "could not rewrite projectPath in $src"
      continue
    fi
    check "$desc" 0 "Config OK" -- bash "$SCRIPT" --queue "$dst" --validate-only
  done
}

check "valid minimal config validates"           0 "Config OK"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-minimal.json" --validate-only
check "valid full config validates"              0 "Config OK"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-full.json" --validate-only
check "--queue-path alias: valid config validates" 0 "Config OK"           -- bash "$SCRIPT" --queue-path "$CONFIGS/valid-minimal.json" --validate-only
check "trailing comma rejected with explanation" 2 "not valid JSON"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-trailing-comma.json" --validate-only
check "missing field rejected naming the field"  2 "Task 1.*prompt"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-missing-field.json" --validate-only
check "missing project path rejected"            2 "does not exist"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-missing-path.json" --validate-only
check "missing queue file gives copy hint"       2 "limitshift-queue.example.json" -- bash "$SCRIPT" --queue "$HERE/nope.json" --validate-only
check "--queue-path: missing file gives copy hint" 2 "limitshift-queue.example.json" -- bash "$SCRIPT" --queue-path "$HERE/nope.json" --validate-only

# Task 2.2: CLI rotation (fallbacks) — parsing
check "fallbacks: valid queue validates"           0 "Config OK"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-fallbacks.json" --validate-only
check "fallbacks: bad cli rejected"                2 "Task 1.*fallback.*claude, codex, gemini, agy, copilot" -- bash "$SCRIPT" --queue "$CONFIGS/broken-fallback-bad-cli.json" --validate-only
check "fallbacks: bad effort rejected"             2 "Task 1.*fallback.*gemini has no effort flag" -- bash "$SCRIPT" --queue "$CONFIGS/broken-fallback-bad-effort.json" --validate-only

run_git_requirement_test() {
  local desc="CLI rotation (fallbacks) — git requirement"
  local root="$TMP_ROOT/git-req"
  local project_dir="$root/project"
  local queue_no_git="$root/queue-no-git.json"
  local queue_with_git="$root/queue-with-git.json"

  mkdir -p "$project_dir"

  # 1. Rejects non-git
  cat > "$queue_no_git" <<EOF
{
  "tasks": [
    { "name": "t", "cli": "claude", "projectPath": "$project_dir", "prompt": "p",
      "fallbacks": [ { "cli": "codex", "model": "gpt-5.5" } ] }
  ]
}
EOF
  check "$desc: rejects non-git" 2 "Task 1.*fallbacks.*not a git repository" -- bash "$SCRIPT" --queue "$queue_no_git" --validate-only

  # 2. Accepts git init
  git -C "$project_dir" init -q
  cat > "$queue_with_git" <<EOF
{
  "tasks": [
    { "name": "t", "cli": "claude", "projectPath": "$project_dir", "prompt": "p",
      "fallbacks": [ { "cli": "codex", "model": "gpt-5.5" } ] }
  ]
}
EOF
  check "$desc: accepts git repo" 0 "Config OK" -- bash "$SCRIPT" --queue "$queue_with_git" --validate-only

  # 3. No-fallbacks unaffected
  local queue_no_fb="$root/queue-no-fb.json"
  local no_git_project="$root/no-git-project"
  mkdir -p "$no_git_project"
  cat > "$queue_no_fb" <<EOF
{
  "tasks": [ { "name": "t", "cli": "claude", "projectPath": "$no_git_project", "prompt": "p" } ]
}
EOF
  check "$desc: no-fallbacks unaffected" 0 "Config OK" -- bash "$SCRIPT" --queue "$queue_no_fb" --validate-only
}

run_total_time_unit_test() {
  local desc="session total time line formats a fixed number of seconds"
  local root="$TMP_ROOT/total-time-unit"
  mkdir -p "$root/project"
  source_runner_functions "$root"

  UI_SESSION_TOTAL_SECONDS=3661
  UI_SESSION_TOTAL_PRINTED=0

  local out
  out=$(ui_print_session_total_time 2>&1)

  if printf '%s' "$out" | grep -q 'Total time: 1 hour 1 minute'; then
    pass "$desc"
  else
    fail "$desc" "$out"
  fi
}

run_total_time_e2e_test() {
  local desc="normal run prints a total time line"
  local root="$TMP_ROOT/total-time-e2e"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_gemini_success "$bin_dir"

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 5,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0
  },
  "tasks": [
    {
      "name": "total time",
      "cli": "gemini",
      "projectPath": "$project_dir",
      "prompt": "do it",
      "model": "m",
      "completionCheck": false
    }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] && printf '%s' "$out" | grep -q 'Total time:'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_banner_details_test() {
  local desc="banner details prints the queue count, CLIs, and a started line with the queue path"
  local root="$TMP_ROOT/banner-details"
  mkdir -p "$root/project"
  source_runner_functions "$root"

  local queue_path="/home/u/pipeline-cli/limitshift-stop-dev.json"
  local out
  # Duplicate CLI (gemini) must collapse to the unique set; started time is passed pre-formatted.
  out=$(ui_banner_details 11 "Tue 22:27" "$queue_path" gemini codex claude gemini 2>&1)

  if printf '%s' "$out" | grep -q '11 tasks queued' &&
     printf '%s' "$out" | grep -q 'gemini, codex, claude' &&
     printf '%s' "$out" | grep -qE 'started [A-Za-z]{3} [0-9]{2}:[0-9]{2}' &&
     printf '%s' "$out" | grep -qF "started Tue 22:27" &&
     printf '%s' "$out" | grep -qF "$queue_path"; then
    pass "$desc"
  else
    fail "$desc" "$out"
  fi
}

run_dry_run_state_test
run_banner_details_test
run_total_time_unit_test
run_total_time_e2e_test
run_codex_limit_resume_test
run_duplicate_name_test
run_stdin_prompt_roundtrip_test
run_exit_code_propagation_test
run_simple_mode_verbatim_test
run_simple_mode_override_test
run_loose_marker_test
run_stall_guard_test
run_clean_output_test
run_show_raw_test
run_resume_repeats_prompt_test
run_resume_simple_mode_test
run_state_layout_test
run_done_marker_format_test
run_stale_done_reruns_test
run_unchanged_done_skips_test
run_legacy_done_reruns_test
run_cli_change_reruns_test
run_state_naming_test
run_legacy_queue_fallback_test
run_model_empty_array_rejected_test
run_model_non_string_rejected_test
run_effort_gemini_rejected_test
run_effort_gemini_null_ok_test
run_effort_agy_rejected_test
run_effort_agy_null_ok_test
run_effort_claude_ultracode_rejected_test
run_effort_claude_xhigh_ok_test
run_effort_claude_outofset_rejected_test
run_effort_claude_haiku_rejected_test
run_effort_claude_haiku_in_list_rejected_test
run_model_claude_dot_rejected_test
run_model_claude_dot_in_list_rejected_test
run_model_claude_hyphen_ok_test
run_model_claude_alias_ok_test
run_model_claude_ollama_dot_ok_test
run_effort_claude_haiku_null_ok_test
run_effort_codex_none_rejected_test
run_effort_codex_high_ok_test
run_effort_empty_string_normalized_test
run_effort_copilot_rejected_test
run_effort_copilot_ok_test
run_ollama_claude_dryrun_test
run_ollama_claude_passthrough_extra_test
run_ollama_codex_passthrough_test
run_ollama_claude_no_model_rejected_test
run_model_rotation_switch_test
run_model_rotation_exhaust_test
run_model_single_string_test
run_agy_prompt_as_arg_test
run_agy_resume_continue_test
run_agy_limit_keyword_not_misread_test
run_agy_transcript_capture_test
run_copilot_prompt_as_arg_test
run_copilot_limit_detection_test
run_copilot_resume_test
run_unknown_cli_rejected_test
run_queue_path_filename_resolves_from_script_dir_test
run_queue_path_absolute_test
run_queue_separate_state_dirs_test
run_queue_lock_stale_pid_proceeds_test
run_queue_lock_live_pid_blocks_test
run_shipped_examples_validate_test
run_levenshtein_test
run_capability_discovery_test
run_capability_cache_test
run_capability_cache_stale_test
run_model_validation_strict_test
run_model_validation_suggestion_test
run_model_validation_warn_test
run_model_validation_off_test
run_model_validation_undiscoverable_test
run_refresh_capabilities_test
run_fingerprint_fallback_test() {
  local desc="fingerprint includes fallbacks but stays back-compat for no-fallbacks"
  local root="$TMP_ROOT/fingerprint-fb"
  local project_dir="$root/project"
  local queue_no_fb="$root/queue-no-fb.json"
  local queue_with_fb="$root/queue-with-fb.json"

  mkdir -p "$project_dir"

  # Task 1: No fallbacks
  cat > "$queue_no_fb" <<EOF
{
  "tasks": [ { "name": "test", "cli": "claude", "projectPath": "$project_dir", "prompt": "X" } ]
}
EOF

  # Task 2: With fallbacks (Task 2.1)
  cat > "$queue_with_fb" <<EOF
{
  "tasks": [
    {
      "name": "test",
      "cli": "claude",
      "projectPath": "$project_dir",
      "prompt": "X",
      "fallbacks": [
        { "cli": "codex", "model": "gpt-4", "effort": "high" }
      ]
    }
  ]
}
EOF

  local fp_no_fb fp_with_fb
  fp_no_fb=$(LIMITSHIFT_SOURCE_ONLY=1 source "$SCRIPT" >/dev/null && export QUEUE_PATH="$queue_no_fb" && get_task_fingerprint 0)
  fp_with_fb=$(LIMITSHIFT_SOURCE_ONLY=1 source "$SCRIPT" >/dev/null && export QUEUE_PATH="$queue_with_fb" && get_task_fingerprint 0)

  if [ "$fp_no_fb" != "$fp_with_fb" ]; then
    pass "$desc"
  else
    fail "$desc" "Fingerprints are identical even though fallbacks differ.
no-fb:   $fp_no_fb
with-fb: $fp_with_fb"
  fi
}

run_fingerprint_backcompat_test() {
  local desc="fingerprint is unchanged when fallbacks are missing or empty (back-compat)"
  local root="$TMP_ROOT/fingerprint-compat"
  local project_dir="$root/project"
  local queue_no_fb="$root/queue-no-fb.json"
  local queue_empty_fb="$root/queue-empty-fb.json"

  mkdir -p "$project_dir"

  cat > "$queue_no_fb" <<EOF
{
  "tasks": [ { "name": "test", "cli": "claude", "projectPath": "$project_dir", "prompt": "X" } ]
}
EOF

  cat > "$queue_empty_fb" <<EOF
{
  "tasks": [ { "name": "test", "cli": "claude", "projectPath": "$project_dir", "prompt": "X", "fallbacks": [] } ]
}
EOF

  local fp_no_fb fp_empty_fb
  fp_no_fb=$(LIMITSHIFT_SOURCE_ONLY=1 source "$SCRIPT" >/dev/null && export QUEUE_PATH="$queue_no_fb" && get_task_fingerprint 0)
  fp_empty_fb=$(LIMITSHIFT_SOURCE_ONLY=1 source "$SCRIPT" >/dev/null && export QUEUE_PATH="$queue_empty_fb" && get_task_fingerprint 0)

  if [ "$fp_no_fb" = "$fp_empty_fb" ]; then
    pass "$desc"
  else
    fail "$desc" "Fingerprint changed for empty fallbacks (breaks back-compat).
no-fb:    $fp_no_fb
empty-fb: $fp_empty_fb"
  fi
}

run_fingerprint_normalized_model_test() {
  local desc="fingerprint is identical for string vs 1-element-array fallback model"
  local root="$TMP_ROOT/fingerprint-norm"
  local project_dir="$root/project"
  local queue_string="$root/queue-string.json"
  local queue_array="$root/queue-array.json"

  mkdir -p "$project_dir"

  cat > "$queue_string" <<EOF
{
  "tasks": [
    { "name": "test", "cli": "claude", "projectPath": "$project_dir", "prompt": "X",
      "fallbacks": [ { "cli": "codex", "model": "gpt-4" } ] }
  ]
}
EOF

  cat > "$queue_array" <<EOF
{
  "tasks": [
    { "name": "test", "cli": "claude", "projectPath": "$project_dir", "prompt": "X",
      "fallbacks": [ { "cli": "codex", "model": ["gpt-4"] } ] }
  ]
}
EOF

  local fp_string fp_array
  fp_string=$(LIMITSHIFT_SOURCE_ONLY=1 source "$SCRIPT" >/dev/null && export QUEUE_PATH="$queue_string" && get_task_fingerprint 0)
  fp_array=$(LIMITSHIFT_SOURCE_ONLY=1 source "$SCRIPT" >/dev/null && export QUEUE_PATH="$queue_array" && get_task_fingerprint 0)

  if [ "$fp_string" = "$fp_array" ]; then
    pass "$desc"
  else
    fail "$desc" "Fingerprint differs for string vs array model.
string: $fp_string
array:  $fp_array"
  fi
}

run_probe_models_optin_test
run_fingerprint_fallback_test
run_fingerprint_backcompat_test
run_fingerprint_normalized_model_test
run_handoff_note_test
run_reset_time_test
run_runner_selection_test
run_git_requirement_test

# CLI rotation end-to-end tests

run_cli_rotation_limit_switch_test() {
  local desc="CLI rotation — switches from gemini to codex on limit, handoff note in prompt"
  local root="$TMP_ROOT/cli-rot-limit-switch"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local stdin_log="$root/codex-stdin.txt"

  mkdir -p "$bin_dir" "$project_dir"
  git -C "$project_dir" init -q

  cat > "$bin_dir/gemini" <<'STUBEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"session_id":"g-1","error":{"message":"Quota exceeded. Try again in 1s.","code":"429"}}'
exit 1
STUBEOF
  chmod +x "$bin_dir/gemini"

  cat > "$bin_dir/codex" <<STUBEOF
#!/usr/bin/env bash
cat >> "$stdin_log"
printf '%s\n' '{"type":"thread.started","thread_id":"c-1"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done\\n\\n[[TASK_COMPLETE]]"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
exit 0
STUBEOF
  chmod +x "$bin_dir/codex"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "limit-switch", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it",
      "fallbacks": [ { "cli": "codex", "model": "c-1" } ] }
  ]
}
EOF

  local out exit_code stdin_content
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  stdin_content=""
  if [ -f "$stdin_log" ]; then stdin_content=$(cat "$stdin_log"); fi

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -qi 'switching to codex' &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     printf '%s' "$stdin_content" | grep -q 'A previous AI tool'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
output:
$out
stdin:
$stdin_content"
  fi
}

run_total_time_unit_test() {
  local desc="session total time line formats a fixed number of seconds"
  local root="$TMP_ROOT/total-time-unit"
  mkdir -p "$root/project"
  source_runner_functions "$root"

  UI_SESSION_TOTAL_SECONDS=3661
  UI_SESSION_TOTAL_PRINTED=0

  local out
  out=$(ui_print_session_total_time 2>&1)

  if printf '%s' "$out" | grep -q 'Total time: 1 hour 1 minute'; then
    pass "$desc"
  else
    fail "$desc" "$out"
  fi
}

run_total_time_e2e_test() {
  local desc="normal run prints a total time line"
  local root="$TMP_ROOT/total-time-e2e"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_gemini_success "$bin_dir"

  cat > "$queue_path" <<EOF
{
  "settings": {
    "stopOnError": true,
    "maxRunsPerTask": 5,
    "maxRetriesOnError": 0,
    "limitWaitMinutes": 1,
    "resetBufferMinutes": 0
  },
  "tasks": [
    {
      "name": "total time",
      "cli": "gemini",
      "projectPath": "$project_dir",
      "prompt": "do it",
      "model": "m",
      "completionCheck": false
    }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] && printf '%s' "$out" | grep -q 'Total time:'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_graceful_stop_after_step_test() {
  local desc="graceful stop: stops after current step, skips task 2, releases lock"
  local root="$TMP_ROOT/graceful-stop"
  local project_dir="$root/project"
  local bin_dir="$root/bin"
  local queue_path="$root/queue.json"
  local call_log="$root/calls.txt"
  local flag="$root/queue/stop-after-step.flag"

  mkdir -p "$project_dir" "$bin_dir"
  git -C "$project_dir" init -q

  cat > "$bin_dir/gemini" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo call >> "$call_log"
mkdir -p "$(dirname "$flag")"
: > "$flag"
printf '%s\n' '{"session_id":"g-1","response":"done\n\n[[TASK_COMPLETE]]"}'
EOF
  chmod +x "$bin_dir/gemini"

  cat > "$queue_path" <<EOF
{ "settings": { "completionCheck": false },
  "tasks": [
    { "name":"t1","cli":"gemini","projectPath":"$project_dir","prompt":"p1","model":"m" },
    { "name":"t2","cli":"gemini","projectPath":"$project_dir","prompt":"p2","model":"m" } ] }
EOF

  local out exit_code call_count
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  call_count=0
  [ -f "$call_log" ] && call_count=$(grep -c '^call$' "$call_log" 2>/dev/null || true)

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Stopping after the current step' &&
     printf '%s' "$out" | grep -q 'Stopped early - 1 of 2 ran (1 not reached). Rerun the same command to continue.' &&
     [ "$call_count" = "1" ] &&
     ! printf '%s' "$out" | grep -q 'Task 2/2' &&
     [ ! -f "$root/queue/limitshift.lock" ] &&
     [ ! -f "$flag" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code call_count=$call_count lock=$([ -f "$root/queue/limitshift.lock" ] && echo yes || echo no) flag=$([ -f "$flag" ] && echo yes || echo no)
$out"
  fi
}

run_cli_rotation_error_switch_test() {
  local desc="CLI rotation — switches to next runner after persistent errors (retries exhausted)"
  local root="$TMP_ROOT/cli-rot-err-switch"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local gemini_counter="$root/gemini-count.txt"

  mkdir -p "$bin_dir" "$project_dir"
  git -C "$project_dir" init -q

  cat > "$bin_dir/gemini" <<STUBEOF
#!/usr/bin/env bash
cat > /dev/null
n=0
[ -f "$gemini_counter" ] && n=\$(cat "$gemini_counter")
n=\$((n + 1))
printf '%s' "\$n" > "$gemini_counter"
printf '%s\n' '{"session_id":"g-1","error":{"message":"Internal server error","code":"500"}}'
exit 1
STUBEOF
  chmod +x "$bin_dir/gemini"

  cat > "$bin_dir/codex" <<'STUBEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"type":"thread.started","thread_id":"c-1"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done\n\n[[TASK_COMPLETE]]"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
exit 0
STUBEOF
  chmod +x "$bin_dir/codex"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": false, "maxRunsPerTask": 10, "maxRetriesOnError": 1, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "err-switch", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it",
      "fallbacks": [ { "cli": "codex", "model": "c-1" } ] }
  ]
}
EOF

  local out exit_code gemini_calls
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  gemini_calls=0
  [ -f "$gemini_counter" ] && gemini_calls=$(cat "$gemini_counter")

  if [ "$exit_code" -eq 0 ] &&
     [ "$gemini_calls" -eq 2 ] &&
     printf '%s' "$out" | grep -qi 'switching to codex' &&
     printf '%s' "$out" | grep -q 'Task 1 done'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code gemini_calls=$gemini_calls
$out"
  fi
}

run_cli_rotation_blocked_no_switch_test() {
  local desc="CLI rotation — does NOT switch runners on TASK_BLOCKED; task fails immediately"
  local root="$TMP_ROOT/cli-rot-blocked"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local codex_counter="$root/codex-count.txt"

  mkdir -p "$bin_dir" "$project_dir"
  git -C "$project_dir" init -q

  cat > "$bin_dir/gemini" <<'STUBEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"session_id":"g-1","response":"Cannot complete this.\n\n[[TASK_BLOCKED]] cannot do this"}'
exit 0
STUBEOF
  chmod +x "$bin_dir/gemini"

  cat > "$bin_dir/codex" <<STUBEOF
#!/usr/bin/env bash
cat > /dev/null
n=0
[ -f "$codex_counter" ] && n=\$(cat "$codex_counter")
n=\$((n + 1))
printf '%s' "\$n" > "$codex_counter"
printf '%s\n' '{"type":"thread.started","thread_id":"c-1"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done\n\n[[TASK_COMPLETE]]"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
exit 0
STUBEOF
  chmod +x "$bin_dir/codex"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "blocked-task", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it",
      "completionCheck": true,
      "fallbacks": [ { "cli": "codex", "model": "c-1" } ] }
  ]
}
EOF

  local out exit_code failed_file codex_calls
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  failed_file="$root/queue/status/task-01.failed"
  codex_calls=0
  [ -f "$codex_counter" ] && codex_calls=$(cat "$codex_counter")

  if [ "$exit_code" -eq 1 ] &&
     ! printf '%s' "$out" | grep -qi 'switching to' &&
     [ -f "$failed_file" ] &&
     [ "$codex_calls" -eq 0 ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code failed_file_exists=$([ -f "$failed_file" ] && echo yes || echo no) codex_calls=$codex_calls
$out"
  fi
}

run_cli_rotation_no_fallbacks_backcompat_test() {
  local desc="CLI rotation — no-fallbacks task waits-and-resumes on single-runner limit (back-compat)"
  local root="$TMP_ROOT/cli-rot-backcompat"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local counter="$root/counter.txt"

  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/gemini" <<STUBEOF
#!/usr/bin/env bash
cat > /dev/null
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n + 1))
printf '%s' "\$n" > "$counter"
if [ "\$n" -eq 1 ]; then
  printf '%s\n' '{"session_id":"g-1","error":{"message":"Quota exceeded. Try again in 0s.","code":"429"}}'
  exit 1
fi
printf '%s\n' '{"session_id":"g-1","response":"done\n\n[[TASK_COMPLETE]]"}'
exit 0
STUBEOF
  chmod +x "$bin_dir/gemini"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "backcompat", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it" }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -qi 'Hit a usage limit' &&
     ! printf '%s' "$out" | grep -qi 'switching to' &&
     printf '%s' "$out" | grep -q 'Task 1 done'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_cli_rotation_all_limited_wait_test() {
  local desc="CLI rotation — waits for soonest-reset runner when all are limited"
  local root="$TMP_ROOT/cli-rot-all-limited"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local counter="$root/counter.txt"

  mkdir -p "$bin_dir" "$project_dir"
  git -C "$project_dir" init -q

  cat > "$bin_dir/gemini" <<STUBEOF
#!/usr/bin/env bash
cat > /dev/null
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n + 1))
printf '%s' "\$n" > "$counter"
if [ "\$n" -eq 1 ]; then
  printf '%s\n' '{"session_id":"g-1","error":{"message":"Quota exceeded. Try again in 5s.","code":"429"}}'
  exit 1
fi
printf '%s\n' '{"session_id":"g-1","response":"done\n\n[[TASK_COMPLETE]]"}'
exit 0
STUBEOF
  chmod +x "$bin_dir/gemini"

  cat > "$bin_dir/codex" <<STUBEOF
#!/usr/bin/env bash
cat > /dev/null
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n + 1))
printf '%s' "\$n" > "$counter"
if [ "\$n" -eq 2 ]; then
  printf '%s\n' '{"type":"thread.started","thread_id":"c-1"}'
  printf '%s\n' '{"type":"error","message":"Rate limit exceeded. Try again in 5s."}'
  exit 1
fi
printf '%s\n' '{"type":"thread.started","thread_id":"c-1"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done\n\n[[TASK_COMPLETE]]"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
exit 0
STUBEOF
  chmod +x "$bin_dir/codex"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 10, "maxRetriesOnError": 0, "limitWaitMinutes": 5, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "all-limited", "cli": "gemini", "model": "m-r0", "projectPath": "$project_dir", "prompt": "do it",
      "fallbacks": [ { "cli": "codex", "model": "c-1" } ] }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -qi 'Hit a usage limit' &&
     printf '%s' "$out" | grep -qi 'switching to codex' &&
     printf '%s' "$out" | grep -q 'Task 1 done'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_cli_rotation_claude_reactive_limit_test() {
  local desc="CLI rotation — claude limit signal triggers reactive rotation to the codex fallback"
  local root="$TMP_ROOT/cli-rot-claude-reactive"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"

  mkdir -p "$bin_dir" "$project_dir"
  git -C "$project_dir" init -q

  # 1.2.x: the `/usage` pre-check is gone. Claude is allowed to run, and when it returns a limit
  # signal in its response, the runner rotates to the codex fallback. Reset is parsed from the
  # `try again in 5s` hint in the error text.
  cat > "$bin_dir/claude" <<'STUBEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"result":"You'\''ve hit your usage limit. Try again in 5s.","session_id":"s-1","is_error":true}'
exit 1
STUBEOF
  chmod +x "$bin_dir/claude"

  cat > "$bin_dir/codex" <<'STUBEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"type":"thread.started","thread_id":"c-1"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done\n\n[[TASK_COMPLETE]]"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
exit 0
STUBEOF
  chmod +x "$bin_dir/codex"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "claude-limit-rotate", "cli": "claude", "projectPath": "$project_dir", "prompt": "do it",
      "fallbacks": [ { "cli": "codex", "model": "c-1" } ] }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -qi 'switching to codex' &&
     printf '%s' "$out" | grep -q 'Task 1 done'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_claude_session_lost_recovery_test() {
  local desc="Claude session-lost: drops stale session id, retries as New, does not flag for human"
  local root="$TMP_ROOT/claude-session-lost"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local counter="$root/claude-counter.txt"

  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/claude" <<STUBEOF
#!/usr/bin/env bash
cat > /dev/null
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n + 1))
printf '%s' "\$n" > "$counter"
if [ "\$n" -eq 1 ]; then
  printf '%s\n' '{"result":"started","session_id":"s-stale","is_error":false}'
  exit 0
fi
if [ "\$n" -eq 2 ]; then
  printf '%s\n' '{"result":"No conversation found with session ID: s-stale","session_id":null,"is_error":true}'
  exit 1
fi
printf '%s\n' '{"result":"done\n[[TASK_COMPLETE]]","session_id":"s-fresh","is_error":false}'
exit 0
STUBEOF
  chmod +x "$bin_dir/claude"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 4, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "session-lost", "cli": "claude", "model": "sonnet", "projectPath": "$project_dir", "prompt": "do it", "completionCheck": true }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  local needs_human="$root/queue/status/task-01.needs-human"
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -qi 'no longer in claude' &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     [ ! -f "$needs_human" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code needs_human=$([ -f "$needs_human" ] && echo yes || echo no)
$out"
  fi
}

run_claude_slash_rejected_flags_human_test() {
  local desc="Claude slash-command rejection: flags for a human, single invocation, no retries"
  local root="$TMP_ROOT/claude-slash-rejected"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local calls="$root/claude-calls.txt"

  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/claude" <<STUBEOF
#!/usr/bin/env bash
cat > /dev/null
printf 'ran\n' >> "$calls"
printf '%s\n' '{"result":"Unknown command: /goal, did you mean /goal?","session_id":"s-1","is_error":true}'
exit 1
STUBEOF
  chmod +x "$bin_dir/claude"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": false, "maxRunsPerTask": 5, "maxRetriesOnError": 3, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "slash-rejected", "cli": "claude", "model": "sonnet", "projectPath": "$project_dir", "prompt": "/goal: do it", "completionCheck": true }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  local call_count=0
  [ -f "$calls" ] && call_count=$(wc -l < "$calls" | tr -d ' ')
  local needs_human="$root/queue/status/task-01.needs-human"

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -qi 'needs human review' &&
     printf '%s' "$out" | grep -qi 'slash command' &&
     [ "$call_count" -eq 1 ] &&
     [ -f "$needs_human" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code calls=$call_count needs_human=$([ -f "$needs_human" ] && echo yes || echo no)
$out"
  fi
}

run_cli_rotation_handoff_after_wait_test() {
  local desc="CLI rotation — resuming into a different runner after a wait switches fresh with handoff (spec 6.1/7)"
  local root="$TMP_ROOT/cli-rot-wait-switchback"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local counter="$root/counter.txt"
  local gemini_stdin="$root/gemini-stdin.txt"

  mkdir -p "$bin_dir" "$project_dir"
  git -C "$project_dir" init -q

  # gemini (runner 0): call 1 limits with a reset far enough out that it is still pending when codex
  # also limits (forcing a real wait); later calls log their stdin and succeed.
  cat > "$bin_dir/gemini" <<STUBEOF
#!/usr/bin/env bash
stdin=\$(cat)
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n + 1))
printf '%s' "\$n" > "$counter"
if [ "\$n" -eq 1 ]; then
  printf '%s\n' '{"session_id":"g-1","error":{"message":"Quota exceeded. Try again in 12s.","code":"429"}}'
  exit 1
fi
printf '%s\n' "\$stdin" >> "$gemini_stdin"
printf '%s\n' '{"session_id":"g-1","response":"done\n\n[[TASK_COMPLETE]]"}'
exit 0
STUBEOF
  chmod +x "$bin_dir/gemini"

  # codex (runner 1): call 2 limits with a much later reset (so gemini, not codex, is the soonest).
  cat > "$bin_dir/codex" <<STUBEOF
#!/usr/bin/env bash
cat > /dev/null
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n + 1))
printf '%s' "\$n" > "$counter"
printf '%s\n' '{"type":"thread.started","thread_id":"c-1"}'
if [ "\$n" -eq 2 ]; then
  printf '%s\n' '{"type":"error","message":"Rate limit exceeded. Try again in 90s."}'
  exit 1
fi
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done\n\n[[TASK_COMPLETE]]"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
exit 0
STUBEOF
  chmod +x "$bin_dir/codex"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 10, "maxRetriesOnError": 0, "limitWaitMinutes": 5, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "wait-then-switch-back", "cli": "gemini", "model": "m-r0", "projectPath": "$project_dir", "prompt": "do it",
      "fallbacks": [ { "cli": "codex", "model": "c-1" } ] }
  ]
}
EOF

  local out exit_code gemini_content
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  gemini_content=""
  if [ -f "$gemini_stdin" ]; then gemini_content=$(cat "$gemini_stdin"); fi

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -qi 'switching to codex' &&
     printf '%s' "$out" | grep -qi 'switching to gemini' &&
     printf '%s' "$out" | grep -q 'Task 1 done' &&
     printf '%s' "$gemini_content" | grep -q 'A previous AI tool'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
output:
$out
gemini stdin:
$gemini_content"
  fi
}

run_runs_csv_columns_test() {
  local desc="runs.csv header and rows include cli and model columns (Phase 8)"
  local root="$TMP_ROOT/runs-csv-columns"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local state_dir="$root/queue"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$root/received.txt" '{"result":"done\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "CSV Task", "cli": "claude", "model": "sonnet", "projectPath": "$project_dir", "prompt": "do it", "completionCheck": true }
  ]
}
EOF

  local out exit_code
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  local header row_ok=0
  header=$(sed -n '1p' "$state_dir/runs.csv" 2>/dev/null)
  if grep -q ',Done,' "$state_dir/runs.csv" 2>/dev/null && \
     grep -q ',claude,' "$state_dir/runs.csv" 2>/dev/null && \
     grep -q ',sonnet' "$state_dir/runs.csv" 2>/dev/null; then
    row_ok=1
  fi

  if [ "$exit_code" -eq 0 ] &&
     [ "$header" = "timestamp,task,run,mode,exit,status,cli,model" ] &&
     [ "$row_ok" -eq 1 ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code header='$header' row_ok=$row_ok
$out
--- runs.csv ---
$(cat "$state_dir/runs.csv" 2>/dev/null)"
  fi
}

run_runner_index_switch_test() {
  local desc="CLI rotation (fallbacks) — runner-index file written after runner switch (Task 9.2)"
  local root="$TMP_ROOT/runner-idx-switch"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"

  mkdir -p "$bin_dir" "$project_dir"
  git -C "$project_dir" init -q

  cat > "$bin_dir/gemini" <<'STUBEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"session_id":"g-1","error":{"message":"Quota exceeded. Try again in 1s.","code":"429"}}'
exit 1
STUBEOF
  chmod +x "$bin_dir/gemini"

  cat > "$bin_dir/codex" <<'STUBEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"type":"thread.started","thread_id":"c-1"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done\\n\\n[[TASK_COMPLETE]]"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
exit 0
STUBEOF
  chmod +x "$bin_dir/codex"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "rotate-idx", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it",
      "fallbacks": [ { "cli": "codex", "model": "c-1" } ] }
  ]
}
EOF

  local out exit_code idx_file idx_val
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  idx_file="$root/queue/sessions/task-01-runner-index.txt"
  idx_val=$(cat "$idx_file" 2>/dev/null | tr -d ' \r\n')

  if [ "$exit_code" -eq 0 ] &&
     [ -f "$idx_file" ] &&
     [ "$idx_val" = "1" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code idx_exists=$([ -f "$idx_file" ] && echo yes || echo no) idx_val=[$idx_val]
$out"
  fi
}

run_runner_model_index_per_runner_test() {
  local desc="CLI rotation (fallbacks) — per-runner model-index file scoped to runner (task-NN-runner-R-model-index.txt) (Task 9.2)"
  local root="$TMP_ROOT/runner-model-idx"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"

  mkdir -p "$bin_dir" "$project_dir"
  git -C "$project_dir" init -q

  cat > "$bin_dir/gemini" <<'STUBEOF'
#!/usr/bin/env bash
cat > /dev/null
model=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-m" ]; then model="$a"; fi
  prev="$a"
done
if [ "$model" = "m-first" ]; then
  printf '%s\n' '{"session_id":"g-1","error":{"message":"Quota exceeded. Try again in 1s.","code":"429"}}'
  exit 1
fi
printf '%s\n' '{"session_id":"g-1","response":"done\n\n[[TASK_COMPLETE]]"}'
exit 0
STUBEOF
  chmod +x "$bin_dir/gemini"

  cat > "$bin_dir/codex" <<'STUBEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"type":"thread.started","thread_id":"c-1"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done\\n\\n[[TASK_COMPLETE]]"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
exit 0
STUBEOF
  chmod +x "$bin_dir/codex"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "per-runner-model-idx", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it",
      "model": ["m-first", "m-second"],
      "fallbacks": [ { "cli": "codex", "model": "c-1" } ] }
  ]
}
EOF

  local out exit_code model_idx_file flat_idx_file model_idx_val
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  model_idx_file="$root/queue/sessions/task-01-runner-0-model-index.txt"
  flat_idx_file="$root/queue/sessions/task-01-model-index.txt"
  model_idx_val=$(cat "$model_idx_file" 2>/dev/null | tr -d ' \r\n')

  if [ "$exit_code" -eq 0 ] &&
     [ -f "$model_idx_file" ] &&
     [ "$model_idx_val" = "1" ] &&
     [ ! -f "$flat_idx_file" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code model_idx_exists=$([ -f "$model_idx_file" ] && echo yes || echo no) model_idx_val=[$model_idx_val] flat_exists=$([ -f "$flat_idx_file" ] && echo yes || echo no)
$out"
  fi
}

run_runner_index_rerun_invalidation_test() {
  local desc="CLI rotation (fallbacks) — changed fallback drops runner-index and per-runner model-index on re-run (Task 9.2)"
  local root="$TMP_ROOT/runner-idx-invalidate"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local counter_file="$root/gemini-counter"

  mkdir -p "$bin_dir" "$project_dir"
  git -C "$project_dir" init -q

  cat > "$bin_dir/gemini" <<EOF
#!/usr/bin/env bash
cat > /dev/null
n=0
if [ -f "$counter_file" ]; then n=\$(cat "$counter_file"); fi
n=\$((n+1))
printf '%s' "\$n" > "$counter_file"
if [ "\$n" -eq 1 ]; then
  printf '%s\n' '{"session_id":"g-1","error":{"message":"Quota exceeded. Try again in 1s.","code":"429"}}'
  exit 1
fi
printf '%s\n' '{"session_id":"g-1","response":"done\\n\\n[[TASK_COMPLETE]]"}'
exit 0
EOF
  chmod +x "$bin_dir/gemini"

  cat > "$bin_dir/codex" <<'STUBEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"type":"thread.started","thread_id":"c-1"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done\\n\\n[[TASK_COMPLETE]]"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
exit 0
STUBEOF
  chmod +x "$bin_dir/codex"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "invalidate-runner-state", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it",
      "fallbacks": [ { "cli": "codex", "model": "c-1" } ] }
  ]
}
EOF

  local out1 out2 exit_code idx_path m_idx_path counter_val
  out1=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)

  idx_path="$root/queue/sessions/task-01-runner-index.txt"
  m_idx_path="$root/queue/sessions/task-01-runner-1-model-index.txt"

  # Plant a per-runner model-index to verify it gets deleted on re-run.
  printf '%s' '0' > "$m_idx_path"

  # Change fallback model to trigger re-run invalidation.
  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "invalidate-runner-state", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it",
      "fallbacks": [ { "cli": "codex", "model": "c-2-changed" } ] }
  ]
}
EOF

  out2=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  counter_val=$(cat "$counter_file" 2>/dev/null | tr -d ' \r\n')

  if [ "$exit_code" -eq 0 ] &&
     [ ! -f "$idx_path" ] &&
     [ ! -f "$m_idx_path" ] &&
     [ "$counter_val" = "2" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code idx_exists=$([ -f "$idx_path" ] && echo yes || echo no) m_idx_exists=$([ -f "$m_idx_path" ] && echo yes || echo no) counter=[$counter_val]
--- run1 ---
$out1
--- run2 ---
$out2"
  fi
}

run_runner_index_no_fallbacks_test() {
  local desc="CLI rotation (fallbacks) — no-fallbacks task creates no runner-index file (Task 9.2)"
  local root="$TMP_ROOT/runner-idx-no-fallbacks"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"

  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/gemini" <<'STUBEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"session_id":"g-1","response":"done\n\n[[TASK_COMPLETE]]"}'
exit 0
STUBEOF
  chmod +x "$bin_dir/gemini"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "no-fallbacks", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it" }
  ]
}
EOF

  local out exit_code idx_file
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  idx_file="$root/queue/sessions/task-01-runner-index.txt"

  if [ "$exit_code" -eq 0 ] &&
     [ ! -f "$idx_file" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code idx_exists=$([ -f "$idx_file" ] && echo yes || echo no)
$out"
  fi
}

run_block_recovery_validation_test() {
  local desc="block recovery — rejects settings and task placement even when settings is zero"
  local root="$TMP_ROOT/block-rec-validation"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  mkdir -p "$project_dir"

  cat > "$queue_path" <<EOF
{
  "settings": { "recoveryAttempts": 0 },
  "tasks": [
    { "name": "bad", "cli": "claude", "projectPath": "$project_dir", "prompt": "p", "recoveryAttempts": 1 }
  ]
}
EOF

  check "$desc" 2 'recoveryAttempts may be set in settings OR on individual tasks' bash "$SCRIPT" --queue "$queue_path" --validate-only
}

run_block_recovery_no_recovery_backcompat_test() {
  local desc="block recovery — recoveryAttempts absent does not retry a blocked task"
  local root="$TMP_ROOT/block-rec-off"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local counter="$root/count"
  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-p" ] && [ "\${2:-}" = "/usage" ]; then
  printf '%s\n' 'Current session: 0% used' 'Current week (all models): 0% used'
  exit 0
fi
cat >/dev/null
n=0; [ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n+1)); printf '%s' "\$n" > "$counter"
printf '%s\n' '{"session_id":"s-1","result":"[[TASK_BLOCKED]] missing info","is_error":false}'
exit 0
EOF
  chmod +x "$bin_dir/claude"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": false, "maxRunsPerTask": 3, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "blocked", "cli": "claude", "projectPath": "$project_dir", "prompt": "p" }
  ]
}
EOF

  local out exit_code count_val needs_path
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  count_val=$(cat "$counter" 2>/dev/null | tr -d ' \r\n')
  needs_path="$root/queue/status/task-01.needs-human"
  if [ "$exit_code" -eq 0 ] && [ "$count_val" = "1" ] && [ ! -f "$needs_path" ] && ! printf '%s' "$out" | grep -q 'recovery round'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code count=[$count_val] needs=$([ -f "$needs_path" ] && echo yes || echo no)
$out"
  fi
}

run_block_recovery_success_test() {
  local desc="block recovery — blocked task resumes same session with Variant A and completes"
  local root="$TMP_ROOT/block-rec-success"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local counter="$root/count"
  local stdin_log="$root/stdin.log"
  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-p" ] && [ "\${2:-}" = "/usage" ]; then
  printf '%s\n' 'Current session: 0% used' 'Current week (all models): 0% used'
  exit 0
fi
stdin=\$(cat)
n=0; [ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n+1)); printf '%s' "\$n" > "$counter"
printf '%s\n%s\n' "--- CALL \$n ---" "\$stdin" >> "$stdin_log"
if [ "\$n" -eq 1 ]; then
  printf '%s\n' '{"session_id":"s-1","result":"[[TASK_BLOCKED]] missing info","is_error":false}'
else
  printf '%s\n' '{"session_id":"s-1","result":"done\n[[TASK_COMPLETE]]","is_error":false}'
fi
exit 0
EOF
  chmod +x "$bin_dir/claude"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 3, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "recover", "cli": "claude", "projectPath": "$project_dir", "prompt": "p", "recoveryAttempts": 1 }
  ]
}
EOF

  local out exit_code stdin_text
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  stdin_text=$(cat "$stdin_log" 2>/dev/null)
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'recovery round 1 of 1' &&
     printf '%s' "$stdin_text" | grep -q 'You ended with \[\[TASK_BLOCKED\]\]: missing info' &&
     ! printf '%s' "$stdin_text" | grep -q 'A previous AI tool worked on this task'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
--- output ---
$out
--- stdin ---
$stdin_text"
  fi
}

run_block_recovery_human_short_circuit_test() {
  local desc="block recovery — HUMAN short-circuits recovery and writes needs-human marker"
  local root="$TMP_ROOT/block-rec-human"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local counter="$root/count"
  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-p" ] && [ "\${2:-}" = "/usage" ]; then
  printf '%s\n' 'Current session: 0% used' 'Current week (all models): 0% used'
  exit 0
fi
cat >/dev/null
n=0; [ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n+1)); printf '%s' "\$n" > "$counter"
printf '%s\n' '{"session_id":"s-1","result":"[[TASK_BLOCKED]] human: need prod creds","is_error":false}'
exit 0
EOF
  chmod +x "$bin_dir/claude"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": false, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "human", "cli": "claude", "projectPath": "$project_dir", "prompt": "p", "recoveryAttempts": 3 }
  ]
}
EOF

  local out exit_code count_val marker
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  count_val=$(cat "$counter" 2>/dev/null | tr -d ' \r\n')
  marker="$root/queue/status/task-01.needs-human"
  if [ "$exit_code" -eq 0 ] && [ "$count_val" = "1" ] && [ -f "$marker" ] &&
     grep -q 'human: need prod creds' "$marker" &&
     printf '%s' "$out" | grep -q 'needs human review: human: need prod creds'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code count=[$count_val] marker=$([ -f "$marker" ] && cat "$marker" || echo missing)
$out"
  fi
}

run_block_recovery_exhaustion_test() {
  local desc="block recovery — exhaustion writes failed and needs-human markers"
  local root="$TMP_ROOT/block-rec-exhaust"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  mkdir -p "$bin_dir" "$project_dir"

  cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-p" ] && [ "${2:-}" = "/usage" ]; then
  printf '%s\n' 'Current session: 0% used' 'Current week (all models): 0% used'
  exit 0
fi
cat >/dev/null
printf '%s\n' '{"session_id":"s-1","result":"[[TASK_BLOCKED]] still stuck","is_error":false}'
exit 0
EOF
  chmod +x "$bin_dir/claude"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": false, "maxRunsPerTask": 3, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [
    { "name": "exhaust", "cli": "claude", "projectPath": "$project_dir", "prompt": "p", "recoveryAttempts": 1 }
  ]
}
EOF

  local out exit_code failed_marker needs_marker
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  failed_marker="$root/queue/status/task-01.failed"
  needs_marker="$root/queue/status/task-01.needs-human"
  if [ "$exit_code" -eq 0 ] && [ -f "$failed_marker" ] && [ -f "$needs_marker" ] &&
     grep -q 'still stuck' "$needs_marker" &&
     printf '%s' "$out" | grep -q '1 need human review'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code failed=$([ -f "$failed_marker" ] && echo yes || echo no) needs=$([ -f "$needs_marker" ] && echo yes || echo no)
$out"
  fi
}

run_block_recovery_variant_b_handoff_test() {
  local desc="block recovery — runner switch handoff includes failure reason and output tail when enabled"
  local root="$TMP_ROOT/block-rec-variant-b"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local codex_stdin="$root/codex.stdin"
  mkdir -p "$bin_dir" "$project_dir"
  git -C "$project_dir" init -q

  cat > "$bin_dir/gemini" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"error":{"message":"Quota exceeded. Try again in 1s.","code":"429"},"session_id":"g-1"}'
exit 1
EOF
  chmod +x "$bin_dir/gemini"

  cat > "$bin_dir/codex" <<EOF
#!/usr/bin/env bash
cat > "$codex_stdin"
printf '%s\n' '{"type":"thread.started","thread_id":"c-1"}'
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"done\n[[TASK_COMPLETE]]"}}'
exit 0
EOF
  chmod +x "$bin_dir/codex"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 3, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0, "recoveryAttempts": 1 },
  "tasks": [
    { "name": "handoff", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it",
      "fallbacks": [ { "cli": "codex" } ] }
  ]
}
EOF

  local out exit_code prompt
  out=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  prompt=$(cat "$codex_stdin" 2>/dev/null)
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$prompt" | grep -q 'This is why the previous attempt did not finish:' &&
     printf '%s' "$prompt" | grep -q 'limited' &&
     printf '%s' "$prompt" | grep -q 'Quota exceeded'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
--- output ---
$out
--- prompt ---
$prompt"
  fi
}

run_cli_rotation_limit_switch_test
run_graceful_stop_after_step_test
run_cli_rotation_error_switch_test
run_cli_rotation_blocked_no_switch_test
run_cli_rotation_no_fallbacks_backcompat_test
run_cli_rotation_all_limited_wait_test
run_cli_rotation_claude_reactive_limit_test
run_claude_session_lost_recovery_test
run_claude_slash_rejected_flags_human_test
run_cli_rotation_handoff_after_wait_test
run_runs_csv_columns_test
run_runner_index_switch_test
run_runner_model_index_per_runner_test
run_runner_index_rerun_invalidation_test
run_runner_index_no_fallbacks_test
run_block_recovery_validation_test
run_block_recovery_no_recovery_backcompat_test
run_block_recovery_success_test
run_block_recovery_human_short_circuit_test
run_block_recovery_exhaustion_test
run_block_recovery_variant_b_handoff_test

run_stopped_early_summary_test() {
  local desc="stopped early summary shows correct count of tasks"
  local root="$TMP_ROOT/stopped-early"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local flag_path="$root/stop.flag"

  mkdir -p "$bin_dir" "$project_dir"
  # Gemini stub that requests a stop during the first task's execution.
  cat > "$bin_dir/gemini" <<EOF
#!/usr/bin/env bash
touch "$flag_path"
printf '{"session_id":"g-1","response":"done"}'
exit 0
EOF
  chmod +x "$bin_dir/gemini"

  cat > "$queue_path" <<EOF
{
  "tasks": [
    { "name": "t1", "cli": "gemini", "projectPath": "$project_dir", "prompt": "p1" },
    { "name": "t2", "cli": "gemini", "projectPath": "$project_dir", "prompt": "p2" }
  ]
}
EOF

  local out exit_code
  # Set STOP_FLAG to the flag_path
  out=$(STOP_FLAG="$flag_path" PATH="$bin_dir:$PATH" bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -qiE 'Stopped early - 1 of 2 ran \(1 not reached\)' &&
     printf '%s' "$out" | grep -q 'Rerun the same command to continue'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_profile_model_validation_test() {
  local desc="profile-based model validation"
  
  # Create a profile
  echo '{"clis": {"claude": {"models": ["valid-model"]}}}' > limitshift-profile.json
  
  # Create a queue with typo model
  local root="$TMP_ROOT/profile-test"
  mkdir -p "$root/project"
  local queue_path="$root/queue.json"
  cat > "$queue_path" <<EOF
{
  "settings": { "modelValidation": "strictWhenDiscoverable" },
  "tasks": [
    { "name": "t", "cli": "claude", "projectPath": "$root/project", "prompt": "p", "model": "typo-model" }
  ]
}
EOF

  # Run validation
  local out
  out=$(bash "$SCRIPT" --validate-only --queue "$queue_path" 2>&1)
  local exit_code=$?

  rm limitshift-profile.json

  if [ "$exit_code" -eq 2 ] && printf '%s' "$out" | grep -q 'not available'; then
    pass "$desc (strict fails typo)"
  else
    fail "$desc (strict fails typo)" "exit=$exit_code (wanted 2)
$out"
  fi
  
  # Valid model
  cat > "$queue_path" <<EOF
{
  "settings": { "modelValidation": "strictWhenDiscoverable" },
  "tasks": [
    { "name": "t", "cli": "claude", "projectPath": "$root/project", "prompt": "p", "model": "valid-model" }
  ]
}
EOF
  
  out=$(bash "$SCRIPT" --validate-only --queue "$queue_path" 2>&1)
  exit_code=$?
  
  if [ "$exit_code" -eq 0 ] && printf '%s' "$out" | grep -q 'Config OK'; then
    pass "$desc (strict passes valid)"
  else
    fail "$desc (strict passes valid)" "exit=$exit_code (wanted 0)
$out"
  fi
}

run_profile_model_validation_test

echo
echo "passed: $PASS  failed: $FAIL"
exit "$FAIL"
