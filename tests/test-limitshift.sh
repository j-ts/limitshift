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

check "valid minimal config validates"           0 "Config OK"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-minimal.json" --validate-only
check "valid full config validates"              0 "Config OK"             -- bash "$SCRIPT" --queue "$CONFIGS/valid-full.json" --validate-only
check "trailing comma rejected with explanation" 2 "not valid JSON"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-trailing-comma.json" --validate-only
check "missing field rejected naming the field"  2 "Task 1.*prompt"        -- bash "$SCRIPT" --queue "$CONFIGS/broken-missing-field.json" --validate-only
check "unknown cli rejected listing allowed"     2 "claude, codex, gemini" -- bash "$SCRIPT" --queue "$CONFIGS/broken-bad-cli.json" --validate-only
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

echo
echo "passed: $PASS  failed: $FAIL"
exit "$FAIL"
