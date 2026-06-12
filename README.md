# LimitShift

LimitShift is a lightweight queue runner designed to execute long-running prompt queues against modern AI developer CLI tools: Claude Code (`claude`), Codex (`codex`), and Gemini CLI (`gemini`). It manages task state, resumes conversation sessions, parses structured JSON/JSONL outputs, and handles usage/rate limit cooldowns automatically. Start a massive batch of prompts before bed and review completed files in the morning.

## How It Works

LimitShift executes prompts sequentially from a JSON task queue.

```
+-------------------------------------------------------------+
|                     Read Queue Config                       |
+-------------------------------------------------------------+
                               |
                               v
                       [ Next Task ]
                               |
                               v
                      Does Task Exist? ---> (No) ---> [ Done ]
                               | (Yes)
                               v
                    Already marked done? ---> (Yes) ---> [ Skip ]
                               | (No)
                               v
                       Execute CLI Run
                               |
                               +-----------------------+
                               |                       |
                               v                       v
                          (Success)                 (Error)
                               |                       |
                  +------------+------------+          v
                  |                         |      Is Limit?
                  v                         v      /   \
          Contains Done?            Contains Block?       /     \
             /       \                 /       \      (Yes)     (No)
         (Yes)       (No)          (Yes)       (No)     |         |
           |           |             |           |      v         v
           v           v             v           v    Wait    Retry/Stop
       Mark Done   Resume Session  Mark Failed  Resume
```

1. **Initialize State**: Creates output, session, and status directories.
2. **Load Queue**: Reads the JSON file and parses configuration settings.
3. **Task Loop**: Checks if each task has a `.done` marker. If yes, it skips.
4. **Execution**: Builds task arguments, navigates to the project directory, and runs the CLI.
5. **Output Parsing**: Extracts structured assistant output, session/thread IDs, and error events.
6. **Limit Wait**: If a usage rate limit is hit, parses the wake time and sleeps until reset.
7. **Idempotent Continuation**: Resumes incomplete sessions automatically or transitions to next task upon completion.

## Requirements

- **Windows**: Windows PowerShell 5.1+
- **macOS / Linux**: Bash 3.2+, and the `jq` JSON utility (`brew install jq` or `sudo apt install jq`).
- **AI CLIs**: The target CLIs must be installed and logged in:
  - `claude` (Anthropic Claude Code, tested with version 2.1.170)
  - `codex` (OpenAI Codex CLI, tested with version 0.136.0)
  - `gemini` (Google Gemini CLI, tested with version 0.46.0)
- **Interactive Trust**: You must run each CLI once interactively in every target project directory to accept any onboarding/workspace trust prompts before using LimitShift headless.

## Installation

Download or clone the files to your machine. No build or install step is required.

- **Windows**: Allow script execution if restricted:
  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  Unblock-File .\run-ai.ps1
  ```
- **macOS / Linux**: Mark script as executable:
  ```bash
  chmod +x run-ai.sh
  ```

## Configuration Reference

The queue is configured using `ai-run-queue.json`. Below is the property reference:

| Field | Type | Required? | Default | Description |
|---|---|---|---|---|
| `settings.stopOnError` | Boolean | No | `true` | Stop entire queue if a task fails after retries |
| `settings.maxRunsPerTask` | Integer | No | `20` | Maximum resumes/runs allowed for a single task |
| `settings.maxRetriesOnError` | Integer | No | `2` | Number of times to retry a task on transient error |
| `settings.limitWaitMinutes` | Integer | No | `30` | Default sleep time when rate limits do not publish reset time |
| `settings.resetBufferMinutes` | Integer | No | `2` | Grace buffer minutes added to parsed reset wake times |
| `tasks` | Array | Yes | N/A | List of tasks to run |
| `tasks[].name` | String | Yes | N/A | Unique task identifier |
| `tasks[].cli` | String | Yes | N/A | CLI to use (`claude`, `codex`, `gemini`) |
| `tasks[].projectPath` | String | Yes | N/A | Absolute or relative path to the workspace |
| `tasks[].prompt` | String | Yes | N/A | Initial prompt text |
| `tasks[].model` | String | No | `null` | Custom model argument overrides |
| `tasks[].effort` | String | No | `null` | Effort/reasoning overrides (`low`, `medium`, `high`) |
| `tasks[].extraArgs` | String/Array| No | `null` | Custom CLI arguments |

### Path Escaping on Windows
Since Windows paths contain backslashes, escape them in your JSON:
- **Wrong**: `"projectPath": "C:\Users\me\projects\app"`
- **Right**: `"projectPath": "C:\\Users\\me\\projects\\app"`

## Per-CLI Behavior

| CLI | Execution Mode | Resume Session | Limit Detection |
|---|---|---|---|
| **claude** | Native JSON | Native session resume (`--resume <session-id>`) | Parses native `/usage` for exact session and weekly resets |
| **codex** | JSONL events | Thread resume (`resume <thread-id>`) | Parses JSONL error messages and calculates sleep time |
| **gemini** | JSON object | Continuation prompt framing | Parses JSON errors and falls back to `limitWaitMinutes` |

## Permissions Warning

Headless execution runs without active user monitoring, meaning prompt instructions will automatically run shell commands.
- For **Claude**, add `--permission-mode acceptEdits` or `--dangerously-skip-permissions` in `extraArgs` if desired.
- For **Codex**, use `--dangerously-bypass-approvals-and-sandbox` or sandbox configurations.
- For **Gemini**, specify `--approval-mode auto_edit` or `--yolo`.

> [!CAUTION]
> Granting full automation permissions carries risk. Always execute queues on clean, version-controlled repositories so changes are easy to review or revert.

## Running

- **Windows**:
  ```powershell
  .\run-ai.ps1 --queue my-queue.json
  ```
- **macOS / Linux**:
  ```bash
  ./run-ai.sh --queue my-queue.json
  ```

### Keep Machine Awake
Ensure your computer does not suspend or drop network connection mid-run:
- **macOS**: Wrap running command in caffeinate:
  ```bash
  caffeinate -i ./run-ai.sh
  ```
- **Windows**: Use `presentationsettings` to prevent sleep.

## State and Logs

LimitShift creates a `.ai-runner-<queue-name>` folder in the same directory as your queue file:
- `/sessions/`: Persists session IDs and Codex thread IDs.
- `/outputs/`: Log outputs from each prompt execution.
- `/status/`: `.done` files indicating completed runs, and `.failed` files indicating blocked runs.
- `ai-run-log.txt`: Runner event log.

To force-retry a completed task, delete its `.done` file from the status folder.

## Completion Marker

Tasks must end with `[[TASK_COMPLETE]]` on their own line to be marked complete. LimitShift automatically appends instructions telling the LLM to output this when done. Ensure your prompt provides concrete completion criteria so the agent knows when to stop.

If an agent determines a task is impossible, it will write `[[TASK_BLOCKED]] <reason>` which halts execution or moves on based on your settings.

## Troubleshooting

| Error Message | Cause | Solution |
|---|---|---|
| `Config file is not valid JSON` | Typo, trailing comma, or bad quotes in queue JSON | Run the validator, check trailing commas |
| `missing required JSON property` | A task is missing name, cli, projectPath, or prompt | Ensure all 4 fields exist in every task |
| `unknown cli` | CLI field has an unsupported value | Allowed: `claude`, `codex`, `gemini` |
| `Project path does not exist` | Invalid or mistyped folder path | Check folder path, escape backslashes on Windows |
| `not found on PATH` | Target CLI binary is not installed | Install the CLI using NPM / package manager |
| `exceeded maxRunsPerTask` | Agent is stuck in a loop without completing | Review prompts, increase limit, or fix code |

## Running the Tests

- **PowerShell**:
  ```powershell
  Invoke-Pester tests/run-ai.Tests.ps1
  ```
- **Bash**:
  ```bash
  bash tests/test-run-ai.sh
  ```

## License

This project is licensed under the [MIT License](LICENSE).
