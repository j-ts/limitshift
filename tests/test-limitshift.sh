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
  rm -rf "$TMP_ROOT" "$CONFIGS"/.limitshift-*
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
  rm -rf "$CONFIGS"/.limitshift-*
}

run_dry_run_state_test() {
  local desc="dry run prints commands without persisting done markers"
  reset_fixture_state

  local out exit_code state_dir
  out=$(bash "$SCRIPT" --queue "$CONFIGS/valid-full.json" --dry-run 2>&1)
  exit_code=$?
  state_dir="$CONFIGS/.limitshift-valid-full"

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
  local status_dir="$root/.limitshift-queue/status"

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
  local status_dir="$root/.limitshift-queue/status"

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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
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
  local status_dir="$root/.limitshift-queue/status"

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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
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
  local status_dir="$root/.limitshift-queue/status"

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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     [ -f "$status_dir/task-01.done" ] &&
     printf '%s' "$out" | grep -q 'Task 1 completed'; then
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
  local status_dir="$root/.limitshift-queue/status"

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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
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
  local output_file="$root/.limitshift-queue/outputs/task-01-clean-output-output.txt"

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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q -- '--- agent response ---' &&
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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" --show-raw 2>&1)
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
  local status_dir="$root/.limitshift-queue/status"

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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  resume_prompt=$(cat "$received_dir/run-2.txt" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$resume_prompt" | grep -q 'Continue the previous task in this same session from where you stopped. Do not restart from scratch.' &&
     printf '%s' "$resume_prompt" | grep -q '/goal ship it' &&
     printf '%s' "$resume_prompt" | grep -q 'do the simple task' &&
     ! printf '%s' "$resume_prompt" | grep -q 'IMPORTANT AUTOMATION INSTRUCTIONS' &&
     ! printf '%s' "$resume_prompt" | grep -q 'TASK_COMPLETE'; then
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
  local state_dir="$root/.limitshift-queue"

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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     [ -f "$state_dir/_README.txt" ] &&
     grep -qi 'delete this whole folder' "$state_dir/_README.txt" &&
     [ -f "$state_dir/runs.csv" ] &&
     [ "$(sed -n '1p' "$state_dir/runs.csv")" = "timestamp,task,run,mode,exit,status" ] &&
     grep -q ',Done$' "$state_dir/runs.csv" &&
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
  local done_file="$root/.limitshift-queue/status/task-01.done"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"did it\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "fp", "cli": "claude", "projectPath": "$project_dir", "prompt": "do it" } ]
}
EOF

  local out exit_code line_count fp_line
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
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
  local done_file="$root/.limitshift-queue/status/task-01.done"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_response "$bin_dir" "$received_file" '{"result":"did it\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "fp", "cli": "claude", "projectPath": "$project_dir", "prompt": "unchanged prompt" } ]
}
EOF

  # Seed a legacy marker: a single timestamp line with no fingerprint (older format).
  mkdir -p "$root/.limitshift-queue/status"
  printf '%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$done_file"

  local out exit_code line_count fp_line
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'changed since last run'; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code
$out"
  fi
}

run_state_migration_test() {
  local desc="old .ai-runner-<name> state folder migrates to .limitshift-<name>, preserving contents"
  local root="$TMP_ROOT/state-migration"
  local bin_dir="$root/bin"
  local project_dir="$root/project"
  local queue_path="$root/queue.json"
  local legacy_state_dir="$root/.ai-runner-queue"
  local new_state_dir="$root/.limitshift-queue"

  mkdir -p "$bin_dir" "$project_dir"
  write_fake_claude_success "$bin_dir"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 2, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "migrate task", "cli": "claude", "projectPath": "$project_dir", "prompt": "do it" } ]
}
EOF

  # Seed an OLD-named state folder with a marker file whose contents must survive the migration.
  mkdir -p "$legacy_state_dir"
  printf '%s' 'preserve me 123' > "$legacy_state_dir/marker.txt"

  local out exit_code marker
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  marker=$(cat "$new_state_dir/marker.txt" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Migrated state folder .ai-runner-queue -> .limitshift-queue' &&
     [ -d "$new_state_dir" ] &&
     [ ! -d "$legacy_state_dir" ] &&
     [ "$marker" = "preserve me 123" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code marker=[$marker]
$out"
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
  PATH="$bin_dir:$PATH" out=$(bash "$script_copy" 2>&1)
  exit_code=$?

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Using legacy queue filename ai-run-queue.json' &&
     printf '%s' "$out" | grep -q 'Task 1 completed' &&
     [ -f "$root/.limitshift-ai-run-queue/status/task-01.done" ]; then
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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" --validate-only 2>&1); exit_code=$?
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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1); exit_code=$?
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Task 1 completed' &&
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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1); exit_code=$?
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Task 1 completed' &&
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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1); exit_code=$?
  runs=$(grep -c '^run$' "$log_file")
  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'Task 1 completed' &&
     [ "$runs" = "1" ] &&
     ! printf '%s' "$out" | grep -qi 'paused by a usage limit'; then
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
     printf '%s' "$out" | grep -q 'Task 1 completed' &&
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
  local idx_file="$root/.limitshift-queue/sessions/task-01-model-index.txt"

  mkdir -p "$bin_dir" "$project_dir"
  write_rotation_gemini "$bin_dir" "$model_log" "m-first"

  cat > "$queue_path" <<EOF
{
  "settings": { "stopOnError": true, "maxRunsPerTask": 5, "maxRetriesOnError": 0, "limitWaitMinutes": 1, "resetBufferMinutes": 0 },
  "tasks": [ { "name": "rotate", "cli": "gemini", "projectPath": "$project_dir", "prompt": "do it", "model": ["m-first", "m-second"] } ]
}
EOF

  local out exit_code first second saved_idx
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  first=$(sed -n '1p' "$model_log" 2>/dev/null)
  second=$(sed -n '2p' "$model_log" 2>/dev/null)
  saved_idx=$(cat "$idx_file" 2>/dev/null | tr -d ' \r\n')

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'switching to m-second' &&
     printf '%s' "$out" | grep -q 'Task 1 completed' &&
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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  m1=$(sed -n '1p' "$model_log" 2>/dev/null)
  m2=$(sed -n '2p' "$model_log" 2>/dev/null)
  m3=$(sed -n '3p' "$model_log" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'paused by a usage limit' &&
     printf '%s' "$out" | grep -q 'Task 1 completed' &&
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
  PATH="$bin_dir:$PATH" out=$(bash "$SCRIPT" --queue "$queue_path" 2>&1)
  exit_code=$?
  m1=$(sed -n '1p' "$model_log" 2>/dev/null)
  m2=$(sed -n '2p' "$model_log" 2>/dev/null)

  if [ "$exit_code" -eq 0 ] &&
     printf '%s' "$out" | grep -q 'paused by a usage limit' &&
     ! printf '%s' "$out" | grep -q 'switching to' &&
     printf '%s' "$out" | grep -q 'Task 1 completed' &&
     [ "$m1" = "only-model" ] && [ "$m2" = "only-model" ]; then
    pass "$desc"
  else
    fail "$desc" "exit=$exit_code m1=[$m1] m2=[$m2]
$out"
  fi
}

run_shipped_examples_validate_test() {
  # Task 7: every shipped example file (legacy name, simple, advanced) must pass
  # --validate-only. The examples carry placeholder projectPath values that do not
  # exist on this machine and validation requires projectPath to exist, so copy each
  # example to a temp file and rewrite every task's projectPath to a real temp dir first.
  local repo_root="$HERE/.."
  local root="$TMP_ROOT/shipped-examples"
  local project_dir="$root/project"
  mkdir -p "$project_dir"

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
    # Rewrite ALL task projectPath values (advanced has multiple) to the temp dir.
    if ! jq --arg pp "$project_dir" '(.tasks[].projectPath) = $pp' "$src" > "$dst" 2>/dev/null; then
      fail "$desc" "could not rewrite projectPath in $src"
      continue
    fi
    check "$desc" 0 "Config OK" -- bash "$SCRIPT" --queue "$dst" --validate-only
  done
}

check "valid minimal config validates"           0 "Config OK"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-minimal.json" --validate-only
check "valid full config validates"              0 "Config OK"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-full.json" --validate-only
check "trailing comma rejected with explanation" 2 "not valid JSON"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-trailing-comma.json" --validate-only
check "missing field rejected naming the field"  2 "Task 1.*prompt"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-missing-field.json" --validate-only
check "unknown cli rejected listing allowed"     2 "claude, codex, gemini, agy" -- bash "$SCRIPT" --queue "$CONFIGS/broken-bad-cli.json" --validate-only
check "missing project path rejected"            2 "does not exist"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-missing-path.json" --validate-only
check "missing queue file gives copy hint"       2 "limitshift-queue.example.json" -- bash "$SCRIPT" --queue "$HERE/nope.json" --validate-only
run_dry_run_state_test
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
run_state_migration_test
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
run_effort_claude_haiku_null_ok_test
run_effort_codex_none_rejected_test
run_effort_codex_high_ok_test
run_effort_empty_string_normalized_test
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
run_shipped_examples_validate_test

echo
echo "passed: $PASS  failed: $FAIL"
exit "$FAIL"
