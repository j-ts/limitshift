#!/usr/bin/env bash
# LimitShift — runs queued prompts against claude / codex / gemini CLIs,
# waiting out usage limits and resuming sessions. macOS (bash 3.2+) and Linux.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUEUE_PATH=""
QUEUE_PATH_EXPLICIT=0
VALIDATE_ONLY=0
DRY_RUN=0
SHOW_RAW=0

TASK_COMPLETE_MARKER="[[TASK_COMPLETE]]"
TASK_BLOCKED_MARKER="[[TASK_BLOCKED]]"

usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  --queue <path>       Path to queue JSON file (default: limitshift-queue.json next to script)"
  echo "  --validate-only      Validate configuration syntax, paths, and binaries, then exit"
  echo "  --dry-run            Simulate execution by printing commands without running them"
  echo "  --show-raw           Print the raw CLI JSON to the console (default: only the response text)"
  echo "  -h, --help           Show this help message"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --queue) QUEUE_PATH="$2"; QUEUE_PATH_EXPLICIT=1; shift 2 ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --show-raw) SHOW_RAW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# Task 5.2: default queue file is limitshift-queue.json; the old ai-run-queue.json is still
# accepted as a fallback for one release. Only applies when no explicit --queue is given: look for
# the new name first, then the old one (warning if the legacy name is used). If neither exists,
# default to the new name so the "not found / copy the example" message uses the current filename.
if [ "$QUEUE_PATH_EXPLICIT" -eq 0 ]; then
  if [ -f "$SCRIPT_DIR/limitshift-queue.json" ]; then
    QUEUE_PATH="$SCRIPT_DIR/limitshift-queue.json"
  elif [ -f "$SCRIPT_DIR/ai-run-queue.json" ]; then
    QUEUE_PATH="$SCRIPT_DIR/ai-run-queue.json"
    echo "Using legacy queue filename ai-run-queue.json; rename to limitshift-queue.json" >&2
  else
    QUEUE_PATH="$SCRIPT_DIR/limitshift-queue.json"
  fi
fi

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
  echo "Copy limitshift-queue.example.json to limitshift-queue.json and fill in your tasks." >&2
  exit 2
fi

QUEUE_DIR="$(cd "$(dirname "$QUEUE_PATH")" && pwd)"
QUEUE_FILE_NAME="$(basename "$QUEUE_PATH")"
QUEUE_PATH="$QUEUE_DIR/$QUEUE_FILE_NAME"
RUNNER_NAME="${QUEUE_FILE_NAME%.*}"
# Task 5.3: state folder is now .limitshift-<name>; the old .ai-runner-<name> folder is migrated
# (renamed) automatically on startup when it exists and the new one does not.
RUNNER_STATE_PATH="$QUEUE_DIR/.limitshift-$RUNNER_NAME"
LEGACY_RUNNER_STATE_PATH="$QUEUE_DIR/.ai-runner-$RUNNER_NAME"
SESSION_STATE_PATH="$RUNNER_STATE_PATH/sessions"
OUTPUT_STATE_PATH="$RUNNER_STATE_PATH/outputs"
STATUS_STATE_PATH="$RUNNER_STATE_PATH/status"
LOG_PATH="$RUNNER_STATE_PATH/limitshift-log.txt"
USAGE_PATH="$RUNNER_STATE_PATH/claude-usage-last.txt"
RUNS_CSV_PATH="$RUNNER_STATE_PATH/runs.csv"
STATE_README_PATH="$RUNNER_STATE_PATH/_README.txt"
RUNS_CSV_HEADER="timestamp,task,run,mode,exit,status"

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

# Task 6: emit the task's model list, one model per line. A single string is a 1-element list; an
# array is that list in order; absent/null emits nothing. Mirrors limitshift.ps1's Models parsing.
get_task_models() {
  local idx="$1"
  jq -r ".tasks[$idx].model | if type==\"array\" then .[] elif type==\"string\" then . else empty end" "$QUEUE_PATH" | tr -d '\r'
}

# Task 6: the task's model list joined by a single space — the canonical model contribution to the
# fingerprint. A single-string model joins to exactly that string (stable vs the pre-Task-6 form).
get_task_models_joined() {
  local idx="$1" joined="" first=1 m
  while IFS= read -r m; do
    if [ "$first" -eq 1 ]; then joined="$m"; first=0; else joined="$joined $m"; fi
  done < <(get_task_models "$idx")
  printf '%s' "$joined"
}

# Resolve completionCheck for a task: per-task override beats the global COMPLETION_CHECK,
# which itself defaults to true. Echoes "true" or "false". (false // empty in jq would lose a
# legitimate false, so the per-task value is read explicitly with has().)
task_completion_check() {
  local idx="$1" per_task
  per_task=$(jq -r ".tasks[$idx] | if has(\"completionCheck\") then .completionCheck else \"\" end" "$QUEUE_PATH" | tr -d '\r')
  if [ "$per_task" = "true" ] || [ "$per_task" = "false" ]; then
    printf '%s' "$per_task"
  elif [ "${COMPLETION_CHECK:-true}" = "false" ]; then
    printf 'false'
  else
    printf 'true'
  fi
}

get_codex_resume_extra_args() {
  local idx="$1"
  local raw_args=()
  local arg

  while IFS= read -r arg; do
    if [ -n "$arg" ]; then
      raw_args+=("$arg")
    fi
  done < <(get_task_extra_args "$idx")

  CODEX_RESUME_EXTRA_ARGS=()
  local i=0
  while [ "$i" -lt "${#raw_args[@]}" ]; do
    arg="${raw_args[$i]}"
    case "$arg" in
      --sandbox|-s|--cd|-C|--add-dir)
        i=$((i + 2))
        continue
        ;;
      --sandbox=*|--cd=*|--add-dir=*|-C=*)
        i=$((i + 1))
        continue
        ;;
    esac

    CODEX_RESUME_EXTRA_ARGS+=("$arg")
    i=$((i + 1))
  done
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
  # Note: jq's `// true` would turn a legitimate `false` into `true` (it treats false as empty),
  # so completionCheck is read with has() to preserve an explicit false.
  COMPLETION_CHECK=$(jq -r '(.settings // {}) | if has("completionCheck") then .completionCheck else true end' "$QUEUE_PATH" | tr -d '\r')
  MAX_STALLS=$(jq -r '.settings.maxStalls // 2' "$QUEUE_PATH" | tr -d '\r')

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
    # Task 6: model may be a string or a non-empty array of strings. Reject an empty array and any
    # non-string element. (A string or absent value is fine.)
    local model_type model_bad
    model_type=$(jq -r ".tasks[$i].model | type" "$QUEUE_PATH" | tr -d '\r')
    if [ "$model_type" = "array" ]; then
      if [ "$(jq -r ".tasks[$i].model | length" "$QUEUE_PATH" | tr -d '\r')" = "0" ]; then
        echo "Task $n model array must not be empty. Use a single string, or list one or more model names in preference order." >&2
        exit 2
      fi
      model_bad=$(jq -r ".tasks[$i].model | map(select(type != \"string\")) | length" "$QUEUE_PATH" | tr -d '\r')
      if [ "$model_bad" != "0" ]; then
        echo "Task $n model array must contain only strings (got a non-string element)." >&2
        exit 2
      fi
    fi

    # Task 6b: enforce the SAME per-CLI effort rules the schema declares (editor-only), so a
    # misconfigured queue fails at validation (exit 2) instead of mid-run. task_field maps both an
    # absent field and JSON null/"" to "" (via `// empty` + tr), so a non-empty effort is a real value.
    local effort
    effort=$(task_field "$i" "effort")
    if [ -n "$effort" ]; then
      case "$cli" in
        gemini)
          echo "Task $n: gemini has no effort flag; set \"effort\": null (use thinkingLevel/thinkingBudget via gemini settings instead)." >&2
          exit 2
          ;;
        claude)
          if [ "$effort" = "ultracode" ]; then
            echo "Task $n: 'ultracode' is only available from the interactive /effort menu, not the --effort flag. Use low|medium|high|xhigh|max." >&2
            exit 2
          fi
          case "$effort" in
            low|medium|high|xhigh|max) ;;
            *) echo "Task $n: claude effort must be one of low, medium, high, xhigh, max (or null)." >&2; exit 2 ;;
          esac
          # Haiku 4.5 supports no effort. Model may be a list (Task 6): reject if ANY model matches haiku.
          local haiku_match
          haiku_match=$(get_task_models "$i" | grep -ic 'haiku')
          if [ "$haiku_match" -gt 0 ]; then
            echo "Task $n: claude model haiku does not support effort; set \"effort\": null." >&2
            exit 2
          fi
          ;;
        codex)
          case "$effort" in
            minimal|low|medium|high|xhigh) ;;
            *) echo "Task $n: codex effort must be one of minimal, low, medium, high, xhigh (or null). 'none' is plan-mode only." >&2; exit 2 ;;
          esac
          ;;
      esac
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
  local idx="$1"
  printf 'task-%02d' $((idx + 1))
}

# Task 4: slugify a task name for the output filename. Keep the original case, replace any run
# of characters outside [A-Za-z0-9._-] with a single dash, trim leading/trailing dashes, and cap
# the length at 40. Mirrors limitshift.ps1 Get-TaskSlug byte-for-byte.
get_task_slug() {
  local name="$1" slug
  slug=$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
  slug=${slug:0:40}
  slug=$(printf '%s' "$slug" | sed -E 's/-+$//')
  if [ -z "$slug" ]; then
    slug="task"
  fi
  printf '%s' "$slug"
}

# Task 4: pick whichever SHA-256 tool exists (sha256sum on Linux/Git-Bash, shasum -a 256 on macOS).
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# Task 4 canonical task fingerprint.
# PURPOSE: detect when a task's definition changed since it was last marked done, so the task
#   re-runs. The fingerprint is consistent and stable WITHIN this runner on one machine. It is
#   NOT intended to match limitshift.ps1's fingerprint or be portable across machines: this hashes the
#   raw JSON projectPath value while limitshift.ps1 hashes a normalized absolute, OS-specific native
#   path, so the two runners produce different hashes. Within-runner self-consistency is the only
#   requirement. Keep the algorithm (fields, order, separator, lowercase hex) exactly as below.
#   CANONICAL FORMAT:
#   fields, in this exact order:  name, cli, projectPath, model, effort, prompt, extraArgs-joined
#   extraArgs-joined = the args joined by a single space (" ").
#   model (Task 6) = the task's model LIST joined by a single space (" "). A single-string model is
#     a 1-element list, so it joins to exactly that string — identical to the pre-Task-6 fingerprint
#     of a plain-string model. limitshift.ps1 joins the model list the same way (space).
#   empty model/effort contribute an empty string.
#   joined with the ASCII unit separator U+001F (printf '\037'), unlikely to appear in any value.
#   SHA-256 of the UTF-8 bytes of that string, rendered as lowercase hex.
get_task_fingerprint() {
  local idx="$1"
  local name cli project_path model effort prompt extra_joined us first arg
  name=$(task_field "$idx" "name")
  # cli is lowercased to match limitshift.ps1, which stores the cli already lowercased.
  cli=$(task_field "$idx" "cli" | tr '[:upper:]' '[:lower:]')
  project_path=$(task_field "$idx" "projectPath")
  model=$(get_task_models_joined "$idx")
  effort=$(task_field "$idx" "effort")
  prompt=$(task_field "$idx" "prompt")

  extra_joined=""
  first=1
  while IFS= read -r arg; do
    if [ "$first" -eq 1 ]; then
      extra_joined="$arg"
      first=0
    else
      extra_joined="$extra_joined $arg"
    fi
  done < <(get_task_extra_args "$idx")

  us=$(printf '\037')
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s' \
    "$name" "$us" "$cli" "$us" "$project_path" "$us" "$model" "$us" "$effort" "$us" "$prompt" "$us" "$extra_joined" \
    | sha256_hex
}

# Task 4: minimal RFC-4180-style CSV field quoting. Wrap in double quotes (doubling embedded
# quotes) only when the value contains a comma, a quote, or a newline. Mirrors ConvertTo-CsvField.
csv_field() {
  local value="$1"
  case "$value" in
    *,*|*\"*|*$'\n'*)
      value=${value//\"/\"\"}
      printf '"%s"' "$value"
      ;;
    *)
      printf '%s' "$value"
      ;;
  esac
}

get_task_session_file_path() {
  local idx="$1" key
  key=$(get_task_key "$idx")
  printf '%s' "$SESSION_STATE_PATH/$key.session"
}

# Task 6: per-task model-rotation index file, persisted so a restart keeps its place in the list.
get_task_model_index_file_path() {
  local idx="$1" key
  key=$(get_task_key "$idx")
  printf '%s' "$SESSION_STATE_PATH/$key-model-index.txt"
}

get_saved_task_model_index() {
  local path raw
  path=$(get_task_model_index_file_path "$1")
  if [ -f "$path" ]; then
    raw=$(cat "$path" | tr -d '\r' | awk '{$1=$1;print}')
    case "$raw" in
      ''|*[!0-9]*) printf '0' ;;
      *) printf '%s' "$raw" ;;
    esac
  else
    printf '0'
  fi
}

save_task_model_index() {
  local path
  path=$(get_task_model_index_file_path "$1")
  printf '%s' "$2" > "$path"
}

get_task_output_file_path() {
  local idx="$1" key slug
  key=$(get_task_key "$idx")
  # Task 4: include a slug of the task name, e.g. task-03-fix-the-thing-output.txt.
  # Identical pattern to limitshift.ps1 Get-TaskOutputFilePath.
  slug=$(get_task_slug "$(task_field "$idx" "name")")
  printf '%s' "$OUTPUT_STATE_PATH/$key-$slug-output.txt"
}

get_task_done_file_path() {
  local idx="$1" key
  key=$(get_task_key "$idx")
  printf '%s' "$STATUS_STATE_PATH/$key.done"
}

get_task_failed_file_path() {
  local idx="$1" key
  key=$(get_task_key "$idx")
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
  # Task 4: the .done file stores two lines — an ISO timestamp then the task fingerprint.
  local path fp
  path=$(get_task_done_file_path "$1")
  fp=$(get_task_fingerprint "$1")
  printf '%s\n%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$fp" > "$path"
}

# Task 4: read the fingerprint line (line 2) out of a .done file. Empty when missing or older.
get_saved_done_fingerprint() {
  local path
  path=$(get_task_done_file_path "$1")
  if [ -f "$path" ]; then
    sed -n '2p' "$path" | tr -d '\r' | awk '{$1=$1;print}'
  else
    printf ''
  fi
}

save_task_failed_marker() {
  # Task 4: store timestamp<TAB>fingerprint<TAB>reason so the reason text is preserved verbatim.
  local path reason fp
  path=$(get_task_failed_file_path "$1")
  reason="$2"
  fp=$(get_task_fingerprint "$1")
  printf '%s\t%s\t%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$fp" "$reason" > "$path"
}

build_cli_args() {
  local idx="$1" mode="$2" session_id="$3" model_override="${4:-}"
  local cli model effort project_path
  cli=$(task_field "$idx" "cli" | tr '[:upper:]' '[:lower:]')
  # Task 6: the -m/--model value is the current rotation model (Models[currentModelIndex]) when the
  # caller passes one; otherwise fall back to the first model in the list.
  if [ -n "$model_override" ]; then
    model="$model_override"
  else
    model=$(get_task_models "$idx" | sed -n '1p')
  fi
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
      ;;
    codex)
      CLI_ARGS+=("exec")
      if [ "$mode" = "Resume" ]; then
        CLI_ARGS+=("resume" "$session_id")
        get_codex_resume_extra_args "$idx"
      fi
      CLI_ARGS+=("--json")
      if [ -n "$model" ]; then
        CLI_ARGS+=("-m" "$model")
      fi
      if [ -n "$effort" ]; then
        CLI_ARGS+=("-c" "model_reasoning_effort=$effort")
      fi
      if [ "$mode" = "Resume" ]; then
        for arg in "${CODEX_RESUME_EXTRA_ARGS[@]}"; do
          CLI_ARGS+=("$arg")
        done
      else
        while IFS= read -r arg; do
          if [ -n "$arg" ]; then CLI_ARGS+=("$arg"); fi
        done < <(get_task_extra_args "$idx")
      fi
      ;;
    gemini)
      # gemini never carries effort here: read_queue_config rejects gemini+effort at validation (Task 6b).
      if [ "$mode" = "Resume" ] && [ -n "$session_id" ]; then
        CLI_ARGS+=("--resume" "$session_id")
      fi
      CLI_ARGS+=("--output-format" "json")
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
    claude) limit_regex='(you'\''ve hit your .{0,40}limit|usage limit)' ;;
    codex)  limit_regex='(usage limit|rate limit|too many requests|try again (at|in)|quota)' ;;
    gemini) limit_regex='(quota exceeded|resource_exhausted|ratelimitexceeded|model_capacity_exhausted|no capacity available|daily quota|usage limit reached|rate limit|429|too many requests)' ;;
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

  # Loosened detection (Task 2.2): the marker only has to be CONTAINED in the last
  # non-empty line. Blocked is checked first so a line mentioning both is treated as blocked.
  # The markers contain glob-special characters ([[ ]]), so quoted case patterns are used to
  # match them literally; the reason is extracted with awk index/substr (not parameter
  # expansion, which would treat the marker as a glob pattern).
  case "$last" in
    *"$TASK_BLOCKED_MARKER"*)
      M_STATUS="Blocked"
      M_REASON=$(awk -v line="$last" -v marker="$TASK_BLOCKED_MARKER" 'BEGIN{p=index(line,marker); r=substr(line,p+length(marker)); gsub(/^[[:space:]]+|[[:space:]]+$/,"",r); print r}')
      ;;
    *"$TASK_COMPLETE_MARKER"*)
      M_STATUS="Done"
      M_REASON=""
      ;;
    *)
      M_STATUS="None"
      M_REASON=""
      ;;
  esac
}

invoke_cli_task_run() {
  local idx="$1" mode="$2" session_id="$3" model_override="${4:-}"
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

  local completion_check
  completion_check=$(task_completion_check "$idx")

  # The marker instruction block (Task 2.3 wording). Empty in simple mode (completionCheck:false).
  local marker_block=""
  if [ "$completion_check" = "true" ]; then
    marker_block=$(printf '\n\nIMPORTANT AUTOMATION INSTRUCTIONS:\n1. When and only when this task is fully complete, end your final response with %s as (or at the end of) the very last line:\n%s\n2. If and only if you cannot complete this task, end your final response with this as (or at the end of) the very last line instead, plus a one-line reason:\n%s <one-line reason>' "$TASK_COMPLETE_MARKER" "$TASK_COMPLETE_MARKER" "$TASK_BLOCKED_MARKER")
  fi

  local prompt_with_marker
  if [ "$mode" = "New" ]; then
    if [ "$completion_check" = "true" ]; then
      prompt_with_marker=$(printf '%s%s\n' "$prompt" "$marker_block")
    else
      # Simple mode: send the prompt verbatim, nothing appended.
      prompt_with_marker=$(printf '%s' "$prompt")
    fi
  else
    # Task 3 (Bug C): one unified resume template for all three CLIs. The resume prompt now
    # repeats the original task verbatim so a thin session and slash commands (e.g. /goal)
    # survive the resume instead of leaving the agent with nothing to continue.
    prompt_with_marker=$(printf 'Continue the previous task in this same session from where you stopped. Do not restart from scratch.\nIf the session has no prior progress, start the task now.\n\nOriginal task (for reference — do not redo finished work):\n%s%s\n' "$prompt" "$marker_block")
  fi

  build_cli_args "$idx" "$mode" "$session_id" "$model_override"

  echo "==== $mode run for task $((idx + 1)): $name [$cli] ===="
  echo "Command: $cli ${CLI_ARGS[@]}"
  echo "(prompt sent via stdin; full text in the output file)"

  if [ "$DRY_RUN" -eq 1 ]; then
    R_OK=1
    R_IS_LIMIT=0
    R_TEXT="[dry-run]"
    R_SESSION_ID=""
    R_ERROR_TEXT=""
    return
  fi

  # Log the full prompt before the run; the displayed command line no longer contains it.
  printf '%s\n\n' "$prompt_with_marker" >> "$output_file_path"

  local output_text exit_code
  local tmp_out
  tmp_out=$(mktemp)
  ( cd "$project_path" && printf '%s' "$prompt_with_marker" | "$cli" "${CLI_ARGS[@]}" ) > "$tmp_out" 2>&1
  exit_code=$?
  
  output_text=$(cat "$tmp_out")
  rm -f "$tmp_out"

  # The FULL raw output always goes to the per-task output file.
  if [ -n "$output_text" ]; then
    printf '%s\n' "$output_text" >> "$output_file_path"
  fi

  # Parse first (Task 2b), then show only the agent's response (or the error) on the console.
  parse_cli_output "$cli" "$output_text" "$exit_code"

  local console_text=""
  if [ "$SHOW_RAW" -eq 1 ]; then
    console_text="$output_text"
  elif [ "$R_OK" -eq 1 ] && [ -n "$R_TEXT" ]; then
    console_text="$R_TEXT"
  elif [ "$R_OK" -eq 0 ] && [ -n "$R_ERROR_TEXT" ]; then
    console_text="$R_ERROR_TEXT"
  elif [ "$R_OK" -eq 0 ] && [ -n "$R_TEXT" ]; then
    console_text="$R_TEXT"
  else
    console_text="$output_text"
  fi

  if [ -n "$console_text" ]; then
    echo "--- agent response ---"
    printf '%s\n' "$console_text"
  fi
}

initialize_runner_state() {
  # Task 5.3: migrate an old-named state folder (.ai-runner-<name>) to the new name
  # (.limitshift-<name>) automatically when the old one exists and the new one does not.
  if [ -d "$LEGACY_RUNNER_STATE_PATH" ] && [ ! -d "$RUNNER_STATE_PATH" ]; then
    mv "$LEGACY_RUNNER_STATE_PATH" "$RUNNER_STATE_PATH"
    echo "Migrated state folder .ai-runner-$RUNNER_NAME -> .limitshift-$RUNNER_NAME"
  fi

  mkdir -p "$RUNNER_STATE_PATH"
  mkdir -p "$SESSION_STATE_PATH"
  mkdir -p "$OUTPUT_STATE_PATH"
  mkdir -p "$STATUS_STATE_PATH"

  # Task 4: self-explaining README (overwritten every init) and a runs.csv with its header.
  write_state_readme
  initialize_runs_csv
}

write_state_readme() {
  cat > "$STATE_README_PATH" <<'EOF'
This folder holds LimitShift's saved state for one queue file.
It is created and maintained automatically. You can delete it at any time.

What is in here:
  sessions/   Saved CLI session / thread ids so a task can resume the SAME conversation.
  outputs/    The full raw output of every run (one file per task: task-NN-<slug>-output.txt).
  status/     Per-task markers: task-NN.done (finished) and task-NN.failed (blocked/failed).
  runs.csv    One line per CLI run: timestamp, task, run, mode (New/Resume), exit, status.
  limitshift-log.txt    The full runner transcript.
  claude-usage-last.txt The last Claude /usage report.

Re-running:
  Delete this whole folder to start completely from scratch.
  Delete status/task-NN.done to force ONE task to run again.
  Editing a task's prompt, cli, projectPath, model, effort, or extraArgs now AUTO-INVALIDATES
  its done marker: the runner notices the change and re-runs that task with a fresh session.
EOF
}

initialize_runs_csv() {
  if [ ! -f "$RUNS_CSV_PATH" ]; then
    printf '%s\n' "$RUNS_CSV_HEADER" > "$RUNS_CSV_PATH"
  fi
}

# Task 4: append one CSV row per CLI run. Fields are escaped with csv_field so a task name with
# commas or quotes cannot break the column layout. Mirrors limitshift.ps1 Add-RunsCsvRow.
add_runs_csv_row() {
  local task="$1" run="$2" mode="$3" exit_code="$4" status="$5"
  printf '%s,%s,%s,%s,%s,%s\n' \
    "$(csv_field "$(date '+%Y-%m-%dT%H:%M:%S')")" \
    "$(csv_field "$task")" \
    "$(csv_field "$run")" \
    "$(csv_field "$mode")" \
    "$(csv_field "$exit_code")" \
    "$(csv_field "$status")" >> "$RUNS_CSV_PATH"
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

if [ "$DRY_RUN" -ne 1 ]; then
  check_cli_binaries
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
  local taskCompletionCheck stallCount previousNoMarkerText hasPreviousNoMarker currentText
  local taskModels modelCount currentModelIndex currentModel nextModelIndex m

  while [ "$i" -lt "$TASK_COUNT" ]; do
    taskNumber=$((i + 1))

    if test_task_already_done "$i"; then
      # Task 4: a done marker only counts when its stored fingerprint still matches the current
      # task. If the task's prompt/cli/projectPath/model/effort/extraArgs changed, invalidate the
      # marker (re-run) and drop the stale session id so it starts a fresh session.
      local savedFp currentFp
      savedFp=$(get_saved_done_fingerprint "$i")
      currentFp=$(get_task_fingerprint "$i")
      if [ "$savedFp" = "$currentFp" ]; then
        write_step "Skipping task $taskNumber of $TASK_COUNT: $(task_field "$i" "name")"
        echo "Task is already marked as done."
        i=$((i + 1))
        continue
      fi
      write_step "Re-running task $taskNumber of $TASK_COUNT: $(task_field "$i" "name")"
      echo "Task $taskNumber changed since last run; previous done marker invalidated."
      rm -f "$(get_task_done_file_path "$i")"
      rm -f "$(get_task_session_file_path "$i")"
      # Task 6: also drop the stale model-rotation index so a changed task starts at model #1.
      rm -f "$(get_task_model_index_file_path "$i")"
    fi

    runCount=0
    errorRetryCount=0
    mustWaitForFreshSession=0
    stallCount=0
    previousNoMarkerText=""
    hasPreviousNoMarker=0
    taskCompletionCheck=$(task_completion_check "$i")

    # Task 6: load the per-task model list (ordered) and the persisted current index. A restart
    # keeps its place. Bash 3.2 has no mapfile, so read line-by-line into an indexed array.
    taskModels=()
    while IFS= read -r m; do
      taskModels+=("$m")
    done < <(get_task_models "$i")
    modelCount=${#taskModels[@]}
    if [ "$modelCount" -gt 1 ]; then
      currentModelIndex=$(get_saved_task_model_index "$i")
    else
      currentModelIndex=0
    fi
    if [ "$currentModelIndex" -ge "$modelCount" ] 2>/dev/null; then currentModelIndex=0; fi

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

      # Task 6: the model used for THIS run is Models[currentModelIndex]. Empty when the task set
      # no model at all (then build_cli_args emits no -m/--model, exactly as before).
      if [ "$modelCount" -gt 0 ]; then
        currentModel="${taskModels[$currentModelIndex]}"
      else
        currentModel=""
      fi

      savedSessionId=$(get_saved_task_session_id "$i")

      local runMode
      if [ -z "$savedSessionId" ]; then
        runMode="New"
        sessionId=""
        if [ "$task_cli" = "claude" ]; then
          sessionId=$(new_task_session_id "$i")
        fi
        invoke_cli_task_run "$i" "New" "$sessionId" "$currentModel"
      else
        runMode="Resume"
        invoke_cli_task_run "$i" "Resume" "$savedSessionId" "$currentModel"
      fi

      if [ "$DRY_RUN" -eq 1 ]; then
        write_step "Dry run for task $taskNumber recorded the command only"
        break
      fi

      # Read results from globals set by invoke_cli_task_run
      result_ok="$R_OK"
      result_is_limit="$R_IS_LIMIT"
      result_text="$R_TEXT"
      result_session_id="$R_SESSION_ID"
      result_error_text="$R_ERROR_TEXT"

      # Task 4: classify this run's outcome and append one runs.csv row. The status maps the
      # parsed result to a short label (Limit/Error/Done/Blocked/NoMarker) consistently with
      # limitshift.ps1. In simple mode an OK run is Done.
      local runStatus runExit
      if [ "$result_is_limit" -eq 1 ]; then
        runStatus="Limit"
      elif [ "$result_ok" -eq 0 ]; then
        runStatus="Error"
      elif [ "$taskCompletionCheck" != "true" ]; then
        runStatus="Done"
      else
        get_marker_status "$result_text"
        if [ "$M_STATUS" = "Done" ]; then
          runStatus="Done"
        elif [ "$M_STATUS" = "Blocked" ]; then
          runStatus="Blocked"
        else
          runStatus="NoMarker"
        fi
      fi
      if [ "$result_ok" -eq 0 ]; then runExit=1; else runExit=0; fi
      add_runs_csv_row "$taskNumber-$(task_field "$i" "name")" "$runCount" "$runMode" "$runExit" "$runStatus"

      if [ -n "$result_session_id" ]; then
        printf '%s' "$result_session_id" > "$(get_task_session_file_path "$i")"
      fi

      # Gemini-only: --resume rejection fallback
      if [ "$task_cli" = "gemini" ] && [ "$result_ok" -eq 0 ] && \
         printf '%s' "$result_error_text" | grep -qiE 'unknown option.*resume|not supported in non-interactive|unexpected argument|too many arguments|invalid.*resume'; then
        rm -f "$(get_task_session_file_path "$i")"
        write_step "Task $taskNumber: installed gemini rejects --resume; retrying with continuation prompt only"
        continue
      fi

      # A usage limit pauses and resumes, in both simple and completion-check modes.
      if [ "$result_is_limit" -eq 1 ]; then
        # Task 6: model rotation. If another model remains in the list, switch to it and retry
        # IMMEDIATELY (same session id — a resume) WITHOUT waiting. Only once every listed model is
        # limit-exhausted do we reset to model #1 and wait for the reset.
        if [ "$modelCount" -gt 1 ] && [ "$currentModelIndex" -lt "$((modelCount - 1))" ]; then
          nextModelIndex=$((currentModelIndex + 1))
          write_step "Task $taskNumber: limit on ${taskModels[$currentModelIndex]}; switching to ${taskModels[$nextModelIndex]}"
          currentModelIndex=$nextModelIndex
          save_task_model_index "$i" "$currentModelIndex"
          continue
        fi

        if [ "$modelCount" -gt 1 ]; then
          # Every model in the list is exhausted: reset to model #1, then wait for the reset.
          currentModelIndex=0
          save_task_model_index "$i" "$currentModelIndex"
        fi

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

      # Simple mode (completionCheck:false): the first OK run (no limit, no error) is done.
      if [ "$taskCompletionCheck" != "true" ]; then
        save_task_done_marker "$i"
        write_step "Task $taskNumber completed"
        break
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

      # No-progress guard: an OK run with no marker whose text repeats the previous no-marker
      # response counts as a stall. After maxStalls stalls, fail the task. Identical responses
      # produce identical text, so a direct string comparison is sufficient.
      currentText="$result_text"
      if [ "$hasPreviousNoMarker" -eq 1 ] && [ "$currentText" = "$previousNoMarkerText" ]; then
        stallCount=$((stallCount + 1))
        if [ "$stallCount" -ge "$MAX_STALLS" ]; then
          save_task_failed_marker "$i" "no progress: agent repeated the same response without a completion marker"
          write_step "Task $taskNumber failed: no progress: agent repeated the same response without a completion marker"
          if [ "$STOP_ON_ERROR" = "true" ]; then
            echo "ERROR: Task $taskNumber failed: no progress: agent repeated the same response without a completion marker" >&2
            exit 1
          fi
          echo "stopOnError=false; abandoning this task and moving to the next one."
          break
        fi
      fi
      previousNoMarkerText="$currentText"
      hasPreviousNoMarker=1

      mustWaitForFreshSession=0
      write_step "Task $taskNumber is not complete yet; resuming the same session."
    done

    i=$((i + 1))
  done

  write_step "Script completed"
  echo "All queue tasks are finished."
  echo "Finished at: $(date)"
  echo "Log saved to: $LOG_PATH"
  echo "Last Claude usage saved to: $USAGE_PATH"
}

# Run the queue function and write log
run_queue 2>&1 | tee -a "$LOG_PATH"
