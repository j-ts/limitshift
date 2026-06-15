#!/usr/bin/env bash
# LimitShift (preview UI) — runs queued prompts against claude / codex / gemini / agy / copilot CLIs,
# waiting out usage limits and resuming sessions. macOS (bash 3.2+) and Linux.
# Functional twin of limitshift.sh; the only deltas are the user-facing UI (helpers prefixed ui_),
# the --demo flag, and the "preview" output palette.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUEUE_PATH=""
QUEUE_PATH_EXPLICIT=0
VALIDATE_ONLY=0
DRY_RUN=0
SHOW_RAW=0
REFRESH_CAPABILITIES=0
PROBE_MODELS=0
DEMO=0
LIMITSHIFT_SOURCE_ONLY="${LIMITSHIFT_SOURCE_ONLY:-0}"
# Snapshot TTY status before any pipe (e.g. tee) replaces fd 1 with a pipe.
_STDOUT_IS_TTY=0; if [ -t 1 ]; then _STDOUT_IS_TTY=1; fi
MODEL_VALIDATION="strictWhenDiscoverable"
CAPABILITY_CACHE_HOURS=24

TASK_COMPLETE_MARKER="[[TASK_COMPLETE]]"
TASK_BLOCKED_MARKER="[[TASK_BLOCKED]]"

usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  --queue-path <path>  Path to queue JSON file (default: limitshift-queue.json next to script)"
  echo "  --queue <path>       Alias for --queue-path"
  echo "  --validate-only      Validate configuration syntax, paths, and binaries, then exit"
  echo "  --dry-run            Simulate execution by printing commands without running them"
  echo "  --show-raw           Print the raw CLI JSON to the console (default: only the response text)"
  echo "  --refresh-capabilities  Ignore cached capability data and re-discover model lists"
  echo "  --probe-models          Run a cheap prompt per CLI to verify model connectivity (validate-only)"
  echo "  --demo               Run the scripted UI preview (no CLIs run, no quota used)"
  echo "  --load-functions-only  Source-only mode (used by tests)"
  echo "  -h, --help           Show this help message"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --queue|--queue-path) QUEUE_PATH="$2"; QUEUE_PATH_EXPLICIT=1; shift 2 ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --show-raw|--show-raw-output) SHOW_RAW=1; shift ;;
    --refresh-capabilities) REFRESH_CAPABILITIES=1; shift ;;
    --probe-models) PROBE_MODELS=1; shift ;;
    --demo) DEMO=1; shift ;;
    --load-functions-only) LIMITSHIFT_SOURCE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# --- UI theme (preview) -------------------------------------------------------
# Cosmetic only. Animations auto-disable when stdout is not a TTY so a redirected
# log file never carries spinner frames. All escape sequences go through ui_color
# so a non-TTY run prints plain text.

UI_ACCENT=$'\033[35m'      # magenta
UI_GREEN=$'\033[32m'
UI_RED=$'\033[31m'
UI_YELLOW=$'\033[33m'
UI_BLUE=$'\033[34m'
UI_DIM=$'\033[90m'
UI_WHITE=$'\033[1m'
UI_RESET=$'\033[0m'

GLYPH_STAR='✦'    # four-pointed star, accent
GLYPH_TASK='▸'    # right triangle, task header
GLYPH_DONE='✓'    # check mark
GLYPH_ERR='✗'     # ballot x
GLYPH_RETRY='↻'   # clockwise arrow
GLYPH_MOON='☾'    # last-quarter moon, rest
GLYPH_DIAMOND='◆' # diamond, final summary
GLYPH_ARROW='→'   # rightwards arrow, prompt-saved tail
GLYPH_DOT='·'     # middle dot
GLYPH_DASH='—'    # em dash, summary separator
GLYPH_RULE='─'    # box-drawing horizontal line

UI_MILESTONE_INDENT='      '
UI_TASK_TOTAL=0
UI_TASK_START_EPOCH=0
UI_SPINNER_PID=""

# stdout TTY test, used by every helper that might animate or colorize.
# Uses the snapshot taken at startup so the tee pipe doesn't suppress colors.
ui_animatable() {
  [ "$_STDOUT_IS_TTY" = "1" ]
}

# ui_color FG TEXT — colored text on a TTY, plain text otherwise.
ui_color() {
  if ui_animatable; then
    printf '%s%s%s' "$1" "$2" "$UI_RESET"
  else
    printf '%s' "$2"
  fi
}

is_git_repo() {
  local p="$1"
  git -C "$p" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

has_commits() {
  local p="$1"
  git -C "$p" rev-parse HEAD >/dev/null 2>&1
}

# Soft section marker (replaces the heavy ==== ... ==== banner).
write_step() {
  printf '\n'
  ui_color "$UI_DIM" "  $GLYPH_DOT $1"
  printf '\n'
}

ui_beat() {
  local glyph="$1" message="$2" color="${3:-$UI_ACCENT}"
  ui_color "$color" "  $glyph "
  ui_color "$UI_DIM" "$message"
  printf '\n'
}

ui_banner() {
  local task_count="$1"; shift
  local cli_list="" seen="" c
  for c in "$@"; do
    case " $seen " in
      *" $c "*) ;;
      *) seen="$seen $c"; if [ -z "$cli_list" ]; then cli_list="$c"; else cli_list="$cli_list, $c"; fi ;;
    esac
  done
  local plural="s"; [ "$task_count" -eq 1 ] && plural=""
  printf '\n'
  ui_color "$UI_ACCENT" "  $GLYPH_STAR LimitShift"
  ui_color "$UI_DIM" "   $GLYPH_DOT   ${task_count} task${plural} queued $GLYPH_DOT $cli_list"
  printf '\n'
}

ui_separator() {
  local rule="" i=0
  while [ "$i" -lt 54 ]; do rule="${rule}${GLYPH_RULE}"; i=$((i + 1)); done
  printf '\n'
  ui_color "$UI_DIM" "  $rule"
  printf '\n'
}

# First up-to-2 non-blank lines of the user's prompt, marker boilerplate stripped,
# lines trimmed to width. Result goes in $UI_PROMPT_PREVIEW (newline-separated).
ui_prompt_preview() {
  local prompt_text="$1" max_lines=2 width=72
  local ellipsis='…' open_q='“' close_q='”'
  UI_PROMPT_PREVIEW=""
  if [ -z "$prompt_text" ]; then UI_PROMPT_PREVIEW='(empty prompt)'; return; fi
  local text="$prompt_text"
  case "$text" in
    *"IMPORTANT AUTOMATION INSTRUCTIONS"*) text="${text%%IMPORTANT AUTOMATION INSTRUCTIONS*}" ;;
  esac
  local lines=() line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$line" ] && lines+=("$line")
  done <<EOF
$text
EOF
  if [ "${#lines[@]}" -eq 0 ]; then UI_PROMPT_PREVIEW='(empty prompt)'; return; fi
  local take=$max_lines
  [ "${#lines[@]}" -lt "$take" ] && take=${#lines[@]}
  local out=() truncated_last=0 k=0 l
  while [ "$k" -lt "$take" ]; do
    l="${lines[$k]}"
    if [ "${#l}" -gt "$width" ]; then
      l="${l:0:$((width - 1))}"
      l="$(printf '%s' "$l" | sed -e 's/[[:space:]]*$//')"
      l="${l}${ellipsis}"
      truncated_last=1
    else
      truncated_last=0
    fi
    out+=("$l")
    k=$((k + 1))
  done
  local more=0
  if [ "${#lines[@]}" -gt "$take" ] || [ "$truncated_last" -eq 1 ]; then more=1; fi
  out[0]="${open_q}${out[0]}"
  local last_idx=$((${#out[@]} - 1))
  if [ "$more" -eq 1 ] && [ "$truncated_last" -eq 0 ]; then
    out[$last_idx]="${out[$last_idx]}${ellipsis}"
  fi
  out[$last_idx]="${out[$last_idx]}${close_q}"
  local i=0
  while [ "$i" -lt "${#out[@]}" ]; do
    if [ "$i" -eq 0 ]; then
      UI_PROMPT_PREVIEW="${out[$i]}"
    else
      UI_PROMPT_PREVIEW="${UI_PROMPT_PREVIEW}
${out[$i]}"
    fi
    i=$((i + 1))
  done
}

ui_task_header() {
  local task_number="$1" task_total="$2" cli="$3" mode="$4" model="$5" name="$6" prompt_text="$7"
  local mode_word="new"
  [ "$mode" = "Resume" ] && mode_word="resume"
  local meta="   $cli"
  if [ -n "$model" ]; then meta="${meta} $GLYPH_DOT ${model}"; fi
  meta="${meta} $GLYPH_DOT ${mode_word}"

  printf '\n'
  ui_color "$UI_ACCENT" "  $GLYPH_TASK "
  ui_color "$UI_WHITE" "Task $task_number/$task_total $GLYPH_DOT $name"
  ui_color "$UI_DIM" "$meta"
  printf '\n'

  if [ "$mode" = "New" ]; then
    ui_prompt_preview "$prompt_text"
    local line
    while IFS= read -r line; do
      ui_color "$UI_YELLOW" "  ${line}"
      printf '\n'
    done <<EOF
$UI_PROMPT_PREVIEW
EOF
    ui_color "$UI_DIM" "  $GLYPH_ARROW full prompt saved to the output file"
    printf '\n'
  fi

  UI_TASK_START_EPOCH=$(date +%s)
}

ui_task_done() {
  local task_number="$1"
  local tail=""
  if [ "$UI_TASK_START_EPOCH" -gt 0 ]; then
    local now elapsed mins secs
    now=$(date +%s)
    elapsed=$((now - UI_TASK_START_EPOCH))
    mins=$((elapsed / 60))
    secs=$((elapsed % 60))
    tail=$(printf '  %s  %d:%02d' "$GLYPH_DOT" "$mins" "$secs")
  fi
  printf '\n'
  ui_color "$UI_GREEN" "${UI_MILESTONE_INDENT}$GLYPH_DONE "
  ui_color "$UI_DIM" "Task ${task_number} done${tail}"
  printf '\n'
}

ui_response_header() {
  printf '\n'
  ui_color "$UI_ACCENT" "  $GLYPH_STAR "
  ui_color "$UI_DIM" "response"
  printf '\n'
}

# Show at most $2 lines of $1 (default 10), then a dim "trimmed" note.
ui_body() {
  local text="$1" max_lines="${2:-10}" color="${3:-}"
  [ -z "$text" ] && return
  local total
  total=$(printf '%s\n' "$text" | awk 'END{print NR}')
  local show=$max_lines
  [ "$total" -lt "$show" ] && show=$total
  local i=0 line
  while IFS= read -r line; do
    i=$((i + 1))
    if [ "$i" -gt "$show" ]; then break; fi
    if [ -n "$color" ]; then
      ui_color "$color" "$line"
      printf '\n'
    else
      printf '%s\n' "$line"
    fi
  done <<EOF
$text
EOF
  if [ "$total" -gt "$max_lines" ]; then
    local hidden=$((total - max_lines))
    local plural="s"; [ "$hidden" -eq 1 ] && plural=""
    ui_color "$UI_DIM" "  $GLYPH_DOT $hidden more line$plural trimmed $GLYPH_DOT full text in the output file"
    printf '\n'
  fi
}

# Quoted single-line if short, otherwise ui_body (dim).
ui_reason() {
  local text="$1" max_lines="${2:-10}"
  if [ -z "$text" ]; then
    ui_color "$UI_DIM" '  "(no detail)"'
    printf '\n'
    return
  fi
  local count
  count=$(printf '%s\n' "$text" | awk 'NF{c++} END{print c+0}')
  if [ "$count" -le 1 ]; then
    local single
    single=$(printf '%s' "$text" | awk 'NF{print; exit}')
    ui_color "$UI_DIM" "  \"${single}\""
    printf '\n'
    return
  fi
  ui_body "$text" "$max_lines" "$UI_DIM"
}

# Format duration in English: "2 seconds", "5 minutes", "1 hour 23 minutes".
ui_format_duration() {
  local secs="$1"
  if [ "$secs" -lt 60 ]; then
    if [ "$secs" -le 1 ]; then printf '1 second'; else printf '%d seconds' "$secs"; fi
    return
  fi
  if [ "$secs" -lt 3600 ]; then
    local m=$(( (secs + 30) / 60 ))
    if [ "$m" -eq 1 ]; then printf '1 minute'; else printf '%d minutes' "$m"; fi
    return
  fi
  local h=$((secs / 3600))
  local m=$(( (secs % 3600) / 60 ))
  local hpart mpart
  if [ "$h" -eq 1 ]; then hpart='1 hour'; else hpart="${h} hours"; fi
  if [ "$m" -eq 0 ]; then printf '%s' "$hpart"; return; fi
  if [ "$m" -eq 1 ]; then mpart='1 minute'; else mpart="${m} minutes"; fi
  printf '%s %s' "$hpart" "$mpart"
}

# Final summary. Variants:
#   dry-run                          -> "Dry run complete"
#   all tasks already done (skipped) -> "Nothing to do" + redo-hint
#   any failed                       -> bulleted breakdown (+ skipped row + redo-hint if any)
#   some new + some skipped          -> "Done - N of M ran" breakdown + redo-hint
#   all new + all completionCheck    -> "executed successfully"
#   all new + any completionCheck off-> "executed. Please check the work manually"
#
# Args: task_count, done_count, failed_count, skipped_count, all_completion_check,
#       log_path, state_path, dry_run
ui_summary() {
  local task_count="$1" done_count="$2" failed_count="$3" skipped_count="$4"
  local all_completion_check="$5" log_path="$6" state_path="$7" dry_run="${8:-0}"
  printf '\n'
  ui_separator
  printf '\n'

  if [ "$dry_run" -eq 1 ]; then
    local plural="s"; [ "$task_count" -eq 1 ] && plural=""
    ui_color "$UI_ACCENT" "  $GLYPH_DIAMOND Dry run complete"
    ui_color "$UI_DIM" " $GLYPH_DASH recorded ${task_count} task command${plural}, no CLIs were run."
    printf '\n'
    return
  fi

  # All tasks skipped - nothing actually ran this turn.
  if [ "$skipped_count" -eq "$task_count" ] && [ "$task_count" -gt 0 ]; then
    local plural="s"; local was="were"
    [ "$task_count" -eq 1 ] && { plural=""; was="was"; }
    ui_color "$UI_ACCENT" "  $GLYPH_DIAMOND Nothing to do"
    ui_color "$UI_DIM" " $GLYPH_DASH all ${task_count} queued task${plural} ${was} already done in a previous run."
    printf '\n'
    if [ -n "$state_path" ]; then
      ui_color "$UI_DIM" "    To redo one task, delete its marker in ${state_path}/status/"
      printf '\n'
      ui_color "$UI_DIM" "    To redo all, delete the state folder: ${state_path}"
      printf '\n'
    fi
    return
  fi

  if [ "$failed_count" -gt 0 ]; then
    local ran_count=$((done_count + failed_count))
    ui_color "$UI_ACCENT" "  $GLYPH_DIAMOND Done"
    ui_color "$UI_DIM" " $GLYPH_DASH ${ran_count} of ${task_count} queued tasks ran this turn:"
    printf '\n'
    ui_color "$UI_GREEN" "      $GLYPH_DOT ${done_count} newly completed"
    printf '\n'
    ui_color "$UI_RED" "      $GLYPH_DOT ${failed_count} failed"
    printf '\n'
    if [ "$skipped_count" -gt 0 ]; then
      ui_color "$UI_DIM" "      $GLYPH_DOT ${skipped_count} already done (skipped)"
      printf '\n'
    fi
    printf '\n'
    ui_color "$UI_DIM" "    See a detailed transcript in ${log_path}"
    printf '\n'
    if [ "$skipped_count" -gt 0 ] && [ -n "$state_path" ]; then
      ui_color "$UI_DIM" "    To redo one task, delete its marker in ${state_path}/status/"
      printf '\n'
      ui_color "$UI_DIM" "    To redo all, delete the state folder: ${state_path}"
      printf '\n'
    fi
    return
  fi

  # Some skipped, some newly executed - no failures.
  if [ "$skipped_count" -gt 0 ]; then
    ui_color "$UI_ACCENT" "  $GLYPH_DIAMOND Done"
    ui_color "$UI_DIM" " $GLYPH_DASH ${done_count} of ${task_count} queued tasks ran this turn:"
    printf '\n'
    ui_color "$UI_GREEN" "      $GLYPH_DOT ${done_count} newly completed"
    printf '\n'
    ui_color "$UI_DIM" "      $GLYPH_DOT ${skipped_count} already done (skipped)"
    printf '\n'
    if [ "$all_completion_check" != "1" ]; then
      printf '\n'
      ui_color "$UI_DIM" "    completionCheck is off for at least one task $GLYPH_DASH please check the work manually."
      printf '\n'
    fi
    ui_color "$UI_DIM" "    log saved to ${log_path}"
    printf '\n'
    if [ -n "$state_path" ]; then
      ui_color "$UI_DIM" "    To redo one task, delete its marker in ${state_path}/status/"
      printf '\n'
      ui_color "$UI_DIM" "    To redo all, delete the state folder: ${state_path}"
      printf '\n'
    fi
    return
  fi

  # All new, no failures, no skips - the "everything went great" path.
  local plural="s"; [ "$task_count" -eq 1 ] && plural=""
  if [ "$all_completion_check" = "1" ]; then
    ui_color "$UI_ACCENT" "  $GLYPH_DIAMOND All done"
    ui_color "$UI_DIM" " $GLYPH_DASH all ${task_count} queued task${plural} were executed successfully."
  else
    ui_color "$UI_ACCENT" "  $GLYPH_DIAMOND All done"
    ui_color "$UI_DIM" " $GLYPH_DASH all ${task_count} queued task${plural} were executed. Please check the work manually."
  fi
  printf '\n'
  ui_color "$UI_DIM" "    log saved to ${log_path}"
  printf '\n'
}

# Animated working spinner. Writes to /dev/tty so its frames never reach a piped
# log file. Started in the background; stopped with ui_spinner_stop.
ui_spinner_start() {
  if ! ui_animatable; then return; fi
  if [ ! -w /dev/tty ]; then return; fi
  (
    trap 'exit 0' TERM INT
    local pos=0 dir=1 i d ch ch_buf
    local track=7
    local verbs=("running" "reading" "operating" "considering" "still on it" "wondering" "progressing" "performing")
    local start now elapsed mins secs verb mmss verb_idx
    start=$(date +%s)
    printf '\033[?25l' > /dev/tty 2>/dev/null
    while :; do
      ch_buf=""
      i=0
      while [ "$i" -lt "$track" ]; do
        d=$((i - pos)); [ "$d" -lt 0 ] && d=$((-d))
        if [ "$d" -eq 0 ]; then ch='●'
        elif [ "$d" -eq 1 ]; then ch='○'
        elif [ "$d" -eq 2 ]; then ch='∘'
        else ch='·'
        fi
        ch_buf="${ch_buf}${ch}"
        i=$((i + 1))
      done
      now=$(date +%s)
      elapsed=$((now - start))
      mins=$((elapsed / 60))
      secs=$((elapsed % 60))
      mmss=$(printf '%d:%02d' "$mins" "$secs")
      verb_idx=$(( (elapsed / 3) % ${#verbs[@]} ))
      verb="${verbs[$verb_idx]}"
      printf '\r' > /dev/tty
      printf '%s  %s %s %s' "$UI_ACCENT" "$GLYPH_STAR" "$ch_buf" "$UI_RESET" > /dev/tty
      printf '%s %s %s %s     %s' "$UI_DIM" " " "$verb" "$GLYPH_DOT $mmss" "$UI_RESET" > /dev/tty
      pos=$((pos + dir))
      if [ "$pos" -ge $((track - 1)) ] || [ "$pos" -le 0 ]; then dir=$((-dir)); fi
      sleep 0.14 2>/dev/null || sleep 1
    done
  ) &
  UI_SPINNER_PID=$!
  disown "$UI_SPINNER_PID" 2>/dev/null || true
}

ui_spinner_stop() {
  if [ -n "$UI_SPINNER_PID" ]; then
    kill "$UI_SPINNER_PID" 2>/dev/null
    wait "$UI_SPINNER_PID" 2>/dev/null
    UI_SPINNER_PID=""
    if ui_animatable && [ -w /dev/tty ]; then
      printf '\r%s\r' "                                                  " > /dev/tty 2>/dev/null
      printf '\033[?25h' > /dev/tty 2>/dev/null
    fi
  fi
}

# Calm "resting" countdown to the given wake-time epoch. Falls back to plain sleep
# off a TTY.
ui_rest() {
  local wake_epoch="$1"
  if ! ui_animatable || [ ! -w /dev/tty ]; then
    local now secs
    now=$(date +%s)
    secs=$((wake_epoch - now))
    if [ "$secs" -gt 0 ]; then sleep "$secs"; fi
    return
  fi
  local moons=('◐' '◳' '◑' '◲')
  local mi=0
  printf '\033[?25l' > /dev/tty 2>/dev/null
  local wake_clock
  if date -d "@$wake_epoch" '+%-I:%M %p' >/dev/null 2>&1; then
    wake_clock=$(date -d "@$wake_epoch" '+%-I:%M %p')
  elif date -r "$wake_epoch" '+%-I:%M %p' >/dev/null 2>&1; then
    wake_clock=$(date -r "$wake_epoch" '+%-I:%M %p')
  else
    wake_clock="soon"
  fi
  while :; do
    local now remain
    now=$(date +%s)
    remain=$((wake_epoch - now))
    [ "$remain" -le 0 ] && break
    local h=$((remain / 3600))
    local m=$(( (remain % 3600) / 60 ))
    local s=$((remain % 60))
    local cd
    cd=$(printf '%02d:%02d:%02d' "$h" "$m" "$s")
    printf '\r' > /dev/tty
    printf '%s     %s %s' "$UI_BLUE" "${moons[$((mi % ${#moons[@]}))]}" "$UI_RESET" > /dev/tty
    printf '%sresting %s %s until %s   %s' "$UI_DIM" "$GLYPH_DOT" "$cd" "$wake_clock" "$UI_RESET" > /dev/tty
    mi=$((mi + 1))
    sleep 1
  done
  printf '\r%s\r' "                                                            " > /dev/tty 2>/dev/null
  printf '\033[?25h' > /dev/tty 2>/dev/null
}

# Rest, then print the past-tense '☾ Hit a usage limit on <cli>, rested for X' beat.
ui_rest_with_summary() {
  local cli="$1" wake_epoch="$2"
  local start now elapsed
  start=$(date +%s)
  ui_rest "$wake_epoch"
  now=$(date +%s)
  elapsed=$((now - start))
  # Always print the beat - the wrapper is only ever called when a real limit was hit, and the
  # downstream code (and tests) need a "Hit a usage limit" line whether or not we actually slept.
  printf '\n'
  ui_beat "$GLYPH_MOON" "Hit a usage limit on ${cli}, rested for $(ui_format_duration "$elapsed")" "$UI_BLUE"
}

# --- Demo flow (no CLIs run) -------------------------------------------------

ui_fake_work() {
  local secs="${1:-4}"
  if ! ui_animatable; then
    ui_color "$UI_ACCENT" "  $GLYPH_STAR working..."
    printf '\n'
    sleep "$secs"
    return
  fi
  ( sleep "$secs" ) &
  local sleeper=$!
  ui_spinner_start
  wait "$sleeper" 2>/dev/null
  ui_spinner_stop
}

ui_demo() {
  local workflow_path="$SCRIPT_DIR/limitshift-queue.example-workflow.json"
  if [ ! -f "$workflow_path" ]; then
    ui_color "$UI_RED" "  $GLYPH_ERR Demo file not found: $workflow_path"
    printf '\n'
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for --demo." >&2
    return 2
  fi
  local count
  count=$(jq '.tasks | length' "$workflow_path" | tr -d '\r')
  UI_TASK_TOTAL=$count

  local clis=() i=0 c
  while [ "$i" -lt "$count" ]; do
    c=$(jq -r ".tasks[$i].cli // empty" "$workflow_path" | tr -d '\r')
    clis+=("$c")
    i=$((i + 1))
  done

  local replies=(
"Wrote bugs.md with 7 numbered issues found in src/ (auth, parsing, error handling).
[[TASK_COMPLETE]]"
"Walked bugs.md top to bottom; applied fixes and appended ' - FIXED' to each item.
[[TASK_COMPLETE]]"
"Audited bugs.md against current src/: 6 items verified fixed, 1 still broken (src/auth/token.ts: race on expired refresh).
[[TASK_COMPLETE]]"
  )

  ui_banner "$count" "${clis[@]}"
  local started; started=$(date '+%a %H:%M' 2>/dev/null || date)
  ui_color "$UI_DIM" "    started ${started} $GLYPH_DOT demo from $(basename "$workflow_path") (no CLIs are run)"
  printf '\n'

  local k=0 task_number cli name model prompt
  while [ "$k" -lt "$count" ]; do
    task_number=$((k + 1))
    cli=$(jq -r ".tasks[$k].cli // empty" "$workflow_path" | tr -d '\r')
    name=$(jq -r ".tasks[$k].name // empty" "$workflow_path" | tr -d '\r')
    model=$(jq -r ".tasks[$k].model // empty" "$workflow_path" | tr -d '\r')
    prompt=$(jq -r ".tasks[$k].prompt // empty" "$workflow_path" | tr -d '\r')

    if [ "$k" -gt 0 ]; then ui_separator; fi

    ui_task_header "$task_number" "$count" "$cli" "New" "$model" "$name" "$prompt"
    ui_fake_work 4

    # Usage-limit beat on task 2 only. Mirrors the PS demo (2-second rest).
    if [ "$task_number" -eq 2 ]; then
      local wake=$(( $(date +%s) + 2 ))
      ui_rest_with_summary "$cli" "$wake"
      ui_fake_work 2
    fi

    ui_response_header
    ui_body "${replies[$k]}" 10
    ui_task_done "$task_number"

    k=$((k + 1))
  done

  ui_summary "$count" "$count" 0 0 1 './limitshift-queue/limitshift-log.txt' './limitshift-queue' 0
}

# --- Functional core (parity with limitshift.sh) -----------------------------

task_field() {
  local idx="$1" field="$2"
  jq -r ".tasks[$idx].$field // empty" "$QUEUE_PATH" | tr -d '\r'
}

get_task_runner_count() {
  local idx="$1"
  jq -r ".tasks[$idx].fallbacks | if type==\"array\" then length + 1 else 1 end" "$QUEUE_PATH" | tr -d '\r'
}

get_runner_field() {
  local task_idx="$1" runner_idx="$2" field="$3"
  if [ "$runner_idx" -eq 0 ]; then
    task_field "$task_idx" "$field"
  else
    local f_idx=$((runner_idx - 1))
    jq -r ".tasks[$task_idx].fallbacks[$f_idx].$field // empty" "$QUEUE_PATH" | tr -d '\r'
  fi
}

get_task_extra_args() {
  get_runner_extra_args "$1" 0
}

get_runner_extra_args() {
  local task_idx="$1" runner_idx="$2"
  local node_path
  if [ "$runner_idx" -eq 0 ]; then
    node_path=".tasks[$task_idx]"
  else
    node_path=".tasks[$task_idx].fallbacks[$((runner_idx-1))]"
  fi
  jq -r "$node_path.extraArgs | if type==\"array\" then .[] elif type==\"string\" then splits(\"\\\\s+\") else empty end" "$QUEUE_PATH" | tr -d '\r'
}

is_ollama_task() {
  is_ollama_runner "$1" 0
}

is_ollama_runner() {
  local task_idx="$1" runner_idx="$2" cli arg lower
  cli=$(get_runner_field "$task_idx" "$runner_idx" "cli" | tr '[:upper:]' '[:lower:]')
  if [ "$cli" != "claude" ]; then return 1; fi
  while IFS= read -r arg; do
    lower=$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')
    if [ "$lower" = "ollama" ] || [ "$lower" = "--oss" ]; then return 0; fi
  done < <(get_runner_extra_args "$task_idx" "$runner_idx")
  return 1
}

get_task_models() {
  get_runner_models "$1" 0
}

get_runner_models() {
  local task_idx="$1" runner_idx="$2"
  local node_path
  if [ "$runner_idx" -eq 0 ]; then
    node_path=".tasks[$task_idx]"
  else
    node_path=".tasks[$task_idx].fallbacks[$((runner_idx-1))]"
  fi
  jq -r "$node_path.model | if type==\"array\" then .[] elif type==\"string\" then . else empty end" "$QUEUE_PATH" | tr -d '\r'
}

get_task_models_joined() {
  get_runner_models_joined "$1" 0
}

get_runner_models_joined() {
  local task_idx="$1" runner_idx="$2" joined="" first=1 m
  while IFS= read -r m; do
    if [ "$first" -eq 1 ]; then joined="$m"; first=0; else joined="$joined $m"; fi
  done < <(get_runner_models "$task_idx" "$runner_idx")
  printf '%s' "$joined"
}

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
  local raw_args=() arg
  while IFS= read -r arg; do
    if [ -n "$arg" ]; then raw_args+=("$arg"); fi
  done < <(get_task_extra_args "$idx")
  CODEX_RESUME_EXTRA_ARGS=()
  local i=0
  while [ "$i" -lt "${#raw_args[@]}" ]; do
    arg="${raw_args[$i]}"
    case "$arg" in
      --sandbox|-s|--cd|-C|--add-dir) i=$((i + 2)); continue ;;
      --sandbox=*|--cd=*|--add-dir=*|-C=*) i=$((i + 1)); continue ;;
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
  COMPLETION_CHECK=$(jq -r '(.settings // {}) | if has("completionCheck") then .completionCheck else true end' "$QUEUE_PATH" | tr -d '\r')
  MAX_STALLS=$(jq -r '.settings.maxStalls // 2' "$QUEUE_PATH" | tr -d '\r')
  MODEL_VALIDATION=$(jq -r '.settings.modelValidation // "strictWhenDiscoverable"' "$QUEUE_PATH" | tr -d '\r')
  CAPABILITY_CACHE_HOURS=$(jq -r '.settings.capabilityCacheHours // 24' "$QUEUE_PATH" | tr -d '\r')
  local probe_from_config; probe_from_config=$(jq -r 'if .settings.probeModels == true then 1 else 0 end' "$QUEUE_PATH" | tr -d '\r')
  [ "$PROBE_MODELS" -eq 0 ] && PROBE_MODELS=$probe_from_config

  local i=0 n cli path
  while [ "$i" -lt "$TASK_COUNT" ]; do
    n=$((i + 1))
    for field in name projectPath prompt; do
      if [ "$(task_field "$i" "$field")" = "" ]; then
        echo "Task $n is missing required JSON property: $field" >&2
        exit 2
      fi
    done
    path=$(task_field "$i" "projectPath")
    path="${path//\\//}"
    if [ ! -d "$path" ]; then
      echo "Project path does not exist for task $n: $path" >&2
      exit 2
    fi

    # Task 4.2: Require a git working tree for tasks with fallbacks.
    local r_count; r_count=$(get_task_runner_count "$i")
    if [ "$r_count" -gt 1 ]; then
      if ! is_git_repo "$path"; then
        echo "Task $n (\"$(task_field "$i" "name")\") has fallbacks, which requires the projectPath to be a git repository. The provided projectPath is not a git repository: $path" >&2
        exit 2
      fi
      if ! has_commits "$path"; then
        ui_color "$UI_YELLOW" "[$GLYPH_STAR] Task $n WARNING: projectPath $path is a git repository but has no commits. Fingerprinting and handoff (git diff) will be less precise. Guidance: commit a baseline before starting rotation work."
        echo
      fi
    fi

    # Task 2.2: Validate all runners (task + fallbacks)
    local r_count; r_count=$(get_task_runner_count "$i")
    local r=0
    while [ "$r" -lt "$r_count" ]; do
      local label=""
      local node_path=".tasks[$i]"
      if [ "$r" -gt 0 ]; then
        label=" (fallback $r)"
        node_path=".tasks[$i].fallbacks[$((r-1))]"
      fi

      cli=$(get_runner_field "$i" "$r" "cli" | tr '[:upper:]' '[:lower:]')
      if [ -z "$cli" ]; then
        echo "Task $n$label is missing required JSON property: cli" >&2
        exit 2
      fi
      case "$cli" in
        claude|codex|gemini|agy|copilot) ;;
        *) echo "Task $n$label has unknown cli \"$cli\". Allowed values: claude, codex, gemini, agy, copilot" >&2; exit 2 ;;
      esac

      local model_type model_bad
      model_type=$(jq -r "$node_path.model | type" "$QUEUE_PATH" | tr -d '\r')
      if [ "$model_type" = "array" ]; then
        if [ "$(jq -r "$node_path.model | length" "$QUEUE_PATH" | tr -d '\r')" = "0" ]; then
          echo "Task $n$label model array must not be empty. Use a single string, or list one or more model names in preference order." >&2
          exit 2
        fi
        model_bad=$(jq -r "$node_path.model | map(select(type != \"string\")) | length" "$QUEUE_PATH" | tr -d '\r')
        if [ "$model_bad" != "0" ]; then
          echo "Task $n$label model array must contain only strings (got a non-string element)." >&2
          exit 2
        fi
      fi

      if [ "$cli" = "claude" ] && is_ollama_runner "$i" "$r"; then
        if [ -z "$(get_runner_models "$i" "$r" | sed -n '1p')" ]; then
          echo "Task $n$label: a local Ollama claude task needs a model (it is passed to 'ollama launch --model'). Set \"model\" to your Ollama model, e.g. \"qwen3.5:9b\"." >&2
          exit 2
        fi
      fi

      if [ "$cli" = "claude" ] && ! is_ollama_runner "$i" "$r"; then
        while IFS= read -r m; do
          case "$m" in
            *.*)
              echo "Task $n$label: claude model \"$m\" contains a dot. Claude headless mode (-p) does not expand the dotted form; use the hyphenated id (e.g. \"claude-opus-4-6\") or an alias (\"opus\", \"sonnet\", \"haiku\")." >&2
              exit 2
              ;;
          esac
        done < <(get_runner_models "$i" "$r")
      fi

      local effort
      effort=$(get_runner_field "$i" "$r" "effort")
      if [ -n "$effort" ]; then
        case "$cli" in
          gemini)
            echo "Task $n$label: gemini has no effort flag; set \"effort\": null (use thinkingLevel/thinkingBudget via gemini settings instead)." >&2
            exit 2
            ;;
          agy)
            echo "Task $n$label: agy (Antigravity CLI) has no --effort flag; set \"effort\": null." >&2
            exit 2
            ;;
          claude)
            if [ "$effort" = "ultracode" ]; then
              echo "Task $n$label: 'ultracode' is only available from the interactive /effort menu, not the --effort flag. Use low|medium|high|xhigh|max." >&2
              exit 2
            fi
            case "$effort" in
              low|medium|high|xhigh|max) ;;
              *) echo "Task $n$label: claude effort must be one of low, medium, high, xhigh, max (or null)." >&2; exit 2 ;;
            esac
            local haiku_match
            haiku_match=$(get_runner_models "$i" "$r" | grep -ic 'haiku')
            if [ "$haiku_match" -gt 0 ]; then
              echo "Task $n$label: claude model haiku does not support effort; set \"effort\": null." >&2
              exit 2
            fi
            ;;
          codex)
            case "$effort" in
              minimal|low|medium|high|xhigh) ;;
              *) echo "Task $n$label: codex effort must be one of minimal, low, medium, high, xhigh (or null). 'none' is plan-mode only." >&2; exit 2 ;;
            esac
            ;;
          copilot)
            case "$effort" in
              low|medium|high|xhigh|max) ;;
              *) echo "Task $n$label: copilot effort must be one of low, medium, high, xhigh, max (or null)." >&2; exit 2 ;;
            esac
            ;;
        esac
      fi
      r=$((r + 1))
    done
    i=$((i + 1))
  done
}

check_cli_binaries() {
  local cli r r_count i tcli missing_clis=() needs_ollama=0
  local -a unique_clis_arr=()

  i=0
  while [ "$i" -lt "$TASK_COUNT" ]; do
    r_count=$(get_task_runner_count "$i")
    r=0
    while [ "$r" -lt "$r_count" ]; do
      tcli=$(get_runner_field "$i" "$r" "cli" | tr '[:upper:]' '[:lower:]')
      unique_clis_arr+=("$tcli")
      if [ "$tcli" = "claude" ] && is_ollama_runner "$i" "$r"; then needs_ollama=1; fi
      r=$((r + 1))
    done
    i=$((i + 1))
  done

  local unique_clis
  unique_clis=$(printf '%s\n' "${unique_clis_arr[@]}" | sort -u)

  for cli in $unique_clis; do
    if ! command -v "$cli" >/dev/null 2>&1; then
      missing_clis+=("$cli")
    fi
  done
  if [ "$needs_ollama" -eq 1 ] && ! command -v ollama >/dev/null 2>&1; then
    missing_clis+=("ollama")
  fi

  if [ ${#missing_clis[@]} -gt 0 ]; then
    local missing_str
    missing_str=$(IFS=, ; echo "${missing_clis[*]}")
    echo "ERROR: The following CLI(s) are used in the queue but not found on PATH: $missing_str" >&2
    echo "Install instructions:" >&2
    echo "  claude : npm install -g @anthropic-ai/claude-code" >&2
    echo "  codex  : npm install -g @openai/codex" >&2
    echo "  gemini : npm install -g @google/gemini-cli" >&2
    echo "  agy    : curl -fsSL https://antigravity.google/cli/install.sh | bash   (Antigravity CLI; Windows PowerShell: irm https://antigravity.google/cli/install.ps1 | iex)" >&2
    echo "  copilot: install GitHub Copilot CLI and run: copilot login" >&2
    echo "  ollama : https://ollama.com/download  (only needed for local models)" >&2
    exit 2
  fi
}

_levenshtein() {
  local s="$1" t="$2"
  local sl=${#s} tl=${#t}
  if [ "$sl" -gt 50 ] || [ "$tl" -gt 50 ]; then echo 99; return; fi
  local -a d
  local i j c a b e
  for ((i = 0; i <= sl; i++)); do d[i*(tl+1)+0]=$i; done
  for ((j = 0; j <= tl; j++)); do d[0*(tl+1)+j]=$j; done
  for ((i = 1; i <= sl; i++)); do
    for ((j = 1; j <= tl; j++)); do
      [ "${s:i-1:1}" = "${t:j-1:1}" ] && c=0 || c=1
      a=$((d[(i-1)*(tl+1)+j]+1))
      b=$((d[i*(tl+1)+(j-1)]+1))
      e=$((d[(i-1)*(tl+1)+(j-1)]+c))
      d[i*(tl+1)+j]=$((a<b ? (a<e ? a : e) : (b<e ? b : e)))
    done
  done
  echo "${d[sl*(tl+1)+tl]}"
}

suggest_model_corrections() {
  local input="$1" models_list="$2"
  local input_lc; input_lc=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
  local min_dist=5
  local -a best
  best=()
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    local m_lc; m_lc=$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')
    local dist; dist=$(_levenshtein "$input_lc" "$m_lc")
    if [ "$dist" -lt "$min_dist" ]; then
      min_dist=$dist
      best=("$m")
    elif [ "$dist" -eq "$min_dist" ]; then
      best+=("$m")
    fi
  done <<< "$models_list"
  if [ "${#best[@]}" -gt 0 ]; then
    printf '%s\n' "${best[@]}" | head -3
  fi
}

discover_cli_models() {
  local cli="$1"
  local ts; ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  local supports=false models_json="[]" source="" error_msg=""

  case "$cli" in
    agy)
      if command -v agy >/dev/null 2>&1; then
        local out ec=0
        out=$(agy models 2>&1) || ec=$?
        if [ "$ec" -eq 0 ] && [ -n "$out" ]; then
          local parsed
          parsed=$(printf '%s' "$out" | \
            jq -r '.[].id // .[].name // .[]' 2>/dev/null | \
            grep -v '^$' | jq -R '.' | jq -s '.' 2>/dev/null) || parsed=""
          if [ -z "$parsed" ] || [ "$parsed" = "[]" ]; then
            parsed=$(printf '%s' "$out" | grep -v '^$' | \
              jq -R '.' | jq -s '.' 2>/dev/null) || parsed=""
          fi
          local cnt; cnt=$(printf '%s' "$parsed" | jq 'length' 2>/dev/null) || cnt=0
          if [ "${cnt:-0}" -gt 0 ]; then
            models_json="$parsed"; supports=true; source="agy models"
          else
            error_msg="agy models: could not parse model list from output"
          fi
        else
          error_msg="agy models: exited $ec"
        fi
      else
        error_msg="agy not on PATH"
      fi
      ;;
    copilot)
      error_msg="copilot does not expose a scriptable model list"
      ;;
    claude|codex|gemini)
      error_msg="$cli does not expose a scriptable model list"
      ;;
  esac

  jq -n \
    --arg cli "$cli" \
    --argjson supports "$supports" \
    --argjson models "$models_json" \
    --arg source "$source" \
    --arg ts "$ts" \
    --arg error "$error_msg" \
    '{cli:$cli,supportsModelDiscovery:$supports,models:$models,source:$source,discoveredAt:$ts,error:$error}'
}

load_capability_cache() {
  local cli="$1" caps_dir="$2" max_age_hours="$3"
  local cache_file="$caps_dir/$cli.json"
  [ -f "$cache_file" ] || return 0
  [ "$max_age_hours" -gt 0 ] 2>/dev/null || return 0
  local discovered_at; discovered_at=$(jq -r '.discoveredAt // ""' "$cache_file" 2>/dev/null)
  [ -n "$discovered_at" ] || return 0
  local now_ts file_ts
  now_ts=$(date -u +%s)
  file_ts=$(date -u -d "$discovered_at" +%s 2>/dev/null) || \
    file_ts=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$discovered_at" +%s 2>/dev/null) || return 0
  local age_hours=$(( (now_ts - file_ts) / 3600 ))
  if [ "$age_hours" -lt "$max_age_hours" ]; then
    cat "$cache_file"
  fi
}

save_capability_cache() {
  local cli="$1" caps_dir="$2" caps_json="$3"
  mkdir -p "$caps_dir"
  printf '%s\n' "$caps_json" > "$caps_dir/$cli.json"
}

get_cli_capabilities() {
  local cli="$1" caps_dir="$2" max_age_hours="${3:-24}" refresh="${4:-0}"
  if [ "$refresh" -eq 0 ]; then
    local cached; cached=$(load_capability_cache "$cli" "$caps_dir" "$max_age_hours")
    if [ -n "$cached" ]; then printf '%s' "$cached"; return 0; fi
  fi
  local caps; caps=$(discover_cli_models "$cli")
  save_capability_cache "$cli" "$caps_dir" "$caps"
  printf '%s' "$caps"
}

validate_model_availability() {
  local caps_dir="$1" refresh="$2" policy="$3" cache_hours="$4"
  local had_error=0 i=0 cli model_type
  [ "$policy" = "off" ] && return 0
  while [ "$i" -lt "$TASK_COUNT" ]; do
    local n=$((i + 1))
    cli=$(task_field "$i" "cli" | tr '[:upper:]' '[:lower:]')
    model_type=$(jq -r ".tasks[$i].model | type" "$QUEUE_PATH" 2>/dev/null | tr -d '\r')
    [ "$model_type" = "null" ] && { i=$((i + 1)); continue; }
    local caps; caps=$(get_cli_capabilities "$cli" "$caps_dir" "$cache_hours" "$refresh")
    local supports; supports=$(printf '%s' "$caps" | jq -r '.supportsModelDiscovery')
    local source; source=$(printf '%s' "$caps" | jq -r '.source // ""')
    if [ "$supports" = "true" ]; then
      local available; available=$(printf '%s' "$caps" | jq -r '.models[]' 2>/dev/null)
      local models_to_check; models_to_check=$(get_task_models "$i")
      while IFS= read -r m; do
        [ -z "$m" ] && continue
        if ! printf '%s\n' "$available" | grep -qxF "$m"; then
          local suggestions; suggestions=$(suggest_model_corrections "$m" "$available" | tr '\n' ',' | sed 's/,$//')
          local sug_str=""
          [ -n "$suggestions" ] && sug_str=" (did you mean: ${suggestions}?)"
          case "$policy" in
            strictWhenDiscoverable)
              echo "ERROR: Task $n: model \"$m\" is not available for $cli according to $source${sug_str}" >&2
              had_error=1
              ;;
            warn)
              echo "WARNING: Task $n: model \"$m\" not found in $cli model list (continuing)${sug_str}" >&2
              ;;
          esac
        fi
      done <<< "$models_to_check"
    else
      local err_msg; err_msg=$(printf '%s' "$caps" | jq -r '.error // ""')
      echo "  INFO: Task $n: model validation skipped for $cli ($err_msg)" >&2
    fi
    i=$((i + 1))
  done
  return $had_error
}

probe_cli_model() {
  local cli="$1" model="$2"
  local tmp_dir; tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/limitshift-probe.XXXXXX")
  local model_flag="" out ec=0
  if [ -n "$model" ]; then
    case "$cli" in
      claude)   model_flag="--model $model" ;;
      codex)    model_flag="-m $model" ;;
      gemini)   model_flag="-m $model" ;;
      agy)      model_flag="--model $model" ;;
      copilot)  model_flag="--model $model" ;;
    esac
  fi
  case "$cli" in
    claude)
      out=$(cd "$tmp_dir" && claude --permission-mode viewOnly --output-format json $model_flag \
        -p 'Respond with only: OK' 2>&1) || ec=$?
      ;;
    codex)
      out=$(cd "$tmp_dir" && printf 'Respond with only: OK' | \
        codex exec --json $model_flag --skip-git-repo-check 2>&1) || ec=$?
      ;;
    gemini)
      out=$(cd "$tmp_dir" && printf 'Respond with only: OK' | \
        gemini $model_flag 2>&1) || ec=$?
      ;;
    agy)
      out=$(agy -p 'Respond with only: OK' $model_flag \
        --dangerously-skip-permissions 2>&1) || ec=$?
      ;;
    copilot)
      out=$(printf 'Respond with only: OK' | \
        copilot --name "limitshift-probe" $model_flag --allow-all 2>&1) || ec=$?
      ;;
  esac
  rm -rf "$tmp_dir"
  local label="$cli${model:+ ($model)}"
  if [ "$ec" -eq 0 ]; then
    echo "  INFO: Probe $label: OK"
  else
    echo "  WARNING: Probe $label: failed (exit $ec) — $(printf '%s' "$out" | head -1)"
  fi
}

probe_all_models() {
  echo "--- model probe ---"
  local i=0 cli model
  local -a seen; seen=()
  while [ "$i" -lt "$TASK_COUNT" ]; do
    cli=$(task_field "$i" "cli" | tr '[:upper:]' '[:lower:]')
    local task_has_model=0
    while IFS= read -r model; do
      task_has_model=1
      local key="$cli:$model"
      local already=0 s
      for s in "${seen[@]}"; do [ "$s" = "$key" ] && already=1 && break; done
      if [ "$already" -eq 0 ]; then
        seen+=("$key")
        probe_cli_model "$cli" "$model"
      fi
    done < <(get_task_models "$i")
    if [ "$task_has_model" -eq 0 ]; then
      local key="$cli:"
      local already=0 s
      for s in "${seen[@]}"; do [ "$s" = "$key" ] && already=1 && break; done
      if [ "$already" -eq 0 ]; then
        seen+=("$key")
        probe_cli_model "$cli" ""
      fi
    fi
    i=$((i + 1))
  done
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
  local now; now=$(date +%s)
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
  SESSION_RESET=""; SESSION_TIMEZONE=""
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
  WEEK_RESET=""; WEEK_TIMEZONE=""
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
      if [ "$SESSION_PERCENT" -le "$FRESH_SESSION_THRESHOLD_PERCENT" ]; then session_ready=1; fi
    else
      if [ "$SESSION_PERCENT" -lt 100 ]; then session_ready=1; fi
    fi
    local week_ready=0
    if [ "$WEEK_PERCENT" -lt 100 ]; then week_ready=1; fi
    if [ "$session_ready" -eq 1 ] && [ "$week_ready" -eq 1 ]; then
      write_step "Claude usage is available"
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
    local now; now=$(date +%s)
    local sleep_seconds=$((wake_time - now))
    if [ "$sleep_seconds" -gt 0 ]; then
      ui_rest_with_summary "claude" "$wake_time"
    else
      ui_color "$UI_DIM" "  $GLYPH_DOT reset time already passed; re-checking in ${POLL_SECONDS_AFTER_RESET_PASSED}s"
      printf '\n'
      sleep "$POLL_SECONDS_AFTER_RESET_PASSED"
    fi
  done
}

parse_reset_from_error() {
  local error_text="$1" match
  if [ -z "$error_text" ]; then R_RESET=""; return; fi

  match=$(printf '%s' "$error_text" | grep -oiE '(try again at|resets? at|available (again )?at)[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?' | head -n 1)
  if [ -n "$match" ]; then
    local clock
    clock=$(printf '%s' "$match" | sed -E 's/(try again at|resets? at|available (again )?at)[[:space:]]+//i')
    clock=$(echo "$clock" | awk '{$1=$1;print}')
    local epoch
    if epoch=$(epoch_from_clock "$clock"); then
      R_RESET="$epoch"; return
    fi
  fi
  match=$(printf '%s' "$error_text" | grep -oiE 'try again in[[:space:]]+([0-9]+[[:space:]]*h(ours?)?)?[[:space:]]*([0-9]+[[:space:]]*m(in(utes?)?)?)?[[:space:]]*([0-9]+[[:space:]]*s(ec(onds?)?)?)?' | head -n 1)
  if [ -n "$match" ]; then
    local h=0 min=0 s=0
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*h'; then h=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*h.*/\1/'); fi
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*m'; then min=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*m.*/\1/'); fi
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*s'; then s=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*s.*/\1/'); fi
    local now; now=$(date +%s)
    R_RESET=$((now + h * 3600 + min * 60 + s))
    return
  fi
  match=$(printf '%s' "$error_text" | grep -oiE 'reset after[[:space:]]+([0-9]+[[:space:]]*h)?[[:space:]]*([0-9]+[[:space:]]*m)?[[:space:]]*([0-9]+[[:space:]]*s)?' | head -n 1)
  if [ -n "$match" ]; then
    local h=0 min=0 s=0
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*h'; then h=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*h.*/\1/'); fi
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*m'; then min=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*m.*/\1/'); fi
    if printf '%s' "$match" | grep -qiE '[0-9]+[[:space:]]*s'; then s=$(printf '%s' "$match" | sed -E 's/.*[^0-9]([0-9]+)[[:space:]]*s.*/\1/'); fi
    local now; now=$(date +%s)
    R_RESET=$((now + h * 3600 + min * 60 + s))
    return
  fi
  match=$(printf '%s' "$error_text" | grep -oiE '"retryDelay"[[:space:]]*:[[:space:]]*"[0-9]+s"' | head -n 1)
  if [ -n "$match" ]; then
    local s
    s=$(printf '%s' "$match" | sed -E 's/.*"([0-9]+)s".*/\1/')
    local now; now=$(date +%s)
    R_RESET=$((now + s))
    return
  fi
  R_RESET=""
}

wait_for_limit_reset() {
  local cli="$1" error_text="$2" settings_wait="$3"
  if [ "$cli" = "claude" ]; then
    wait_until_claude_ready 1
    return
  fi
  parse_reset_from_error "$error_text"
  local reset_time="$R_RESET"
  if [ -z "$reset_time" ]; then
    local now; now=$(date +%s)
    reset_time=$((now + settings_wait * 60))
    ui_color "$UI_DIM" "     no reset time in the error $GLYPH_DOT waiting the configured $settings_wait min"
    printf '\n'
  fi
  local wake_time=$((reset_time + RESET_BUFFER_MINUTES * 60))
  # Always call the wrapper, even when the reset is "in 0s" (a real case some CLIs emit and
  # what stubs in the test suite produce). The wrapper prints the "Hit a usage limit" beat
  # regardless and skips the actual sleep when wake_time is already in the past.
  ui_rest_with_summary "$cli" "$wake_time"
}

get_task_key() {
  local idx="$1"
  printf 'task-%02d' $((idx + 1))
}

get_task_slug() {
  local name="$1" slug
  slug=$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
  slug=${slug:0:40}
  slug=$(printf '%s' "$slug" | sed -E 's/-+$//')
  if [ -z "$slug" ]; then slug="task"; fi
  printf '%s' "$slug"
}

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

get_task_fingerprint() {
  local idx="$1"
  local name cli project_path model effort prompt extra_joined us first arg canonical
  name=$(task_field "$idx" "name")
  cli=$(task_field "$idx" "cli" | tr '[:upper:]' '[:lower:]')
  project_path=$(task_field "$idx" "projectPath")
  model=$(get_task_models_joined "$idx")
  effort=$(task_field "$idx" "effort")
  prompt=$(task_field "$idx" "prompt")
  extra_joined=""; first=1
  while IFS= read -r arg; do
    if [ "$first" -eq 1 ]; then extra_joined="$arg"; first=0
    else extra_joined="$extra_joined $arg"
    fi
  done < <(get_task_extra_args "$idx")
  us=$(printf '\037')
  canonical=$(printf '%s%s%s%s%s%s%s%s%s%s%s%s%s' \
    "$name" "$us" "$cli" "$us" "$project_path" "$us" "$model" "$us" "$effort" "$us" "$prompt" "$us" "$extra_joined")

  # Phase 3: include fallbacks in the task fingerprint (Task 3.2).
  local r_count; r_count=$(get_task_runner_count "$idx")
  if [ "$r_count" -gt 1 ]; then
    local rs; rs=$(printf '\036')
    local fb_canonical=""
    local r=1
    while [ "$r" -lt "$r_count" ]; do
      local f_cli f_models f_effort f_extra
      f_cli=$(get_runner_field "$idx" "$r" "cli" | tr '[:upper:]' '[:lower:]')
      f_models=$(get_runner_models_joined "$idx" "$r")
      f_effort=$(get_runner_field "$idx" "$r" "effort")
      f_extra=""; local f_first=1
      while IFS= read -r arg; do
        if [ "$f_first" -eq 1 ]; then f_extra="$arg"; f_first=0
        else f_extra="$f_extra $arg"
        fi
      done < <(get_runner_extra_args "$idx" "$r")
      
      local fb_part
      fb_part=$(printf '%s%s%s%s%s%s%s' "$f_cli" "$us" "$f_models" "$us" "$f_effort" "$us" "$f_extra")
      if [ -z "$fb_canonical" ]; then fb_canonical="$fb_part"
      else fb_canonical="$fb_canonical$rs$fb_part"
      fi
      r=$((r + 1))
    done
    canonical="$canonical$rs$fb_canonical"
  fi

  printf '%s' "$canonical" | sha256_hex
}

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
  if [ -f "$path" ]; then cat "$path"; else printf ''; fi
}

new_task_session_id() {
  local idx="$1" uuid
  if command -v uuidgen >/dev/null 2>&1; then
    uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
  elif [ -f /proc/sys/kernel/random/uuid ]; then
    uuid=$(cat /proc/sys/kernel/random/uuid)
  else
    uuid=$(od -x -N 16 /dev/urandom 2>/dev/null | head -n 1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}')
    if [ -z "$uuid" ]; then uuid="mock-uuid-$RANDOM-$RANDOM"; fi
  fi
  printf '%s' "$uuid" > "$(get_task_session_file_path "$idx")"
  printf '%s' "$uuid"
}

test_task_already_done() {
  local path
  path=$(get_task_done_file_path "$1")
  if [ -f "$path" ]; then return 0; else return 1; fi
}

save_task_done_marker() {
  local path fp
  path=$(get_task_done_file_path "$1")
  fp=$(get_task_fingerprint "$1")
  printf '%s\n%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$fp" > "$path"
}

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
  local path reason fp
  path=$(get_task_failed_file_path "$1")
  reason="$2"
  fp=$(get_task_fingerprint "$1")
  printf '%s\t%s\t%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$fp" "$reason" > "$path"
}

build_cli_args() {
  local idx="$1" mode="$2" session_id="$3" model_override="${4:-}" prompt="${5:-}"
  local cli model effort project_path
  cli=$(task_field "$idx" "cli" | tr '[:upper:]' '[:lower:]')
  if [ -n "$model_override" ]; then
    model="$model_override"
  else
    model=$(get_task_models "$idx" | sed -n '1p')
  fi
  effort=$(task_field "$idx" "effort")
  project_path=$(task_field "$idx" "projectPath")

  CLI_ARGS=()
  CLI_EXE="$cli"

  case "$cli" in
    claude)
      local ollama=0
      if is_ollama_task "$idx"; then ollama=1; fi
      local claude_args=()
      claude_args+=("-p")
      if [ "$mode" = "New" ]; then
        claude_args+=("--session-id" "$session_id")
      elif [ "$mode" = "Resume" ]; then
        claude_args+=("--resume" "$session_id")
      fi
      claude_args+=("--output-format" "json")
      if [ -n "$model" ] && [ "$ollama" -eq 0 ]; then
        claude_args+=("--model" "$model")
      fi
      if [ -n "$effort" ]; then
        claude_args+=("--effort" "$effort")
      fi
      while IFS= read -r arg; do
        if [ -n "$arg" ]; then
          if [ "$ollama" -eq 1 ]; then
            local lower
            lower=$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')
            case "$lower" in
              --oss|--local-provider|ollama) continue ;;
            esac
          fi
          claude_args+=("$arg")
        fi
      done < <(get_task_extra_args "$idx")
      if [ "$ollama" -eq 1 ]; then
        CLI_EXE="ollama"
        CLI_ARGS=("launch" "claude")
        if [ -n "$model" ]; then CLI_ARGS+=("--model" "$model"); fi
        CLI_ARGS+=("--yes" "--")
        CLI_ARGS+=("${claude_args[@]}")
      else
        CLI_ARGS=("${claude_args[@]}")
      fi
      ;;
    codex)
      CLI_ARGS+=("exec")
      if [ "$mode" = "Resume" ]; then
        CLI_ARGS+=("resume" "$session_id")
        get_codex_resume_extra_args "$idx"
      fi
      CLI_ARGS+=("--json")
      if [ -n "$model" ]; then CLI_ARGS+=("-m" "$model"); fi
      if [ -n "$effort" ]; then CLI_ARGS+=("-c" "model_reasoning_effort=$effort"); fi
      if [ "$mode" = "Resume" ]; then
        for arg in "${CODEX_RESUME_EXTRA_ARGS[@]}"; do CLI_ARGS+=("$arg"); done
      else
        while IFS= read -r arg; do
          if [ -n "$arg" ]; then CLI_ARGS+=("$arg"); fi
        done < <(get_task_extra_args "$idx")
      fi
      ;;
    gemini)
      if [ "$mode" = "Resume" ] && [ -n "$session_id" ]; then
        CLI_ARGS+=("--resume=$session_id")
      fi
      CLI_ARGS+=("--output-format" "json")
      if [ -n "$model" ]; then CLI_ARGS+=("-m" "$model"); fi
      while IFS= read -r arg; do
        if [ -n "$arg" ]; then CLI_ARGS+=("$arg"); fi
      done < <(get_task_extra_args "$idx")
      ;;
    agy)
      if [ "$mode" = "Resume" ]; then CLI_ARGS+=("-c"); fi
      CLI_ARGS+=("-p" "$prompt")
      if [ -n "$model" ]; then CLI_ARGS+=("--model" "$model"); fi
      while IFS= read -r arg; do
        if [ -n "$arg" ]; then CLI_ARGS+=("$arg"); fi
      done < <(get_task_extra_args "$idx")
      ;;
    copilot)
      if [ "$mode" = "New" ]; then
        CLI_ARGS+=("--name" "$session_id")
      elif [ "$mode" = "Resume" ]; then
        CLI_ARGS+=("--resume" "$session_id")
      fi
      CLI_ARGS+=("--output-format=json" "--stream=off" "--no-ask-user")
      CLI_ARGS+=("-p" "$prompt")
      if [ -n "$model" ]; then CLI_ARGS+=("--model" "$model"); fi
      if [ -n "$effort" ]; then CLI_ARGS+=("--effort" "$effort"); fi
      while IFS= read -r arg; do
        if [ -n "$arg" ]; then CLI_ARGS+=("$arg"); fi
      done < <(get_task_extra_args "$idx")
      ;;
  esac
}

agy_data_dir() {
  if [ -n "${LIMITSHIFT_AGY_DATA_DIR:-}" ]; then
    printf '%s' "$LIMITSHIFT_AGY_DATA_DIR"
  else
    printf '%s' "$HOME/.gemini/antigravity-cli"
  fi
}

agy_response_from_transcript() {
  local project_path="$1"
  project_path="${project_path%$'\r'}"
  local data_dir cache cid tx k v
  data_dir=$(agy_data_dir)
  cache="$data_dir/cache/last_conversations.json"
  [ -f "$cache" ] || return 0
  cid=""
  while IFS=$'\t' read -r k v; do
    k="${k%$'\r'}"; v="${v%$'\r'}"
    if [ "$k" = "$project_path" ]; then cid="$v"; break; fi
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$cache" 2>/dev/null)
  [ -n "$cid" ] || return 0
  tx="$data_dir/brain/$cid/.system_generated/logs/transcript.jsonl"
  [ -f "$tx" ] || return 0
  jq -rs 'map(select(.type=="PLANNER_RESPONSE" and ((.content // "") != ""))) | (last // {}) | .content // empty' "$tx" 2>/dev/null | tr -d '\r'
}

parse_cli_output() {
  local cli="$1" output="$2" exit_code="$3"
  local combined="${4:-$output}"
  R_OK=1; R_IS_LIMIT=0; R_TEXT=""; R_SESSION_ID=""; R_ERROR_TEXT=""

  local limit_regex=""
  case "$cli" in
    claude) limit_regex='(you'\''ve hit your .{0,40}limit|usage limit)' ;;
    codex)  limit_regex='(usage limit|rate limit|too many requests|try again (at|in)|quota)' ;;
    gemini) limit_regex='(quota exceeded|resource_exhausted|ratelimitexceeded|model_capacity_exhausted|no capacity available|daily quota|usage limit reached|rate limit|429|too many requests)' ;;
    agy)    limit_regex='(quota exceeded|resource_exhausted|model_capacity_exhausted|no capacity available|insufficient quota|out of quota|daily quota|usage limit|rate ?limit|429|too many requests|try again (at|in))' ;;
    copilot) limit_regex='(usage limit|rate limit|too many requests|quota|premium requests|billing|try again at|try again in|429)' ;;
  esac

  case "$cli" in
    claude)
      local clean_json
      clean_json=$(printf '%s' "$output" | sed -n '/^{/,$p')
      if [ -z "$clean_json" ] || ! printf '%s' "$clean_json" | jq empty >/dev/null 2>&1; then
        R_OK=0
        if printf '%s' "$output" | grep -qiE "$limit_regex" >/dev/null 2>&1; then R_IS_LIMIT=1; fi
        R_TEXT="$output"; R_ERROR_TEXT="$output"; return
      fi
      R_TEXT=$(printf '%s' "$clean_json" | jq -r '.result // empty')
      R_SESSION_ID=$(printf '%s' "$clean_json" | jq -r '.session_id // empty')
      local is_error
      is_error=$(printf '%s' "$clean_json" | jq -r '.is_error // empty')
      if [ "$is_error" = "true" ] || [ "$exit_code" -ne 0 ]; then
        R_OK=0
        if printf '%s' "$R_TEXT" | grep -qiE "$limit_regex" >/dev/null 2>&1; then R_IS_LIMIT=1; fi
        R_ERROR_TEXT="$R_TEXT"
      fi
      ;;
    codex)
      local clean_jsonl
      clean_jsonl=$(printf '%s' "$output" | grep -E '^\{')
      if [ -z "$clean_jsonl" ] || ! printf '%s' "$clean_jsonl" | jq -s empty >/dev/null 2>&1; then
        R_OK=0
        if printf '%s' "$output" | grep -qiE "$limit_regex" >/dev/null 2>&1; then R_IS_LIMIT=1; fi
        R_TEXT="$output"; R_ERROR_TEXT="$output"; return
      fi
      R_SESSION_ID=$(printf '%s' "$clean_jsonl" | jq -rs '[.[] | select(.type=="thread.started")] | last | .thread_id // empty')
      R_TEXT=$(printf '%s' "$clean_jsonl" | jq -rs '[.[] | select(.type=="item.completed" and .item.type=="agent_message")] | last | .item.text // empty')
      R_ERROR_TEXT=$(printf '%s' "$clean_jsonl" | jq -rs '[.[] | select(.type=="error")] | last | .message // empty')
      local turn_failed_err
      turn_failed_err=$(printf '%s' "$clean_jsonl" | jq -rs '[.[] | select(.type=="turn.failed")] | last | .error.message // empty')
      if [ -n "$turn_failed_err" ]; then R_ERROR_TEXT="$turn_failed_err"; fi
      if [ -n "$R_ERROR_TEXT" ] || [ "$exit_code" -ne 0 ]; then
        R_OK=0
        if printf '%s %s' "$R_ERROR_TEXT" "$output" | grep -qiE "$limit_regex" >/dev/null 2>&1; then R_IS_LIMIT=1; fi
      fi
      ;;
    gemini)
      local clean_json
      clean_json=$(printf '%s' "$output" | sed -n '/^{/,$p')
      if [ -z "$clean_json" ] || ! printf '%s' "$clean_json" | jq empty >/dev/null 2>&1; then
        R_OK=0
        if printf '%s' "$output" | grep -qiE "$limit_regex" >/dev/null 2>&1; then R_IS_LIMIT=1; fi
        R_TEXT="$output"; R_ERROR_TEXT="$output"; return
      fi
      R_SESSION_ID=$(printf '%s' "$clean_json" | jq -r '.session_id // empty')
      local error_msg error_code
      error_msg=$(printf '%s' "$clean_json" | jq -r '.error.message // empty')
      error_code=$(printf '%s' "$clean_json" | jq -r '.error.code // empty')
      if [ -n "$error_msg" ] && [ "$error_msg" != "null" ]; then
        R_OK=0; R_TEXT="$error_msg"; R_ERROR_TEXT="$error_msg"
        if printf '%s' "$error_msg" | grep -qiE "$limit_regex" >/dev/null 2>&1 || [ "$error_code" = "429" ]; then R_IS_LIMIT=1; fi
      else
        R_TEXT=$(printf '%s' "$clean_json" | jq -r '.response // empty')
        if [ "$exit_code" -ne 0 ]; then R_OK=0; R_ERROR_TEXT="$output"; fi
      fi
      ;;
    agy)
      R_TEXT="$output"
      if [ -z "$output" ]; then
        R_OK=0
        if printf '%s' "$combined" | grep -qiE "$limit_regex" >/dev/null 2>&1; then R_IS_LIMIT=1; fi
        if [ -n "$combined" ]; then R_ERROR_TEXT="$combined"
        else R_ERROR_TEXT="agy produced no capturable response (no transcript reply found and stdout was empty)"
        fi
      fi
      ;;
    copilot)
      local clean_jsonl
      clean_jsonl=$(printf '%s' "$output" | grep -E '^\{')
      if [ -z "$clean_jsonl" ] || ! printf '%s' "$clean_jsonl" | jq -s empty >/dev/null 2>&1; then
        R_OK=0
        if printf '%s' "$output" | grep -qiE "$limit_regex" >/dev/null 2>&1; then R_IS_LIMIT=1; fi
        R_TEXT="$output"; R_ERROR_TEXT="$output"; return
      fi
      R_SESSION_ID=$(printf '%s' "$clean_jsonl" | jq -rs 'map(.interactionId // .session_id // .sessionId // .conversation_id // .conversationId // .thread_id // .threadId // empty) | last // empty')
      R_TEXT=$(printf '%s' "$clean_jsonl" | jq -rs 'map(select(.type=="assistant.message" or .type=="assistant" or .type=="message" or .type=="response" or .type=="completion" or .type=="final" or .role=="assistant") | (.content // .text // .message // (.item.content // .item.text // .item.message // empty))) | map(select(type=="string" and . != "")) | join("")')
      R_ERROR_TEXT=$(printf '%s' "$clean_jsonl" | jq -rs 'map(.error.message // .error.text // .error.detail // (if .type=="error" then (.message // .text // .detail // empty) else empty end) // empty) | last // empty')
      if [ -n "$R_ERROR_TEXT" ] || [ "$exit_code" -ne 0 ]; then
        R_OK=0
        if printf '%s %s' "$R_ERROR_TEXT" "$output" | grep -qiE "$limit_regex" >/dev/null 2>&1; then R_IS_LIMIT=1; fi
        if [ -z "$R_ERROR_TEXT" ]; then R_ERROR_TEXT="$output"; fi
      fi
      ;;
  esac
}

get_marker_status() {
  local text="$1"
  if [ -z "$text" ]; then M_STATUS="None"; M_REASON=""; return; fi
  local last
  last=$(printf '%s' "$text" | awk 'NF{last=$0} END{print last}')
  last=$(printf '%s' "$last" | awk '{$1=$1;print}')
  case "$last" in
    *"$TASK_BLOCKED_MARKER"*)
      M_STATUS="Blocked"
      M_REASON=$(awk -v line="$last" -v marker="$TASK_BLOCKED_MARKER" 'BEGIN{p=index(line,marker); r=substr(line,p+length(marker)); gsub(/^[[:space:]]+|[[:space:]]+$/,"",r); print r}')
      ;;
    *"$TASK_COMPLETE_MARKER"*)
      M_STATUS="Done"; M_REASON=""
      ;;
    *)
      M_STATUS="None"; M_REASON=""
      ;;
  esac
}

invoke_cli_task_run() {
  local idx="$1" mode="$2" session_id="$3" model_override="${4:-}" quiet="${5:-0}"
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

  local marker_block=""
  if [ "$completion_check" = "true" ]; then
    marker_block=$(printf '\n\nIMPORTANT AUTOMATION INSTRUCTIONS:\n1. When and only when this task is fully complete, end your final response with %s as (or at the end of) the very last line:\n%s\n2. If and only if you cannot complete this task, end your final response with this as (or at the end of) the very last line instead, plus a one-line reason:\n%s <one-line reason>' "$TASK_COMPLETE_MARKER" "$TASK_COMPLETE_MARKER" "$TASK_BLOCKED_MARKER")
  fi

  local prompt_with_marker
  if [ "$mode" = "New" ]; then
    if [ "$completion_check" = "true" ]; then
      prompt_with_marker=$(printf '%s%s\n' "$prompt" "$marker_block")
    else
      prompt_with_marker=$(printf '%s' "$prompt")
    fi
  else
    prompt_with_marker=$(printf 'Continue the previous task in this same session from where you stopped. Do not restart from scratch.\nIf the session has no prior progress, start the task now.\n\nOriginal task (for reference — do not redo finished work):\n%s%s\n' "$prompt" "$marker_block")
  fi

  build_cli_args "$idx" "$mode" "$session_id" "$model_override" "$prompt_with_marker"

  if [ "$quiet" -ne 1 ]; then
    ui_task_header "$((idx + 1))" "$UI_TASK_TOTAL" "$cli" "$mode" "$model_override" "$name" "$prompt"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    # Dry-run prints the assembled command at column 0 so it's greppable - the whole point of
    # dry-run is "show me what would run". Format matches the pre-preview-UI style intentionally.
    local cmd_display
    cmd_display=$(printf '%s ' "${CLI_ARGS[@]}" | tr -d '\r' | tr '\n' ' ')
    printf 'Command: %s %s\n' "$CLI_EXE" "${cmd_display% }"
    R_OK=1; R_IS_LIMIT=0; R_TEXT="[dry-run]"; R_SESSION_ID=""; R_ERROR_TEXT=""
    return
  fi
  if [ "$SHOW_RAW" -eq 1 ]; then
    local cmd_display
    cmd_display=$(printf '%s ' "${CLI_ARGS[@]}" | tr -d '\r' | tr '\n' ' ')
    ui_color "$UI_DIM" "  $GLYPH_DOT command: $CLI_EXE ${cmd_display% }"
    printf '\n'
  fi

  printf '%s\n\n' "$prompt_with_marker" >> "$output_file_path"

  # Spinner writes to /dev/tty (when this script's stdout is being teed/piped, the
  # spinner stays on the user's terminal and never reaches the log file).
  ui_spinner_start

  local output_text exit_code agy_stdout=""
  local tmp_out tmp_err
  tmp_out=$(mktemp)
  if [ "$cli" = "agy" ] || [ "$cli" = "copilot" ]; then
    tmp_err=$(mktemp)
    ( cd "$project_path" && "$CLI_EXE" "${CLI_ARGS[@]}" </dev/null ) > "$tmp_out" 2> "$tmp_err"
    exit_code=$?
    if [ "$cli" = "agy" ]; then agy_stdout=$(cat "$tmp_out"); fi
    output_text=$(cat "$tmp_out"; cat "$tmp_err")
    rm -f "$tmp_out" "$tmp_err"
  else
    ( cd "$project_path" && printf '%s' "$prompt_with_marker" | "$CLI_EXE" "${CLI_ARGS[@]}" ) > "$tmp_out" 2>&1
    exit_code=$?
    output_text=$(cat "$tmp_out")
    rm -f "$tmp_out"
  fi

  ui_spinner_stop

  if [ -n "$output_text" ]; then
    printf '%s\n' "$output_text" >> "$output_file_path"
  fi

  if [ "$cli" = "agy" ]; then
    local agy_response
    agy_response=$(agy_response_from_transcript "$project_path")
    if [ -z "$agy_response" ]; then
      sleep 0.3
      agy_response=$(agy_response_from_transcript "$project_path")
    fi
    [ -z "$agy_response" ] && agy_response="$agy_stdout"
    parse_cli_output "$cli" "$agy_response" "$exit_code" "$output_text"
  else
    parse_cli_output "$cli" "$output_text" "$exit_code"
  fi

  # Console display: show the response only on success (or the raw output with --show-raw);
  # failures and limits are reported by the main loop with the new error/blocked layout.
  if [ "$SHOW_RAW" -eq 1 ]; then
    ui_response_header
    printf '%s\n' "$output_text"
  elif [ "$R_OK" -eq 1 ] && [ -n "$R_TEXT" ]; then
    ui_response_header
    ui_body "$R_TEXT" 10
  fi
}

initialize_runner_state() {
  # Migrate legacy state folders to the current name.
  if [ ! -d "$RUNNER_STATE_PATH" ]; then
    if [ "$STUTTERED_STATE_PATH" != "$RUNNER_STATE_PATH" ] && [ -d "$STUTTERED_STATE_PATH" ]; then
      mv "$STUTTERED_STATE_PATH" "$RUNNER_STATE_PATH"
      echo "Migrated state folder limitshift-$RUNNER_NAME -> limitshift-$STATE_NAME"
    elif [ -d "$LEGACY_DOT_STATE_PATH" ]; then
      mv "$LEGACY_DOT_STATE_PATH" "$RUNNER_STATE_PATH"
      echo "Migrated state folder .limitshift-$RUNNER_NAME -> limitshift-$STATE_NAME"
    elif [ -d "$LEGACY_RUNNER_STATE_PATH" ]; then
      mv "$LEGACY_RUNNER_STATE_PATH" "$RUNNER_STATE_PATH"
      echo "Migrated state folder .ai-runner-$RUNNER_NAME -> limitshift-$STATE_NAME"
    fi
  fi
  mkdir -p "$RUNNER_STATE_PATH"
  mkdir -p "$SESSION_STATE_PATH"
  mkdir -p "$OUTPUT_STATE_PATH"
  mkdir -p "$STATUS_STATE_PATH"
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
  Editing a task's name, prompt, cli, projectPath, model, effort, or extraArgs now AUTO-INVALIDATES
  its done marker: the runner notices the change and re-runs that task with a fresh session.
EOF
}

initialize_runs_csv() {
  if [ ! -f "$RUNS_CSV_PATH" ]; then
    printf '%s\n' "$RUNS_CSV_HEADER" > "$RUNS_CSV_PATH"
  fi
}

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

# --- MAIN EXECUTION ----------------------------------------------------------

if [ "$LIMITSHIFT_SOURCE_ONLY" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# Demo runs entirely off the example workflow JSON; no queue loading, no state.
if [ "$DEMO" -eq 1 ]; then
  ui_demo
  exit 0
fi

# Default queue resolution.
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

if [[ "$QUEUE_PATH" != /* ]] && [[ "$QUEUE_PATH" != [a-zA-Z]:\\* ]] && [[ "$QUEUE_PATH" != [a-zA-Z]:/* ]]; then
  if [[ "$QUEUE_PATH" != */* ]] && [[ "$QUEUE_PATH" != *\\* ]]; then
    QUEUE_PATH="$SCRIPT_DIR/$QUEUE_PATH"
  else
    QUEUE_PATH="$(pwd)/$QUEUE_PATH"
  fi
fi

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
# Strip "limitshift-" prefix to avoid stutter (limitshift-limitshift-queue -> limitshift-queue).
STATE_NAME="$RUNNER_NAME"
case "$STATE_NAME" in limitshift-*) STATE_NAME="${STATE_NAME#limitshift-}" ;; esac
RUNNER_STATE_PATH="$QUEUE_DIR/limitshift-$STATE_NAME"
STUTTERED_STATE_PATH="$QUEUE_DIR/limitshift-$RUNNER_NAME"
LEGACY_DOT_STATE_PATH="$QUEUE_DIR/.limitshift-$RUNNER_NAME"
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

read_queue_config

if [ "$VALIDATE_ONLY" -eq 1 ]; then
  check_cli_binaries
  caps_dir="$RUNNER_STATE_PATH/capabilities"
  if ! validate_model_availability "$caps_dir" "$REFRESH_CAPABILITIES" "$MODEL_VALIDATION" "$CAPABILITY_CACHE_HOURS"; then
    exit 2
  fi
  [ "$PROBE_MODELS" -eq 1 ] && probe_all_models
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

LOCK_PATH="$RUNNER_STATE_PATH/limitshift.lock"
if [ -f "$LOCK_PATH" ]; then
  existing_pid=$(cat "$LOCK_PATH" 2>/dev/null || true)
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "ERROR: Another LimitShift process is already running with this queue (PID $existing_pid)." >&2
    echo "       Queue: $QUEUE_PATH" >&2
    echo "       To force-unlock: rm \"$LOCK_PATH\"" >&2
    exit 2
  fi
fi

initialize_runner_state

echo $$ > "$LOCK_PATH"
trap 'ui_spinner_stop; rm -f "$LOCK_PATH"' EXIT

run_queue() {
  UI_TASK_TOTAL=$TASK_COUNT

  local banner_clis=() bi=0
  while [ "$bi" -lt "$TASK_COUNT" ]; do
    banner_clis+=("$(task_field "$bi" "cli")")
    bi=$((bi + 1))
  done
  ui_banner "$TASK_COUNT" "${banner_clis[@]}"
  local started; started=$(date '+%a %H:%M' 2>/dev/null || date)
  ui_color "$UI_DIM" "    started ${started} $GLYPH_DOT ${QUEUE_PATH}"
  printf '\n'
  if [ "$SHOW_RAW" -eq 1 ]; then
    ui_color "$UI_DIM" "    state $GLYPH_DOT ${RUNNER_STATE_PATH}"; printf '\n'
    ui_color "$UI_DIM" "    log   $GLYPH_DOT ${LOG_PATH}"; printf '\n'
  fi

  local doneCount=0 skippedCount=0 failedCount=0 allCompletionCheck=1
  local ci=0
  while [ "$ci" -lt "$TASK_COUNT" ]; do
    if [ "$(task_completion_check "$ci")" != "true" ]; then allCompletionCheck=0; fi
    ci=$((ci + 1))
  done

  local i=0 taskNumber runCount errorRetryCount mustWaitForFreshSession=0
  local savedSessionId sessionId result_ok result_is_limit result_text result_session_id result_error_text
  local taskCompletionCheck stallCount previousNoMarkerText hasPreviousNoMarker currentText
  local taskModels modelCount currentModelIndex currentModel nextModelIndex m

  while [ "$i" -lt "$TASK_COUNT" ]; do
    taskNumber=$((i + 1))

    if [ "$i" -gt 0 ]; then ui_separator; fi

    if test_task_already_done "$i"; then
      local savedFp currentFp
      savedFp=$(get_saved_done_fingerprint "$i")
      currentFp=$(get_task_fingerprint "$i")
      if [ "$savedFp" = "$currentFp" ]; then
        write_step "Skipping task $taskNumber of $TASK_COUNT: $(task_field "$i" "name")"
        echo "Task is already marked as done."
        skippedCount=$((skippedCount + 1))
        i=$((i + 1))
        continue
      fi
      write_step "Re-running task $taskNumber of $TASK_COUNT: $(task_field "$i" "name")"
      echo "Task $taskNumber changed since last run; previous done marker invalidated."
      rm -f "$(get_task_done_file_path "$i")"
      rm -f "$(get_task_session_file_path "$i")"
      rm -f "$(get_task_model_index_file_path "$i")"
    fi

    runCount=0
    errorRetryCount=0
    mustWaitForFreshSession=0
    stallCount=0
    previousNoMarkerText=""
    hasPreviousNoMarker=0
    taskCompletionCheck=$(task_completion_check "$i")

    taskModels=()
    while IFS= read -r m; do taskModels+=("$m"); done < <(get_task_models "$i")
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
      if [ "$task_cli" = "claude" ] && ! is_ollama_task "$i" && [ "$DRY_RUN" -eq 0 ]; then
        wait_until_claude_ready "$mustWaitForFreshSession"
      fi

      if [ "$modelCount" -gt 0 ]; then
        currentModel="${taskModels[$currentModelIndex]}"
      else
        currentModel=""
      fi

      savedSessionId=$(get_saved_task_session_id "$i")

      # Within-run continuations (runCount > 1) suppress the task header — the
      # contextual one-liner printed by the prior iteration IS the resume marker.
      local quietHeader=0
      [ "$runCount" -gt 1 ] && quietHeader=1

      local runMode
      if [ -z "$savedSessionId" ]; then
        runMode="New"
        sessionId=""
        if [ "$task_cli" = "claude" ] || [ "$task_cli" = "agy" ] || [ "$task_cli" = "copilot" ]; then
          sessionId=$(new_task_session_id "$i")
        fi
        invoke_cli_task_run "$i" "New" "$sessionId" "$currentModel" "$quietHeader"
      else
        runMode="Resume"
        invoke_cli_task_run "$i" "Resume" "$savedSessionId" "$currentModel" "$quietHeader"
      fi

      if [ "$DRY_RUN" -eq 1 ]; then
        write_step "Dry run for task $taskNumber recorded the command only"
        break
      fi

      result_ok="$R_OK"
      result_is_limit="$R_IS_LIMIT"
      result_text="$R_TEXT"
      result_session_id="$R_SESSION_ID"
      result_error_text="$R_ERROR_TEXT"

      local runStatus runExit
      if [ "$result_is_limit" -eq 1 ]; then
        runStatus="Limit"
      elif [ "$result_ok" -eq 0 ]; then
        runStatus="Error"
      elif [ "$taskCompletionCheck" != "true" ]; then
        runStatus="Done"
      else
        get_marker_status "$result_text"
        if [ "$M_STATUS" = "Done" ]; then runStatus="Done"
        elif [ "$M_STATUS" = "Blocked" ]; then runStatus="Blocked"
        else runStatus="NoMarker"
        fi
      fi
      if [ "$result_ok" -eq 0 ]; then runExit=1; else runExit=0; fi
      add_runs_csv_row "$taskNumber-$(task_field "$i" "name")" "$runCount" "$runMode" "$runExit" "$runStatus"

      if [ -n "$result_session_id" ]; then
        printf '%s' "$result_session_id" > "$(get_task_session_file_path "$i")"
      fi

      if [ "$task_cli" = "gemini" ] && [ "$result_ok" -eq 0 ] && \
         printf '%s' "$result_error_text" | grep -qiE 'unknown option.*resume|not supported in non-interactive|unexpected argument|too many arguments|invalid.*resume'; then
        rm -f "$(get_task_session_file_path "$i")"
        write_step "Task $taskNumber: installed gemini rejects --resume; retrying with continuation prompt only"
        continue
      fi

      if [ "$result_is_limit" -eq 1 ]; then
        if [ "$modelCount" -gt 1 ] && [ "$currentModelIndex" -lt "$((modelCount - 1))" ]; then
          nextModelIndex=$((currentModelIndex + 1))
          write_step "Task $taskNumber: limit on ${taskModels[$currentModelIndex]}; switching to ${taskModels[$nextModelIndex]}"
          currentModelIndex=$nextModelIndex
          save_task_model_index "$i" "$currentModelIndex"
          continue
        fi
        if [ "$modelCount" -gt 1 ]; then
          currentModelIndex=0
          save_task_model_index "$i" "$currentModelIndex"
        fi
        mustWaitForFreshSession=1
        # Past-tense beat is printed by ui_rest_with_summary AFTER the rest ends.
        wait_for_limit_reset "$task_cli" "$result_error_text" "$LIMIT_WAIT_MINUTES"
        continue
      fi

      if [ "$result_ok" -eq 0 ]; then
        errorRetryCount=$((errorRetryCount + 1))
        printf '\n'
        ui_color "$UI_RED" "  $GLYPH_ERR Task $taskNumber hit an error:"
        printf '\n'
        ui_reason "$result_error_text"
        if [ "$errorRetryCount" -le "$MAX_RETRIES_ON_ERROR" ]; then
          printf '\n'
          ui_color "$UI_YELLOW" "  $GLYPH_RETRY retry $errorRetryCount of $MAX_RETRIES_ON_ERROR for Task $taskNumber/$TASK_COUNT $GLYPH_DOT $(task_field "$i" "name") $GLYPH_DOT resume"
          printf '\n'
          continue
        fi
        if [ "$STOP_ON_ERROR" = "true" ]; then
          echo "ERROR: Task $taskNumber failed after $MAX_RETRIES_ON_ERROR retries: $result_error_text" >&2
          exit 1
        fi
        printf '\n'
        ui_color "$UI_RED" "  $GLYPH_ERR Task $taskNumber gave up after $MAX_RETRIES_ON_ERROR retries $GLYPH_DOT moving to the next task"
        printf '\n'
        failedCount=$((failedCount + 1))
        break
      fi

      if [ "$taskCompletionCheck" != "true" ]; then
        save_task_done_marker "$i"
        ui_task_done "$taskNumber"
        doneCount=$((doneCount + 1))
        break
      fi

      get_marker_status "$result_text"
      if [ "$M_STATUS" = "Done" ]; then
        save_task_done_marker "$i"
        ui_task_done "$taskNumber"
        doneCount=$((doneCount + 1))
        break
      fi
      if [ "$M_STATUS" = "Blocked" ]; then
        save_task_failed_marker "$i" "$M_REASON"
        printf '\n'
        ui_color "$UI_YELLOW" "  $GLYPH_ERR Task $taskNumber is blocked:"
        printf '\n'
        ui_reason "$M_REASON"
        if [ "$STOP_ON_ERROR" = "true" ]; then
          echo "ERROR: Task $taskNumber is blocked: $M_REASON" >&2
          exit 1
        fi
        failedCount=$((failedCount + 1))
        break
      fi

      currentText="$result_text"
      if [ "$hasPreviousNoMarker" -eq 1 ] && [ "$currentText" = "$previousNoMarkerText" ]; then
        stallCount=$((stallCount + 1))
        if [ "$stallCount" -ge "$MAX_STALLS" ]; then
          save_task_failed_marker "$i" "no progress: agent repeated the same response without a completion marker"
          printf '\n'
          ui_color "$UI_RED" "  $GLYPH_ERR Task $taskNumber failed:"
          printf '\n'
          ui_reason "no progress: agent repeated the same response without a completion marker"
          if [ "$STOP_ON_ERROR" = "true" ]; then
            echo "ERROR: Task $taskNumber failed: no progress: agent repeated the same response without a completion marker" >&2
            exit 1
          fi
          failedCount=$((failedCount + 1))
          break
        fi
      fi
      previousNoMarkerText="$currentText"
      hasPreviousNoMarker=1

      mustWaitForFreshSession=0
      printf '\n'
      ui_color "$UI_DIM" "  $GLYPH_RETRY Task $taskNumber/$TASK_COUNT $GLYPH_DOT $(task_field "$i" "name") not finished yet $GLYPH_DOT resuming the same session"
      printf '\n'
    done

    i=$((i + 1))
  done

  ui_summary "$TASK_COUNT" "$doneCount" "$failedCount" "$skippedCount" "$allCompletionCheck" "$LOG_PATH" "$RUNNER_STATE_PATH" "$DRY_RUN"
}

# Run the queue and tee output to the log. The spinner writes to /dev/tty so its
# frames never reach the tee'd log file.
run_queue 2>&1 | tee -a "$LOG_PATH"
