#!/usr/bin/env bash
# LimitShift — runs queued prompts against claude / codex / gemini CLIs,
# waiting out usage limits and resuming sessions. macOS (bash 3.2+) and Linux.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUEUE_PATH="$SCRIPT_DIR/ai-run-queue.json"
VALIDATE_ONLY=0
DRY_RUN=0

TASK_COMPLETE_MARKER="[[TASK_COMPLETE]]"
TASK_BLOCKED_MARKER="[[TASK_BLOCKED]]"

usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  --queue <path>       Path to queue JSON file (default: ai-run-queue.json next to script)"
  echo "  --validate-only      Validate configuration syntax, paths, and binaries, then exit"
  echo "  --dry-run            Simulate execution by printing commands without running them"
  echo "  -h, --help           Show this help message"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --queue) QUEUE_PATH="$2"; shift 2 ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&2
  echo "  macOS: brew install jq    Linux: sudo apt install jq (or your distro's equivalent)" >&2
  exit 2
fi

# Convert to absolute path
if [[ "$QUEUE_PATH" != /* ]] && [[ "$QUEUE_PATH" != [a-zA-Z]:\\* ]] && [[ "$QUEUE_PATH" != [a-zA-Z]:/* ]]; then
  QUEUE_PATH="$(pwd)/$QUEUE_PATH"
fi

# Normalize path separators if on Windows (e.g. from C:\some\path to C:/some/path)
QUEUE_PATH="${QUEUE_PATH//\\//}"

if [ ! -f "$QUEUE_PATH" ]; then
  echo "Config file not found: $QUEUE_PATH" >&2
  echo "Copy ai-run-queue.example.json to ai-run-queue.json and fill in your tasks." >&2
  exit 2
fi

QUEUE_DIR="$(cd "$(dirname "$QUEUE_PATH")" && pwd)"
QUEUE_FILE_NAME="$(basename "$QUEUE_PATH")"
QUEUE_PATH="$QUEUE_DIR/$QUEUE_FILE_NAME"
RUNNER_NAME="${QUEUE_FILE_NAME%.*}"
RUNNER_STATE_PATH="$QUEUE_DIR/.ai-runner-$RUNNER_NAME"
SESSION_STATE_PATH="$RUNNER_STATE_PATH/sessions"
OUTPUT_STATE_PATH="$RUNNER_STATE_PATH/outputs"
STATUS_STATE_PATH="$RUNNER_STATE_PATH/status"
LOG_PATH="$RUNNER_STATE_PATH/ai-run-log.txt"
USAGE_PATH="$RUNNER_STATE_PATH/claude-usage-last.txt"

FRESH_SESSION_THRESHOLD_PERCENT=0
POLL_SECONDS_AFTER_RESET_PASSED=60

write_step() {
  echo ""
  echo "==== $1 ===="
  echo ""
}

task_field() {
  local idx="$1"
  local field="$2"
  jq -r ".tasks[$idx].$field // empty" "$QUEUE_PATH" | tr -d '\r'
}

get_task_extra_args() {
  local idx="$1"
  jq -r ".tasks[$idx].extraArgs | if type==\"array\" then .[] elif type==\"string\" then splits(\"\\\\s+\") else empty end" "$QUEUE_PATH" | tr -d '\r'
}

read_queue_config() {
  local jq_err
  if ! jq_err=$(jq empty "$QUEUE_PATH" 2>&1); then
    echo "Config file is not valid JSON: $QUEUE_PATH" >&2
    echo "Parser said: $jq_err" >&2
    echo "Common causes: a trailing comma after the last item, a missing comma between items," >&2
    echo "or an unescaped quote inside a prompt." >&2
    exit 2
  fi

  TASK_COUNT=$(jq '.tasks | length' "$QUEUE_PATH" | tr -d '\r')
  if [ "$TASK_COUNT" = "null" ] || [ "$TASK_COUNT" -eq 0 ]; then
    echo "Config file contains no tasks: $QUEUE_PATH" >&2
    exit 2
  fi

  STOP_ON_ERROR=$(jq -r '.settings.stopOnError // true' "$QUEUE_PATH" | tr -d '\r')
  MAX_RUNS_PER_TASK=$(jq -r '.settings.maxRunsPerTask // 20' "$QUEUE_PATH" | tr -d '\r')
  MAX_RETRIES_ON_ERROR=$(jq -r '.settings.maxRetriesOnError // 2' "$QUEUE_PATH" | tr -d '\r')
  LIMIT_WAIT_MINUTES=$(jq -r '.settings.limitWaitMinutes // 30' "$QUEUE_PATH" | tr -d '\r')
  RESET_BUFFER_MINUTES=$(jq -r '.settings.resetBufferMinutes // 2' "$QUEUE_PATH" | tr -d '\r')

  local i=0 n cli path
  while [ "$i" -lt "$TASK_COUNT" ]; do
    n=$((i + 1))
    for field in name cli projectPath prompt; do
      if [ "$(task_field "$i" "$field")" = "" ]; then
        echo "Task $n is missing required JSON property: $field" >&2
        exit 2
      fi
    done
    cli=$(task_field "$i" "cli" | tr '[:upper:]' '[:lower:]')
    case "$cli" in
      claude|codex|gemini) ;;
      *) echo "Task $n has unknown cli \"$cli\". Allowed values: claude, codex, gemini" >&2; exit 2 ;;
    esac
    path=$(task_field "$i" "projectPath")
    # Normalize path separators for checking directory existence on unix/git-bash
    path="${path//\\//}"
    if [ ! -d "$path" ]; then
      echo "Project path does not exist for task $n: $path" >&2
      exit 2
    fi
    i=$((i + 1))
  done
}

check_cli_binaries() {
  local cli unique_clis missing_clis=()
  unique_clis=$(jq -r '.tasks[].cli' "$QUEUE_PATH" | tr '[:upper:]' '[:lower:]' | tr -d '\r' | sort -u)
  for cli in $unique_clis; do
    if ! command -v "$cli" >/dev/null 2>&1; then
      missing_clis+=("$cli")
    fi
  done
  
  if [ ${#missing_clis[@]} -gt 0 ]; then
    local missing_str
    missing_str=$(IFS=, ; echo "${missing_clis[*]}")
    echo "ERROR: The following CLI(s) are used in the queue but not found on PATH: $missing_str" >&2
    echo "Install instructions:" >&2
    echo "  claude : npm install -g @anthropic-ai/claude-code" >&2
    echo "  codex  : npm install -g @openai/codex" >&2
    echo "  gemini : npm install -g @google/gemini-cli" >&2
    exit 2
  fi
}

epoch_from_clock() {
  local clock="$1" epoch
  clock="${clock//[[:space:]]/}"
  if date -d "today $clock" +%s >/dev/null 2>&1; then
    epoch=$(date -d "today $clock" +%s)
  elif date -j -f "%I:%M %p" "$clock" +%s >/dev/null 2>&1; then
    epoch=$(date -j -f "%I:%M %p" "$clock" +%s)
  elif date -j -f "%I %p" "$clock" +%s >/dev/null 2>&1; then
    epoch=$(date -j -f "%I %p" "$clock" +%s)
  else
    return 1
  fi
  if [ "$epoch" -lt "$(date +%s)" ]; then epoch=$((epoch + 86400)); fi
  printf '%s\n' "$epoch"
}

parse_claude_reset_date() {
  local raw="$1" epoch
  local clean
  clean=$(printf '%s' "$raw" | tr -s ' ')
  
  if date -d "$clean" +%s >/dev/null 2>&1; then
    epoch=$(date -d "$clean" +%s)
  elif date -j -f "%b %d, %I:%M%p" "$clean" +%s >/dev/null 2>&1; then
    epoch=$(date -j -f "%b %d, %I:%M%p" "$clean" +%s)
  elif date -j -f "%b %d, %I%p" "$clean" +%s >/dev/null 2>&1; then
    epoch=$(date -j -f "%b %d, %I%p" "$clean" +%s)
  else
    return 1
  fi
  
  local now
  now=$(date +%s)
  if [ "$epoch" -lt "$((now - 300))" ]; then
    if date -d "today +1 year" >/dev/null 2>&1; then
      epoch=$(date -d "@$epoch + 1 year" +%s)
    else
      epoch=$((epoch + 31536000))
    fi
  fi
  printf '%s\n' "$epoch"
}

get_claude_usage() {
  write_step "Checking Claude usage"

  local usage_out exit_code
  usage_out=$(claude -p "/usage" 2>&1)
  exit_code=$?

  printf '%s\n' "$usage_out" > "$USAGE_PATH"

  if [ "$exit_code" -ne 0 ]; then
    echo "ERROR: Claude /usage failed with exit code $exit_code." >&2
    echo "$usage_out" >&2
    exit 1
  fi

  local session_line week_line
  session_line=$(printf '%s\n' "$usage_out" | grep -i "Current session:")
  week_line=$(printf '%s\n' "$usage_out" | grep -i "Current week (all models):")

  if [ -z "$session_line" ] || [ -z "$week_line" ]; then
    echo "ERROR: Could not parse Claude usage output." >&2
    echo "$usage_out" >&2
    exit 1
  fi

  SESSION_PERCENT=$(printf '%s\n' "$session_line" | sed -E 's/.*Current session:[[:space:]]*([0-9]+)%.*/\1/i')
  
  local session_reset_raw session_tz_raw
  SESSION_RESET=""
  SESSION_TIMEZONE=""
  if printf '%s\n' "$session_line" | grep -q -i "resets"; then
    session_reset_raw=$(printf '%s\n' "$session_line" | sed -E 's/.*resets[[:space:]]+([^(]+).*/\1/i')
    session_reset_raw=$(echo "$session_reset_raw" | awk '{$1=$1;print}')
    session_tz_raw=$(printf '%s\n' "$session_line" | sed -E 's/.*resets[[:space:]]+[^(]+\(([^)]+)\).*/\1/i')
    session_tz_raw=$(echo "$session_tz_raw" | awk '{$1=$1;print}')
    
    SESSION_RESET=$(parse_claude_reset_date "$session_reset_raw")
    SESSION_TIMEZONE="$session_tz_raw"
  fi

  WEEK_PERCENT=$(printf '%s\n' "$week_line" | sed -E 's/.*Current week.*:[[:space:]]*([0-9]+)%.*/\1/i')
  
  local week_reset_raw week_tz_raw
  WEEK_RESET=""
  WEEK_TIMEZONE=""
  if printf '%s\n' "$week_line" | grep -q -i "resets"; then
    week_reset_raw=$(printf '%s\n' "$week_line" | sed -E 's/.*resets[[:space:]]+([^(]+).*/\1/i')
    week_reset_raw=$(echo "$week_reset_raw" | awk '{$1=$1;print}')
    week_tz_raw=$(printf '%s\n' "$week_line" | sed -E 's/.*resets[[:space:]]+[^(]+\(([^)]+)\).*/\1/i')
    week_tz_raw=$(echo "$week_tz_raw" | awk '{$1=$1;print}')
    
    WEEK_RESET=$(parse_claude_reset_date "$week_reset_raw")
    WEEK_TIMEZONE="$week_tz_raw"
  fi

  if [ -z "$SESSION_RESET" ] && [ "$SESSION_PERCENT" -ge 100 ]; then
    echo "ERROR: Could not parse Claude session reset time from /usage output." >&2
    echo "$usage_out" >&2
    exit 1
  fi

  if [ -z "$WEEK_RESET" ] && [ "$WEEK_PERCENT" -ge 100 ]; then
    echo "ERROR: Could not parse Claude weekly reset time from /usage output." >&2
    echo "$usage_out" >&2
    exit 1
  fi

  echo "Claude usage command exit code: $exit_code"
  echo "Session usage: $SESSION_PERCENT%"
  if [ -n "$SESSION_RESET" ]; then
    echo "Session reset: $SESSION_RESET ($SESSION_TIMEZONE)"
  else
    echo "Session reset: N/A"
  fi
  echo "Week usage: $WEEK_PERCENT%"
  if [ -n "$WEEK_RESET" ]; then
    echo "Week reset: $WEEK_RESET ($WEEK_TIMEZONE)"
  else
    echo "Week reset: N/A"
  fi
}

wait_until_claude_ready() {
  local require_fresh="$1"
  while true; do
    get_claude_usage
    
    local session_ready=0
    if [ "$require_fresh" -eq 1 ]; then
      if [ "$SESSION_PERCENT" -le "$FRESH_SESSION_THRESHOLD_PERCENT" ]; then
        session_ready=1
      fi
    else
      if [ "$SESSION_PERCENT" -lt 100 ]; then
        session_ready=1
      fi
    fi

    local week_ready=0
    if [ "$WEEK_PERCENT" -lt 100 ]; then
      week_ready=1
    fi

    if [ "$session_ready" -eq 1 ] && [ "$week_ready" -eq 1 ]; then
      echo "==== Claude usage is available ===="
      echo "Current session usage: $SESSION_PERCENT%"
      echo "Current weekly usage: $WEEK_PERCENT%"
      return
    fi

    local reset_to_wait=""
    if [ "$WEEK_PERCENT" -ge 100 ]; then
      reset_to_wait="$WEEK_RESET"
    elif [ "$SESSION_PERCENT" -ge 100 ] || { [ "$require_fresh" -eq 1 ] && [ "$SESSION_PERCENT" -gt "$FRESH_SESSION_THRESHOLD_PERCENT" ]; }; then
      reset_to_wait="$SESSION_RESET"
    fi

    if [ -z "$reset_to_wait" ]; then
      echo "ERROR: Claude usage is not ready, but no reset time could be determined." >&2
      exit 1
    fi

    local wake_time=$((reset_to_wait + RESET_BUFFER_MINUTES * 60))
    local now
    now=$(date +%s)
    local sleep_seconds=$((wake_time - now))

    if [ "$sleep_seconds" -gt 0 ]; then
      echo "==== Waiting for Claude reset ===="
      local wake_date
      if date -d "@$wake_time" >/dev/null 2>&1; then
        wake_date=$(date -d "@$wake_time")
      else
        wake_date=$(date -r "$wake_time" 2>/dev/null || echo "$wake_time")
      fi
      echo "Sleeping until: $wake_date ($sleep_seconds seconds)"
      sleep "$sleep_seconds"
    else
      echo "==== Reset time already passed ===="
      echo "Checking usage again in $POLL_SECONDS_AFTER_RESET_PASSED seconds"
      sleep "$POLL_SECONDS_AFTER_RESET_PASSED"
    fi
  done
}

parse_reset_from_error() {
  local error_text="$1" match
  if [ -z "$error_text" ]; then
    R_RESET=""
    return
  fi

  match=$(printf '%s' "$error_text" | grep -oiE '(try again at|resets? at|available (again )?at)[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?' | head -n 1)
  if [ -n "$match" ]; then
    local clock
    clock=$(printf '%s' "$match" | sed -E 's/(try again at|resets? at|available (again )?at)[[:space:]]+//i')
    clock=$(echo "$clock" | awk '{$1=$1;print}')
    local epoch
    if epoch=$(epoch_from_clock "$clock"); then
      R_RESET="$epoch"
      return
    fi
  fi

  match=$(printf '%s' "$error_text" | grep -oiE 'try again in[[:space:]]+([0-9]+[[:space:]]*h(ours?)?)?[[:space:]]*([0-9]+[[:space:]]*m(in(utes?)?)?)?[[:space:]]*([0-9]+[[:space:]]*s(ec(onds?)?)?)?' | head -n 1)
  if [ -n "$match" ]; then
    local h=0 min=0 s=0
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*h'; then
      h=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*h.*/\1/')
    fi
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*m'; then
      min=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*m.*/\1/')
    fi
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*s'; then
      s=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*s.*/\1/')
    fi
    local now
    now=$(date +%s)
    R_RESET=$((now + h * 3600 + min * 60 + s))
    return
  fi

  match=$(printf '%s' "$error_text" | grep -oiE 'reset after[[:space:]]+([0-9]+[[:space:]]*h)?[[:space:]]*([0-9]+[[:space:]]*m)?[[:space:]]*([0-9]+[[:space:]]*s)?' | head -n 1)
  if [ -n "$match" ]; then
    local h=0 min=0 s=0
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*h'; then
      h=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*h.*/\1/')
    fi
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*m'; then
      min=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*m.*/\1/')
    fi
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*s'; then
      s=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*s.*/\1/')
    fi
    local now
    now=$(date +%s)
    R_RESET=$((now + h * 3600 + min * 60 + s))
    return
  fi

  match=$(printf '%s' "$error_text" | grep -oiE '"retryDelay"[[:space:]]*:[[:space:]]*"[0-9]+s"' | head -n 1)
  if [ -n "$match" ]; then
    local s
    s=$(printf '%s' "$match" | sed -E 's/.*"([0-9]+)s".*/\1/')
    local now
    now=$(date +%s)
    R_RESET=$((now + s))
    return
  fi

  R_RESET=""
}

wait_for_limit_reset() {
  local cli="$1"
  local error_text="$2"
  local settings_wait="$3"

  if [ "$cli" = "claude" ]; then
    wait_until_claude_ready 1
    return
  fi

  parse_reset_from_error "$error_text"
  local reset_time="$R_RESET"
  if [ -z "$reset_time" ]; then
    local now
    now=$(date +%s)
    reset_time=$((now + settings_wait * 60))
    echo "==== Limit hit on $cli; no reset time found in the error ===="
    echo "Waiting the configured limitWaitMinutes: $settings_wait minutes"
  fi
  
  local wake_time=$((reset_time + RESET_BUFFER_MINUTES * 60))
  local now
  now=$(date +%s)
  local sleep_seconds=$((wake_time - now))
  if [ "$sleep_seconds" -gt 0 ]; then
    local wake_date
    if date -d "@$wake_time" >/dev/null 2>&1; then
      wake_date=$(date -d "@$wake_time")
    else
      wake_date=$(date -r "$wake_time" 2>/dev/null || echo "$wake_time")
    fi
    echo "Sleeping until: $wake_date ($sleep_seconds seconds)"
    sleep "$sleep_seconds"
  fi
}

get_task_key() {
  local name="$1"
  printf '%s' "$name" | sed 's/[^a-zA-Z0-9_-]/-/g'
}

get_task_session_file_path() {
  local idx="$1" name key
  name=$(task_field "$idx" "name")
  key=$(get_task_key "$name")
  printf '%s' "$SESSION_STATE_PATH/$key.session"
}

get_task_output_file_path() {
  local idx="$1" name key
  name=$(task_field "$idx" "name")
  key=$(get_task_key "$name")
  printf '%s' "$OUTPUT_STATE_PATH/$key.txt"
}

get_task_done_file_path() {
  local idx="$1" name key
  name=$(task_field "$idx" "name")
  key=$(get_task_key "$name")
  printf '%s' "$STATUS_STATE_PATH/$key.done"
}

get_task_failed_file_path() {
  local idx="$1" name key
  name=$(task_field "$idx" "name")
  key=$(get_task_key "$name")
  printf '%s' "$STATUS_STATE_PATH/$key.failed"
}

get_saved_task_session_id() {
  local path
  path=$(get_task_session_file_path "$1")
  if [ -f "$path" ]; then
    cat "$path"
  else
    printf ''
  fi
}

new_task_session_id() {
  local uuid
  if command -v uuidgen >/dev/null 2>&1; then
    uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
  elif [ -f /proc/sys/kernel/random/uuid ]; then
    uuid=$(cat /proc/sys/kernel/random/uuid)
  else
    uuid=$(od -x -N 16 /dev/urandom 2>/dev/null | head -n 1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}')
    if [ -z "$uuid" ]; then
      uuid="mock-uuid-$RANDOM-$RANDOM"
    fi
  fi
  printf '%s' "$uuid"
}

test_task_already_done() {
  local path
  path=$(get_task_done_file_path "$1")
  if [ -f "$path" ]; then
    return 0
  else
    return 1
  fi
}

save_task_done_marker() {
  local path
  path=$(get_task_done_file_path "$1")
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$path"
}

save_task_failed_marker() {
  local path reason
  path=$(get_task_failed_file_path "$1")
  reason="$2"
  printf '%s  %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$reason" > "$path"
}

build_cli_args() {
  local idx="$1" mode="$2" session_id="$3" prompt="$4"
  local cli model effort project_path
  cli=$(task_field "$idx" "cli" | tr '[:upper:]' '[:lower:]')
  model=$(task_field "$idx" "model")
  effort=$(task_field "$idx" "effort")
  project_path=$(task_field "$idx" "projectPath")

  CLI_ARGS=()

  case "$cli" in
    claude)
      CLI_ARGS+=("-p")
      if [ "$mode" = "New" ]; then
        CLI_ARGS+=("--session-id" "$session_id")
      elif [ "$mode" = "Resume" ]; then
        CLI_ARGS+=("--resume" "$session_id")
      fi
      CLI_ARGS+=("--output-format" "json")
      if [ -n "$model" ]; then
        CLI_ARGS+=("--model" "$model")
      fi
      if [ -n "$effort" ]; then
        CLI_ARGS+=("--effort" "$effort")
      fi
      while IFS= read -r arg; do
        if [ -n "$arg" ]; then CLI_ARGS+=("$arg"); fi
      done < <(get_task_extra_args "$idx")
      CLI_ARGS+=("$prompt")
      ;;
    codex)
      CLI_ARGS+=("exec")
      if [ "$mode" = "Resume" ]; then
        CLI_ARGS+=("resume" "$session_id")
      fi
      CLI_ARGS+=("--json" "-C" "$project_path")
      if [ -n "$model" ]; then
        CLI_ARGS+=("-m" "$model")
      fi
      if [ -n "$effort" ]; then
        CLI_ARGS+=("-c" "model_reasoning_effort=$effort")
      fi
      while IFS= read -r arg; do
        if [ -n "$arg" ]; then CLI_ARGS+=("$arg"); fi
      done < <(get_task_extra_args "$idx")
      CLI_ARGS+=("$prompt")
      ;;
    gemini)
      if [ -n "$effort" ]; then
        echo "Note: 'effort' is not supported by gemini and is ignored for task '$(task_field "$idx" "name")'."
      fi
      if [ "$mode" = "Resume" ] && [ -n "$session_id" ]; then
        CLI_ARGS+=("--resume" "$session_id")
      fi
      CLI_ARGS+=("-p" "$prompt" "--output-format" "json")
      if [ -n "$model" ]; then
        CLI_ARGS+=("-m" "$model")
      fi
      while IFS= read -r arg; do
        if [ -n "$arg" ]; then CLI_ARGS+=("$arg"); fi
      done < <(get_task_extra_args "$idx")
      ;;
  esac
}

parse_cli_output() {
  local cli="$1" output="$2" exit_code="$3"
  R_OK=1
  R_IS_LIMIT=0
  R_TEXT=""
  R_SESSION_ID=""
  R_ERROR_TEXT=""

  local limit_regex=""
  case "$cli" in
    claude) limit_regex='(?i)(you'\''ve hit your .{0,40}limit|usage limit)' ;;
    codex)  limit_regex='(?i)(usage limit|rate limit|too many requests|try again (at|in)|quota)' ;;
    gemini) limit_regex='(?i)(quota exceeded|resource_exhausted|ratelimitexceeded|model_capacity_exhausted|no capacity available|daily quota|usage limit reached|rate limit|429|too many requests)' ;;
  esac

  case "$cli" in
    claude)
      local clean_json
      clean_json=$(printf '%s' "$output" | sed -n '/^{/,$p')
      if [ -z "$clean_json" ] || ! printf '%s' "$clean_json" | jq empty >/dev/null 2>&1; then
        R_OK=0
        if printf '%s' "$output" | grep -qiE "$limit_regex" >/dev/null 2>&1; then
          R_IS_LIMIT=1
        fi
        R_TEXT="$output"
        R_ERROR_TEXT="$output"
        return
      fi

      R_TEXT=$(printf '%s' "$clean_json" | jq -r '.result // empty')
      R_SESSION_ID=$(printf '%s' "$clean_json" | jq -r '.session_id // empty')
      local is_error
      is_error=$(printf '%s' "$clean_json" | jq -r '.is_error // empty')

      if [ "$is_error" = "true" ] || [ "$exit_code" -ne 0 ]; then
        R_OK=0
        if printf '%s' "$R_TEXT" | grep -qiE "$limit_regex" >/dev/null 2>&1; then
          R_IS_LIMIT=1
        fi
        R_ERROR_TEXT="$R_TEXT"
      fi
      ;;
    codex)
      local clean_jsonl
      clean_jsonl=$(printf '%s' "$output" | grep -E '^\{')
      if [ -z "$clean_jsonl" ] || ! printf '%s' "$clean_jsonl" | jq -s empty >/dev/null 2>&1; then
        R_OK=0
        if printf '%s' "$output" | grep -qiE "$limit_regex" >/dev/null 2>&1; then
          R_IS_LIMIT=1
        fi
        R_TEXT="$output"
        R_ERROR_TEXT="$output"
        return
      fi

      R_SESSION_ID=$(printf '%s' "$clean_jsonl" | jq -rs '[.[] | select(.type=="thread.started")] | last | .thread_id // empty')
      R_TEXT=$(printf '%s' "$clean_jsonl" | jq -rs '[.[] | select(.type=="item.completed" and .item.type=="agent_message")] | last | .item.text // empty')
      R_ERROR_TEXT=$(printf '%s' "$clean_jsonl" | jq -rs '[.[] | select(.type=="error")] | last | .message // empty')
      local turn_failed_err
      turn_failed_err=$(printf '%s' "$clean_jsonl" | jq -rs '[.[] | select(.type=="turn.failed")] | last | .error.message // empty')
      if [ -n "$turn_failed_err" ]; then
        R_ERROR_TEXT="$turn_failed_err"
      fi

      if [ -n "$R_ERROR_TEXT" ] || [ "$exit_code" -ne 0 ]; then
        R_OK=0
        if printf '%s %s' "$R_ERROR_TEXT" "$output" | grep -qiE "$limit_regex" >/dev/null 2>&1; then
          R_IS_LIMIT=1
        fi
      fi
      ;;
    gemini)
      local clean_json
      clean_json=$(printf '%s' "$output" | sed -n '/^{/,$p')
      if [ -z "$clean_json" ] || ! printf '%s' "$clean_json" | jq empty >/dev/null 2>&1; then
        R_OK=0
        if printf '%s' "$output" | grep -qiE "$limit_regex" >/dev/null 2>&1; then
          R_IS_LIMIT=1
        fi
        R_TEXT="$output"
        R_ERROR_TEXT="$output"
        return
      fi

      R_SESSION_ID=$(printf '%s' "$clean_json" | jq -r '.session_id // empty')
      local error_msg error_code
      error_msg=$(printf '%s' "$clean_json" | jq -r '.error.message // empty')
      error_code=$(printf '%s' "$clean_json" | jq -r '.error.code // empty')

      if [ -n "$error_msg" ] && [ "$error_msg" != "null" ]; then
        R_OK=0
        R_TEXT="$error_msg"
        R_ERROR_TEXT="$error_msg"
        if printf '%s' "$error_msg" | grep -qiE "$limit_regex" >/dev/null 2>&1 || [ "$error_code" = "429" ]; then
          R_IS_LIMIT=1
        fi
      else
        R_TEXT=$(printf '%s' "$clean_json" | jq -r '.response // empty')
        if [ "$exit_code" -ne 0 ]; then
          R_OK=0
          R_ERROR_TEXT="$output"
        fi
      fi
      ;;
  esac
}

get_marker_status() {
  local text="$1"
  if [ -z "$text" ]; then
    M_STATUS="None"
    M_REASON=""
    return
  fi
  local last
  last=$(printf '%s' "$text" | awk 'NF{last=$0} END{print last}')
  last=$(printf '%s' "$last" | awk '{$1=$1;print}')

  if [ "$last" = "$TASK_COMPLETE_MARKER" ]; then
    M_STATUS="Done"
    M_REASON=""
  elif [[ "$last" == "$TASK_BLOCKED_MARKER"* ]]; then
    M_STATUS="Blocked"
    M_REASON=$(printf '%s' "$last" | sed "s/^$(printf '%s' "$TASK_BLOCKED_MARKER" | sed 's/[^^$*.[\]]/\\&/g')//")
    M_REASON=$(printf '%s' "$M_REASON" | awk '{$1=$1;print}')
  else
    M_STATUS="None"
    M_REASON=""
  fi
}

invoke_cli_task_run() {
  local idx="$1" mode="$2" session_id="$3"
  local name cli project_path prompt
  name=$(task_field "$idx" "name")
  cli=$(task_field "$idx" "cli" | tr '[:upper:]' '[:lower:]')
  project_path=$(task_field "$idx" "projectPath")
  project_path="${project_path//\\//}"
  prompt=$(task_field "$idx" "prompt")

  local output_file_path
  output_file_path=$(get_task_output_file_path "$idx")

  if [ "$mode" = "New" ] && [ -f "$output_file_path" ]; then
    rm -f "$output_file_path"
  fi

  local prompt_with_marker
  if [ "$mode" = "New" ]; then
    prompt_with_marker=$(printf '%s\n\nIMPORTANT AUTOMATION INSTRUCTIONS:\n1. When and only when this task is fully complete, end your final response with exactly this as the very last line:\n%s\n2. If and only if you cannot complete this task, end your final response with this as the very last line instead, plus a one-line reason:\n%s <one-line reason>\n' "$prompt" "$TASK_COMPLETE_MARKER" "$TASK_BLOCKED_MARKER")
  else
    if [ "$cli" = "gemini" ]; then
      prompt_with_marker=$(printf 'You were interrupted partway through the following task. Inspect the current state of the working directory to see what is already done. Do not redo completed work; continue from where things stand.\n\nOriginal task:\n%s\n\nIMPORTANT AUTOMATION INSTRUCTIONS:\n1. When and only when this task is fully complete, end your final response with exactly this as the very last line:\n%s\n2. If and only if you cannot complete this task, end your final response with this as the very last line instead, plus a one-line reason:\n%s <one-line reason>\n' "$prompt" "$TASK_COMPLETE_MARKER" "$TASK_BLOCKED_MARKER")
    else
      prompt_with_marker=$(printf 'Continue the previous task in this same session from where you stopped. Do not restart from scratch.\n\nIMPORTANT AUTOMATION INSTRUCTIONS:\n1. When and only when this task is fully complete, end your final response with exactly this as the very last line:\n%s\n2. If and only if you cannot complete this task, end your final response with this as the very last line instead, plus a one-line reason:\n%s <one-line reason>\n' "$TASK_COMPLETE_MARKER" "$TASK_BLOCKED_MARKER")
    fi
  fi

  build_cli_args "$idx" "$mode" "$session_id" "$prompt_with_marker"

  echo "==== $mode run for task $((idx + 1)): $name [$cli] ===="
  echo "Command: $cli ${CLI_ARGS[@]}"

  if [ "$DRY_RUN" -eq 1 ]; then
    R_OK=1
    R_IS_LIMIT=0
    R_TEXT="[dry-run]
$TASK_COMPLETE_MARKER"
    R_SESSION_ID="$session_id"
    R_ERROR_TEXT=""
    return
  fi

  local output_text exit_code
  local tmp_out
  tmp_out=$(mktemp)
  ( cd "$project_path" && "$cli" "${CLI_ARGS[@]}" ) > "$tmp_out" 2>&1
  exit_code=$?
  
  output_text=$(cat "$tmp_out")
  rm -f "$tmp_out"

  if [ -n "$output_text" ]; then
    printf '%s\n' "$output_text" >> "$output_file_path"
    printf '%s\n' "$output_text"
  fi

  parse_cli_output "$cli" "$output_text" "$exit_code"
}

initialize_runner_state() {
  mkdir -p "$RUNNER_STATE_PATH"
  mkdir -p "$SESSION_STATE_PATH"
  mkdir -p "$OUTPUT_STATE_PATH"
  mkdir -p "$STATUS_STATE_PATH"
}

# MAIN EXECUTION
read_queue_config

if [ "$VALIDATE_ONLY" -eq 1 ]; then
  check_cli_binaries
  echo "Config OK: $QUEUE_PATH"
  echo "Tasks: $TASK_COUNT"
  i=0
  while [ "$i" -lt "$TASK_COUNT" ]; do
    echo " - [$(task_field "$i" "cli")] $(task_field "$i" "name")  ($(task_field "$i" "projectPath"))"
    i=$((i + 1))
  done
  exit 0
fi

initialize_runner_state

# Start logging
# Since bash does not have Start-Transcript, we can redirect all script output to log file in addition to stdout
# using tee. To keep code clean and self-contained, we redirect stdout/stderr to tee at the bottom or inside a block.

run_queue() {
  write_step "Script started"
  echo "Started at: $(date)"
  echo "Queue path: $QUEUE_PATH"
  echo "Runner state path: $RUNNER_STATE_PATH"
  echo "Log path: $LOG_PATH"
  echo "Usage path: $USAGE_PATH"
  echo "Prompt count: $TASK_COUNT"

  write_step "Current folder"
  pwd

  local i=0 taskNumber runCount errorRetryCount mustWaitForFreshSession=0
  local savedSessionId sessionId result_ok result_is_limit result_text result_session_id result_error_text
  
  while [ "$i" -lt "$TASK_COUNT" ]; do
    taskNumber=$((i + 1))
    
    if test_task_already_done "$i"; then
      write_step "Skipping task $taskNumber of $TASK_COUNT: $(task_field "$i" "name")"
      echo "Task is already marked as done."
      i=$((i + 1))
      continue
    fi

    runCount=0
    errorRetryCount=0
    mustWaitForFreshSession=0

    while true; do
      runCount=$((runCount + 1))
      if [ "$runCount" -gt "$MAX_RUNS_PER_TASK" ]; then
        echo "ERROR: Task $taskNumber exceeded maxRunsPerTask=$MAX_RUNS_PER_TASK" >&2
        exit 1
      fi

      local task_cli
      task_cli=$(task_field "$i" "cli" | tr '[:upper:]' '[:lower:]')
      if [ "$task_cli" = "claude" ] && [ "$DRY_RUN" -eq 0 ]; then
        wait_until_claude_ready "$mustWaitForFreshSession"
      fi

      savedSessionId=$(get_saved_task_session_id "$i")

      if [ -z "$savedSessionId" ]; then
        sessionId=""
        if [ "$task_cli" = "claude" ]; then
          sessionId=$(new_task_session_id "$i")
        fi
        invoke_cli_task_run "$i" "New" "$sessionId"
      else
        invoke_cli_task_run "$i" "Resume" "$savedSessionId"
      fi

      # Read results from globals set by invoke_cli_task_run
      result_ok="$R_OK"
      result_is_limit="$R_IS_LIMIT"
      result_text="$R_TEXT"
      result_session_id="$R_SESSION_ID"
      result_error_text="$R_ERROR_TEXT"

      if [ -n "$result_session_id" ]; then
        printf '%s' "$result_session_id" > "$(get_task_session_file_path "$i")"
      fi

      get_marker_status "$result_text"
      if [ "$M_STATUS" = "Done" ]; then
        save_task_done_marker "$i"
        write_step "Task $taskNumber completed"
        break
      fi
      if [ "$M_STATUS" = "Blocked" ]; then
        save_task_failed_marker "$i" "$M_REASON"
        write_step "Task $taskNumber reported itself BLOCKED: $M_REASON"
        if [ "$STOP_ON_ERROR" = "true" ]; then
          echo "ERROR: Task $taskNumber is blocked: $M_REASON" >&2
          exit 1
        fi
        echo "stopOnError=false; moving to the next task."
        break
      fi

      # Gemini-only: --resume rejection fallback
      if [ "$task_cli" = "gemini" ] && [ "$result_ok" -eq 0 ] && \
         printf '%s' "$result_error_text" | grep -qiE 'unknown option.*resume|not supported in non-interactive|unexpected argument|too many arguments|invalid.*resume'; then
        rm -f "$(get_task_session_file_path "$i")"
        write_step "Task $taskNumber: installed gemini rejects --resume; retrying with continuation prompt only"
        continue
      fi

      if [ "$result_is_limit" -eq 1 ]; then
        mustWaitForFreshSession=1
        write_step "Task $taskNumber paused by a usage limit on $task_cli"
        wait_for_limit_reset "$task_cli" "$result_error_text" "$LIMIT_WAIT_MINUTES"
        continue
      fi

      if [ "$result_ok" -eq 0 ]; then
        errorRetryCount=$((errorRetryCount + 1))
        write_step "Task $taskNumber errored: $result_error_text"
        if [ "$errorRetryCount" -le "$MAX_RETRIES_ON_ERROR" ]; then
          echo "Retry $errorRetryCount of $MAX_RETRIES_ON_ERROR; resuming the same session."
          continue
        fi
        if [ "$STOP_ON_ERROR" = "true" ]; then
          echo "ERROR: Task $taskNumber failed after $MAX_RETRIES_ON_ERROR retries: $result_error_text" >&2
          exit 1
        fi
        echo "stopOnError=false; abandoning this task and moving to the next one."
        break
      fi

      mustWaitForFreshSession=0
      write_step "Task $taskNumber is not complete yet; resuming the same session."
    done

    i=$((i + 1))
  done

  write_step "Script completed"
  echo "All queue tasks are finished."
  echo "PC will stay on."
  echo "Finished at: $(date)"
  echo "Log saved to: $LOG_PATH"
  echo "Last Claude usage saved to: $USAGE_PATH"
}

# Run the queue function and write log
run_queue 2>&1 | tee -a "$LOG_PATH"
