param(
    [string]$QueuePath,
    [switch]$ValidateOnly,
    [switch]$DryRun,
    [switch]$ShowRawOutput,
    [switch]$LoadFunctionsOnly,
    [switch]$RefreshCapabilities,
    [switch]$ProbeModels
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Utf8Encoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = $Utf8Encoding
[Console]::OutputEncoding = $Utf8Encoding
$OutputEncoding = $Utf8Encoding

# Default-queue resolution and the state-path derivations below touch the filesystem (Test-Path)
# and can emit the legacy-queue warning. Skip the whole block when only loading functions for tests
# so dot-sourcing with -LoadFunctionsOnly has zero filesystem side effects. These script-level path
# variables are only consumed on a real run, which never happens under -LoadFunctionsOnly.
if (-not $LoadFunctionsOnly) {
    # Task 5.2: the default queue file is limitshift-queue.json; the old ai-run-queue.json is still
    # accepted as a fallback for one release. When no explicit -QueuePath is given, look for the new
    # name first, then the old one (warning if the legacy name is used). If neither exists, default
    # to the new name so the "not found / copy the example" message references the current filename.
    if ([string]::IsNullOrWhiteSpace($QueuePath)) {
        $newDefaultQueue = Join-Path $PSScriptRoot 'limitshift-queue.json'
        $legacyDefaultQueue = Join-Path $PSScriptRoot 'ai-run-queue.json'
        if (Test-Path -LiteralPath $newDefaultQueue) {
            $QueuePath = $newDefaultQueue
        }
        elseif (Test-Path -LiteralPath $legacyDefaultQueue) {
            $QueuePath = $legacyDefaultQueue
            [Console]::Error.WriteLine('Using legacy queue filename ai-run-queue.json; rename to limitshift-queue.json')
        }
        else {
            $QueuePath = $newDefaultQueue
        }
    }

    # A bare filename (no directory separator) resolves from the script's directory so that
    # `-QueuePath surgemesh-queue.json` is equivalent to placing the file next to the script.
    # A relative path WITH separators resolves from the current working directory.
    if ($QueuePath -notmatch '[/\\]') {
        $QueuePath = Join-Path $PSScriptRoot $QueuePath
    } else {
        $QueuePath = [System.IO.Path]::GetFullPath($QueuePath)
    }
    $QueueRootPath = Split-Path -Parent $QueuePath
    $QueueName = [System.IO.Path]::GetFileNameWithoutExtension($QueuePath)
    $RunnerName = $QueueName -replace '[^A-Za-z0-9._-]', '-'
    # Task 5.3: state folder is now .limitshift-<name>; the old .ai-runner-<name> folder is migrated
    # (renamed) automatically on startup when it exists and the new one does not.
    $RunnerStatePath = Join-Path $QueueRootPath ".limitshift-$RunnerName"
    $LegacyRunnerStatePath = Join-Path $QueueRootPath ".ai-runner-$RunnerName"
    $SessionStatePath = Join-Path $RunnerStatePath "sessions"
    $OutputStatePath = Join-Path $RunnerStatePath "outputs"
    $StatusStatePath = Join-Path $RunnerStatePath "status"
    $LogPath = Join-Path $RunnerStatePath "limitshift-log.txt"
    $UsagePath = Join-Path $RunnerStatePath "claude-usage-last.txt"
    $RunsCsvPath = Join-Path $RunnerStatePath "runs.csv"
    $StateReadmePath = Join-Path $RunnerStatePath "_README.txt"
    $LockPath = Join-Path $RunnerStatePath 'limitshift.lock'
}

$RunsCsvHeader = "timestamp,task,run,mode,exit,status"

$FreshSessionThresholdPercent = 0
$PollSecondsAfterResetPassed = 60

$TaskCompleteMarker = "[[TASK_COMPLETE]]"
$TaskBlockedMarker  = "[[TASK_BLOCKED]]"

function Write-Step {
    param([string]$Message)

    Write-Host ""
    Write-Host "==== $Message ===="
    Write-Host ""
}

function New-DirectoryIfMissing {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Initialize-RunnerState {
    # Task 5.3: migrate an old-named state folder (.ai-runner-<name>) to the new name
    # (.limitshift-<name>) automatically when the old one exists and the new one does not.
    if ((Test-Path -LiteralPath $LegacyRunnerStatePath) -and -not (Test-Path -LiteralPath $RunnerStatePath)) {
        Move-Item -LiteralPath $LegacyRunnerStatePath -Destination $RunnerStatePath
        Write-Host "Migrated state folder .ai-runner-$RunnerName -> .limitshift-$RunnerName"
    }

    New-DirectoryIfMissing -Path $RunnerStatePath
    New-DirectoryIfMissing -Path $SessionStatePath
    New-DirectoryIfMissing -Path $OutputStatePath
    New-DirectoryIfMissing -Path $StatusStatePath

    # Task 4: drop a self-explaining README inside the state folder (overwritten every init),
    # and make sure runs.csv has its header row.
    Write-StateReadme
    Initialize-RunsCsv
}

function Write-StateReadme {
    $readme = @"
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
"@
    Set-Content -LiteralPath $StateReadmePath -Value $readme -Encoding UTF8
}

function Initialize-RunsCsv {
    if (-not (Test-Path -LiteralPath $RunsCsvPath)) {
        Set-Content -LiteralPath $RunsCsvPath -Value $RunsCsvHeader -Encoding UTF8
    }
}

# Task 4: append one CSV row per CLI run. Fields are escaped with ConvertTo-CsvField so a task
# name containing commas or quotes cannot break the column layout.
function Add-RunsCsvRow {
    param(
        [string]$Task,
        [int]$Run,
        [string]$Mode,
        $Exit,
        [string]$Status
    )

    $row = @(
        (ConvertTo-CsvField -Value ((Get-Date).ToString('s'))),
        (ConvertTo-CsvField -Value $Task),
        (ConvertTo-CsvField -Value ([string]$Run)),
        (ConvertTo-CsvField -Value $Mode),
        (ConvertTo-CsvField -Value ([string]$Exit)),
        (ConvertTo-CsvField -Value $Status)
    ) -join ','

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($RunsCsvPath, $row + [Environment]::NewLine, $utf8NoBom)
}

$AllowedClis = @('claude', 'codex', 'gemini', 'agy', 'copilot')

# Local-model (Ollama) support. A task targets a local Ollama model when its extraArgs carry the
# provider marker (`--oss` / `--local-provider ollama`) — the same flags codex understands natively.
# codex passes them straight through; claude has no native Ollama flag, so LimitShift runs it via
# `ollama launch claude --model <model> --yes -- <claude args>`. Keep one config shape for both CLIs.
$OllamaControlArgs = @('--oss', '--local-provider', 'ollama')

function Test-ExtraArgsRequestOllama {
    param([string[]]$ExtraArgs)
    if ($null -eq $ExtraArgs) { return $false }
    foreach ($a in $ExtraArgs) {
        $t = ([string]$a).Trim().ToLowerInvariant()
        if ($t -eq 'ollama' -or $t -eq '--oss') { return $true }
    }
    return $false
}

# Only claude needs the `ollama launch` wrapper; codex reaches Ollama on its own, so it is never
# "ollama mode" for the purposes of executable/arg rewriting.
function Test-IsOllamaTask {
    param($Task)
    if ($Task.Cli -ne 'claude') { return $false }
    return (Test-ExtraArgsRequestOllama -ExtraArgs $Task.ExtraArgs)
}

function Remove-OllamaControlArgs {
    param([string[]]$ExtraArgs)
    if ($null -eq $ExtraArgs) { return @() }
    return @($ExtraArgs | Where-Object {
        $OllamaControlArgs -notcontains (([string]$_).Trim().ToLowerInvariant())
    })
}

function Get-CliExecutable {
    param($Task)
    if (Test-IsOllamaTask -Task $Task) { return 'ollama' }
    return $Task.Cli
}

function Read-QueueConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path`nCopy limitshift-queue.example.json to limitshift-queue.json and fill in your tasks."
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try {
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        throw ("Config file is not valid JSON: $Path`n" +
               "Parser said: $($_.Exception.Message)`n" +
               "Common causes: a trailing comma after the last item, a missing comma between items, " +
               "an unescaped backslash in a Windows path (write \\ not \), or an unescaped `"quote`" inside a prompt.")
    }

    $defaults = @{
        StopOnError           = $true
        MaxRunsPerTask        = 20
        MaxRetriesOnError     = 2
        LimitWaitMinutes      = 30
        ResetBufferMinutes    = 2
        CompletionCheck       = $true
        MaxStalls             = 2
        ModelValidation       = 'strictWhenDiscoverable'
        CapabilityCacheHours  = 24
        ProbeModels           = $false
    }
    $settings = $defaults.Clone()
    $settingsNode = $parsed.PSObject.Properties['settings']
    if ($null -ne $settingsNode -and $null -ne $settingsNode.Value) {
        foreach ($key in @($defaults.Keys)) {
            $jsonKey = $key.Substring(0,1).ToLower() + $key.Substring(1)
            $prop = $settingsNode.Value.PSObject.Properties[$jsonKey]
            if ($null -ne $prop -and $null -ne $prop.Value) { $settings[$key] = $prop.Value }
        }
    }

    $tasksNode = $parsed.PSObject.Properties['tasks']
    if ($null -eq $tasksNode) { throw "Config file has no `"tasks`" array: $Path" }
    $rawTasks = @($tasksNode.Value)
    if ($rawTasks.Count -eq 0) { throw "Config file contains no tasks: $Path" }

    $tasks = @()
    for ($i = 0; $i -lt $rawTasks.Count; $i++) {
        $t = $rawTasks[$i]
        $n = $i + 1

        foreach ($required in @('name', 'cli', 'projectPath', 'prompt')) {
            $p = $t.PSObject.Properties[$required]
            if ($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.Value)) {
                throw "Task $n is missing required JSON property: $required"
            }
        }

        $cli = ([string]$t.cli).ToLower()
        if ($AllowedClis -notcontains $cli) {
            throw "Task $n has unknown cli `"$($t.cli)`". Allowed values: $($AllowedClis -join ', ')"
        }

        $projectPath = $t.projectPath
        if (-not [System.IO.Path]::IsPathRooted($projectPath)) {
            $projectPath = Join-Path (Get-Location) $projectPath
        }
        $projectPath = [System.IO.Path]::GetFullPath($projectPath)
        if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) {
            throw "Project path does not exist for task $n (`"$($t.name)`"): $projectPath"
        }

        $extraArgs = [string[]]@()
        $extraNode = $t.PSObject.Properties['extraArgs']
        if ($null -ne $extraNode -and $null -ne $extraNode.Value) {
            if ($extraNode.Value -is [string]) {
                $extraArgs = [string[]]@($extraNode.Value -split '\s+' | Where-Object { $_ })
            }
            elseif ($extraNode.Value -is [System.Array]) {
                $extraArgs = [string[]]@($extraNode.Value | ForEach-Object { [string]$_ })
            }
            else {
                throw "Task $n extraArgs must be a string or an array of strings."
            }
        }

        # Task 6: model may be a single string OR an ordered array of strings (preference order).
        # Parse it into an ordered list (Models). A single string becomes a 1-element list; Model
        # scalar stays = the first element for back-compat (fingerprint, .Model readers).
        $models = [string[]]@()
        $modelNode = $t.PSObject.Properties['model']
        if ($null -ne $modelNode -and $null -ne $modelNode.Value) {
            $modelValue = $modelNode.Value
            if ($modelValue -is [string]) {
                $models = [string[]]@($modelValue)
            }
            elseif ($modelValue -is [System.Array]) {
                if (@($modelValue).Count -eq 0) {
                    throw "Task $n model array must not be empty. Use a single string, or list one or more model names in preference order."
                }
                foreach ($element in $modelValue) {
                    if ($null -eq $element -or -not ($element -is [string])) {
                        throw "Task $n model array must contain only strings (got a non-string element)."
                    }
                }
                $models = [string[]]@($modelValue | ForEach-Object { [string]$_ })
            }
            else {
                throw "Task $n model must be a string or an array of strings."
            }
        }
        $model = if ($models.Count -gt 0) { $models[0] } else { $null }

        # Local Ollama mode (claude): the model is selected by `ollama launch --model`, so it is
        # required. (codex reaches Ollama natively and needs no model-for-launcher.)
        if ($cli -eq 'claude' -and (Test-ExtraArgsRequestOllama -ExtraArgs $extraArgs) -and $models.Count -eq 0) {
            throw "Task ${n}: a local Ollama claude task needs a model (it is passed to 'ollama launch --model'). Set `"model`" to your Ollama model, e.g. `"qwen3.5:9b`"."
        }

        # Effort normalization: treat absent, JSON null, and "" all as "no effort" (null).
        $effort = $null
        if ($t.PSObject.Properties['effort'] -and $null -ne $t.effort) {
            $effortText = ([string]$t.effort).Trim()
            if ($effortText.Length -gt 0) { $effort = $effortText }
        }

        # Task 6b: enforce the SAME per-CLI effort rules the schema declares (editor-only), so a
        # misconfigured queue fails at validation (exit 2) instead of mid-run. Runs AFTER the
        # required-field checks above so a missing cli is reported first.
        if ($null -ne $effort) {
            switch ($cli) {
                'gemini' {
                    throw "Task ${n}: gemini has no effort flag; set `"effort`": null (use thinkingLevel/thinkingBudget via gemini settings instead)."
                }
                'agy' {
                    throw "Task ${n}: agy (Antigravity CLI) has no --effort flag; set `"effort`": null."
                }
                'claude' {
                    $claudeEfforts = @('low', 'medium', 'high', 'xhigh', 'max')
                    if ($effort -eq 'ultracode') {
                        throw "Task ${n}: 'ultracode' is only available from the interactive /effort menu, not the --effort flag. Use low|medium|high|xhigh|max."
                    }
                    if ($claudeEfforts -notcontains $effort) {
                        throw "Task ${n}: claude effort must be one of low, medium, high, xhigh, max (or null)."
                    }
                    # Haiku 4.5 supports no effort. Model may be a list (Task 6): reject if ANY matches haiku.
                    $haikuMatch = @($models | Where-Object { $_ -match '(?i)haiku' }).Count -gt 0
                    if ($haikuMatch) {
                        throw "Task ${n}: claude model haiku does not support effort; set `"effort`": null."
                    }
                }
                'codex' {
                    $codexEfforts = @('minimal', 'low', 'medium', 'high', 'xhigh')
                    if ($codexEfforts -notcontains $effort) {
                        throw "Task ${n}: codex effort must be one of minimal, low, medium, high, xhigh (or null). 'none' is plan-mode only."
                    }
                }
                'copilot' {
                    $copilotEfforts = @('low', 'medium', 'high', 'xhigh', 'max')
                    if ($copilotEfforts -notcontains $effort) {
                        throw "Task ${n}: copilot effort must be one of low, medium, high, xhigh, max (or null)."
                    }
                }
            }
        }

        # completionCheck: per-task override beats the global setting, which defaults to true.
        $completionCheck = [bool]$settings['CompletionCheck']
        $completionCheckNode = $t.PSObject.Properties['completionCheck']
        if ($null -ne $completionCheckNode -and $null -ne $completionCheckNode.Value) {
            $completionCheck = [bool]$completionCheckNode.Value
        }

        $tasks += [pscustomobject]@{
            Name            = [string]$t.name
            Cli             = $cli
            ProjectPath     = $projectPath
            Model           = $model
            Models          = $models
            Effort          = $effort
            Prompt          = [string]$t.prompt
            ExtraArgs       = $extraArgs
            CompletionCheck = $completionCheck
        }
    }

    return @{ Settings = $settings; Tasks = $tasks }
}

function Test-CliBinariesAvailable {
    param($Tasks)

    $needed = @()
    foreach ($t in $Tasks) {
        $needed += $t.Cli
        # A claude task targeting a local Ollama model is launched via `ollama`, so it must be present too.
        if (Test-IsOllamaTask -Task $t) { $needed += 'ollama' }
    }

    $missing = @()
    foreach ($cli in ($needed | Sort-Object -Unique)) {
        if (-not (Get-Command $cli -ErrorAction SilentlyContinue)) {
            $missing += $cli
        }
    }
    if ($missing.Count -gt 0) {
        throw ("The following CLI(s) are used in the queue but not found on PATH: $($missing -join ', ')`n" +
               "Install instructions:`n" +
               "  claude : npm install -g @anthropic-ai/claude-code`n" +
               "  codex  : npm install -g @openai/codex`n" +
               "  gemini : npm install -g @google/gemini-cli`n" +
               "  agy    : irm https://antigravity.google/cli/install.ps1 | iex   (Antigravity CLI; macOS/Linux: curl -fsSL https://antigravity.google/cli/install.sh | bash)`n" +
               "  copilot: install GitHub Copilot CLI and run: copilot login`n" +
               "  ollama : https://ollama.com/download  (only needed for local models)")
    }
}


function Get-TaskKey {
    param([int]$TaskIndex)

    return ("task-{0:d2}" -f ($TaskIndex + 1))
}

# Task 4: slugify a task name for the output filename. Keep the original case, replace any
# run of characters outside [A-Za-z0-9._-] with a single dash, trim leading/trailing dashes,
# and cap the length at 40. Mirrored byte-for-byte in limitshift.sh (get_task_slug).
function Get-TaskSlug {
    param([string]$Name)

    if ($null -eq $Name) { $Name = '' }
    $slug = [regex]::Replace($Name, '[^A-Za-z0-9._-]+', '-')
    $slug = $slug.Trim('-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    if ([string]::IsNullOrEmpty($slug)) { $slug = 'task' }
    return $slug
}

# Task 4 canonical task fingerprint.
# PURPOSE: detect when a task's definition changed since it was last marked done, so the task
#   re-runs. The fingerprint is consistent and stable WITHIN this runner on one machine. It is
#   NOT intended to match limitshift.sh's fingerprint or be portable across machines: ProjectPath is
#   normalized to an absolute, OS-specific native path here (limitshift.sh hashes the raw JSON value),
#   so the two runners produce different hashes. Within-runner self-consistency is the only
#   requirement. Keep the algorithm (fields, order, separator, lowercase hex) exactly as below.
#   CANONICAL FORMAT:
#   fields, in this exact order:  Name, Cli, ProjectPath, Model, Effort, Prompt, ExtraArgs-joined
#   ExtraArgs-joined = the args joined by a single space (" ").
#   Model (Task 6) = the task's model LIST joined by a single space (" "). A single-string model is
#     a 1-element list, so it canonicalizes to exactly that string — identical to the pre-Task-6
#     fingerprint of a plain-string model. limitshift.sh joins the model list the same way (space),
#     so both runners agree on the model contribution for a given queue.
#   null/empty Model/Effort contribute an empty string.
#   joined with the ASCII unit separator U+001F (0x1F), which is unlikely to appear in any value.
#   SHA256 of the UTF-8 bytes of that string, rendered as lowercase hex.
function Get-TaskFingerprint {
    param($Task)

    $us = [char]0x1f
    $extraArgs = @($Task.ExtraArgs)
    $extraJoined = ($extraArgs -join ' ')
    # Task 6: the canonical model field is the space-joined model list. Fall back to the Model
    # scalar for task objects that predate the Models property (e.g. older test fixtures).
    $modelsProp = $Task.PSObject.Properties['Models']
    if ($null -ne $modelsProp -and $null -ne $modelsProp.Value -and @($modelsProp.Value).Count -gt 0) {
        $model = (@($modelsProp.Value) -join ' ')
    }
    elseif ($null -ne $Task.Model) {
        $model = [string]$Task.Model
    }
    else {
        $model = ''
    }
    $effort = if ($null -ne $Task.Effort) { [string]$Task.Effort } else { '' }

    $canonical = @(
        [string]$Task.Name,
        [string]$Task.Cli,
        [string]$Task.ProjectPath,
        $model,
        $effort,
        [string]$Task.Prompt,
        $extraJoined
    ) -join $us

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return (([System.BitConverter]::ToString($hash)) -replace '-', '').ToLowerInvariant()
}

# Task 4: minimal RFC-4180-style CSV field quoting. A field is wrapped in double quotes (and
# its embedded quotes doubled) only when it contains a comma, a quote, or a newline.
function ConvertTo-CsvField {
    param([string]$Value)

    if ($null -eq $Value) { $Value = '' }
    if ($Value -match '[",\r\n]') {
        return '"' + ($Value -replace '"', '""') + '"'
    }
    return $Value
}

function Get-TaskSessionFilePath {
    param([int]$TaskIndex)

    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    return Join-Path $SessionStatePath "$taskKey-session-id.txt"
}

# Task 6: per-task model-rotation index, persisted so a restart keeps its place in the model list.
function Get-TaskModelIndexFilePath {
    param([int]$TaskIndex)

    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    return Join-Path $SessionStatePath "$taskKey-model-index.txt"
}

function Get-SavedTaskModelIndex {
    param([int]$TaskIndex)

    $path = Get-TaskModelIndexFilePath -TaskIndex $TaskIndex
    if (Test-Path -LiteralPath $path) {
        $raw = (Get-Content -LiteralPath $path -Raw).Trim()
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
    }
    return 0
}

function Save-TaskModelIndex {
    param([int]$TaskIndex, [int]$ModelIndex)

    $path = Get-TaskModelIndexFilePath -TaskIndex $TaskIndex
    [string]$ModelIndex | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-TaskOutputFilePath {
    param(
        [int]$TaskIndex,
        $Task
    )

    # Task 4: name the output file with the zero-padded index AND a slug of the task name,
    # e.g. task-03-fix-the-thing-output.txt. Identical pattern in limitshift.sh.
    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    $slug = if ($null -ne $Task) { Get-TaskSlug -Name $Task.Name } else { 'task' }
    return Join-Path $OutputStatePath "$taskKey-$slug-output.txt"
}

function Get-TaskDoneFilePath {
    param([int]$TaskIndex)

    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    return Join-Path $StatusStatePath "$taskKey.done"
}

function Get-SavedTaskSessionId {
    param([int]$TaskIndex)

    $sessionFilePath = Get-TaskSessionFilePath -TaskIndex $TaskIndex

    if (Test-Path -LiteralPath $sessionFilePath) {
        return (Get-Content -LiteralPath $sessionFilePath -Raw).Trim()
    }

    return $null
}

function New-TaskSessionId {
    param([int]$TaskIndex)

    $sessionId = [guid]::NewGuid().ToString()
    $sessionFilePath = Get-TaskSessionFilePath -TaskIndex $TaskIndex

    $sessionId | Set-Content -LiteralPath $sessionFilePath -Encoding UTF8

    return $sessionId
}

function Test-TaskAlreadyDone {
    param([int]$TaskIndex)

    $doneFilePath = Get-TaskDoneFilePath -TaskIndex $TaskIndex
    return (Test-Path -LiteralPath $doneFilePath)
}

# Task 4: read the fingerprint line out of a .done file (line 2 of the timestamp/fingerprint
# pair). Returns $null when the file is missing or has no fingerprint line (older markers).
function Get-SavedDoneFingerprint {
    param([int]$TaskIndex)

    $doneFilePath = Get-TaskDoneFilePath -TaskIndex $TaskIndex
    if (-not (Test-Path -LiteralPath $doneFilePath)) { return $null }
    $lines = @(Get-Content -LiteralPath $doneFilePath)
    if ($lines.Count -ge 2) { return ([string]$lines[1]).Trim() }
    return $null
}

function Save-TaskDoneMarker {
    param([int]$TaskIndex, $Task)

    # Task 4: the .done file stores two lines — an ISO timestamp then the task fingerprint.
    $doneFilePath = Get-TaskDoneFilePath -TaskIndex $TaskIndex
    $fingerprint = Get-TaskFingerprint -Task $Task
    @((Get-Date).ToString("s"), $fingerprint) | Set-Content -LiteralPath $doneFilePath -Encoding UTF8
}

function Convert-ClaudeResetTextToDateTime {
    param([string]$ResetText)

    $clean = ($ResetText -replace "\s+", " ").Trim()
    $year = (Get-Date).Year
    $withYear = "$clean $year"
    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    $formats = @(
        "MMM d, htt yyyy",
        "MMM d, h:mmtt yyyy",
        "MMM dd, htt yyyy",
        "MMM dd, h:mmtt yyyy"
    )

    foreach ($format in $formats) {
        try {
            $parsed = [datetime]::ParseExact(
                $withYear,
                $format,
                $culture,
                [System.Globalization.DateTimeStyles]::None
            )

            if ($parsed -lt (Get-Date).AddMinutes(-5)) {
                $parsed = $parsed.AddYears(1)
            }

            return $parsed
        }
        catch {
        }
    }

    return $null
}

function Get-ClaudeUsage {
    Write-Step "Checking Claude usage"

    $usageOutput = & claude -p "/usage" 2>&1
    $usageExitCode = $LASTEXITCODE
    $usageText = $usageOutput | Out-String

    [System.IO.File]::WriteAllText($UsagePath, $usageText, [System.Text.UTF8Encoding]::new($false))

    if ($usageExitCode -ne 0) {
        throw "Claude /usage failed with exit code $usageExitCode.`n$usageText"
    }

    $sessionMatch = [regex]::Match(
        $usageText,
        'Current session:\s*(\d+)% used(?:[^\r\n]*?resets\s*([^\r\n(]+)\s*\(([^)]+)\))?',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $sessionMatch.Success) {
        throw "Could not parse Claude session usage from /usage output.`n$usageText"
    }

    $weekMatch = [regex]::Match(
        $usageText,
        'Current week \(all models\):\s*(\d+)% used(?:[^\r\n]*?resets\s*([^\r\n(]+)\s*\(([^)]+)\))?',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $weekMatch.Success) {
        throw "Could not parse Claude weekly usage from /usage output.`n$usageText"
    }

    $sessionPercent = [int]$sessionMatch.Groups[1].Value
    $sessionResetText = if ($sessionMatch.Groups[2].Success) { $sessionMatch.Groups[2].Value.Trim() } else { $null }
    $sessionTimezone = if ($sessionMatch.Groups[3].Success) { $sessionMatch.Groups[3].Value.Trim() } else { $null }
    $sessionReset = if ($null -ne $sessionResetText) { Convert-ClaudeResetTextToDateTime -ResetText $sessionResetText } else { $null }

    $weekPercent = [int]$weekMatch.Groups[1].Value
    $weekResetText = if ($weekMatch.Groups[2].Success) { $weekMatch.Groups[2].Value.Trim() } else { $null }
    $weekTimezone = if ($weekMatch.Groups[3].Success) { $weekMatch.Groups[3].Value.Trim() } else { $null }
    $weekReset = if ($null -ne $weekResetText) { Convert-ClaudeResetTextToDateTime -ResetText $weekResetText } else { $null }

    if ($null -eq $sessionReset -and $sessionPercent -ge 100) {
        throw "Could not parse Claude session reset time from /usage output.`n$usageText"
    }

    if ($null -eq $weekReset -and $weekPercent -ge 100) {
        throw "Could not parse Claude weekly reset time from /usage output.`n$usageText"
    }

    Write-Host "Claude usage command exit code: $usageExitCode"
    Write-Host "Session usage: $sessionPercent%"
    Write-Host "Session reset: $(if ($null -ne $sessionReset) { "$sessionReset ($sessionTimezone)" } else { "N/A" })"
    Write-Host "Week usage: $weekPercent%"
    Write-Host "Week reset: $(if ($null -ne $weekReset) { "$weekReset ($weekTimezone)" } else { "N/A" })"

    return @{
        Text            = $usageText
        ExitCode        = $usageExitCode
        SessionPercent  = $sessionPercent
        SessionReset    = $sessionReset
        SessionTimezone = $sessionTimezone
        WeekPercent     = $weekPercent
        WeekReset       = $weekReset
        WeekTimezone    = $weekTimezone
    }
}

function Test-ClaudeSessionExhausted {
    param($Usage)

    return ($null -ne $Usage.SessionPercent -and $Usage.SessionPercent -ge 100)
}

function Test-ClaudeWeekExhausted {
    param($Usage)

    return ($null -ne $Usage.WeekPercent -and $Usage.WeekPercent -ge 100)
}

function Get-ClaudeResetToWaitFor {
    param(
        $Usage,
        [switch]$RequireFreshSession
    )

    if (Test-ClaudeWeekExhausted -Usage $Usage) {
        return $Usage.WeekReset
    }

    if (Test-ClaudeSessionExhausted -Usage $Usage) {
        return $Usage.SessionReset
    }

    if ($RequireFreshSession -and $Usage.SessionPercent -gt $FreshSessionThresholdPercent) {
        return $Usage.SessionReset
    }

    return $null
}

function Wait-UntilClaudeUsageReady {
    param([switch]$RequireFreshSession)

    while ($true) {
        $usage = Get-ClaudeUsage

        if ($RequireFreshSession) {
            $sessionReady = ($usage.SessionPercent -le $FreshSessionThresholdPercent)
        }
        else {
            $sessionReady = ($usage.SessionPercent -lt 100)
        }

        $weekReady = ($usage.WeekPercent -lt 100)

        if ($sessionReady -and $weekReady) {
            Write-Step "Claude usage is available"
            Write-Host "Current session usage: $($usage.SessionPercent)%"
            Write-Host "Current weekly usage: $($usage.WeekPercent)%"
            return
        }

        $resetToWaitFor = Get-ClaudeResetToWaitFor -Usage $usage -RequireFreshSession:$RequireFreshSession

        if ($null -eq $resetToWaitFor) {
            throw "Claude usage is not ready, but no reset time could be determined."
        }

        $wakeTime = $resetToWaitFor.AddMinutes($ResetBufferMinutes)
        $sleepSeconds = [int]($wakeTime - (Get-Date)).TotalSeconds

        if ($sleepSeconds -gt 0) {
            Write-Step "Waiting for Claude reset"
            Write-Host "Sleeping until: $wakeTime"
            Start-Sleep -Seconds $sleepSeconds
        }
        else {
            Write-Step "Reset time already passed"
            Write-Host "Checking usage again in $PollSecondsAfterResetPassed seconds"
            Start-Sleep -Seconds $PollSecondsAfterResetPassed
        }
    }
}

function Get-CompletionMarkerInstructions {
    return @"
IMPORTANT AUTOMATION INSTRUCTIONS:
1. When and only when this task is fully complete, end your final response with $TaskCompleteMarker as (or at the end of) the very last line:
$TaskCompleteMarker
2. If and only if you cannot complete this task, end your final response with this as (or at the end of) the very last line instead, plus a one-line reason:
$TaskBlockedMarker <one-line reason>
"@
}

function Get-TaskPromptWithCompletionMarker {
    param($Task)

    # Simple mode: send the prompt verbatim, nothing appended.
    if (-not $Task.CompletionCheck) {
        return [string]$Task.Prompt
    }

    return @"
$($Task.Prompt)

$(Get-CompletionMarkerInstructions)
"@
}

function Get-ResumePrompt {
    param($Task)

    # The marker block is only appended when completion checking is on (Task 2).
    $markerBlock = if ($Task.CompletionCheck) { "`n`n" + (Get-CompletionMarkerInstructions) } else { '' }

    # Task 3 (Bug C): one unified resume template for all three CLIs. The resume prompt now
    # repeats the original task verbatim so a thin session and slash commands (e.g. /goal)
    # survive the resume instead of leaving the agent with nothing to continue.
    return @"
Continue the previous task in this same session from where you stopped. Do not restart from scratch.
If the session has no prior progress, start the task now.

Original task (for reference — do not redo finished work):
$($Task.Prompt)$markerBlock
"@
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]$Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Get-CodexResumeExtraArgs {
    param([string[]]$ExtraArgs)

    if ($null -eq $ExtraArgs -or $ExtraArgs.Count -eq 0) {
        return @()
    }

    $filteredArgs = @()
    for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
        $arg = [string]$ExtraArgs[$i]

        if ($arg -match '^(--sandbox|-s|--cd|-C|--add-dir)$') {
            if ($i + 1 -lt $ExtraArgs.Count) {
                $i++
            }
            continue
        }

        if ($arg -match '^(--sandbox=|--cd=|--add-dir=)' -or $arg -match '^-C=') {
            continue
        }

        $filteredArgs += $arg
    }

    return $filteredArgs
}

function Format-CommandForDisplay {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    $renderedArgs = foreach ($arg in $Arguments) {
        $text = [string]$arg
        $text = $text -replace "`r", '' -replace "`n", '\n'
        if ($text -match '[\s"]') {
            '"' + ($text -replace '"', '\"') + '"'
        }
        else {
            $text
        }
    }

    return (($Command + ' ' + ($renderedArgs -join ' ')).Trim())
}

# Build a single Windows command-line string from an argument array, quoting per the standard
# CommandLineToArgvW rules (the "Everyone quotes command line arguments the wrong way" algorithm).
# Start-Process -ArgumentList given an *array* joins with spaces and does NOT quote elements that
# contain spaces, so a path like "C:\Program Files\..." or a project folder with a space splits.
# Passing a single pre-quoted string instead makes Start-Process use it verbatim as the command line.
function ConvertTo-WindowsArgString {
    param([string[]]$Arguments)

    $parts = foreach ($arg in @($Arguments)) {
        $s = [string]$arg
        if ($s.Length -gt 0 -and $s -notmatch '[ \t\n\r\v"]') {
            $s
        }
        else {
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append('"')
            for ($i = 0; $i -lt $s.Length; $i++) {
                $backslashes = 0
                while ($i -lt $s.Length -and $s[$i] -eq '\') { $backslashes++; $i++ }
                if ($i -eq $s.Length) {
                    [void]$sb.Append('\', $backslashes * 2)
                    break
                }
                elseif ($s[$i] -eq '"') {
                    [void]$sb.Append('\', $backslashes * 2 + 1)
                    [void]$sb.Append('"')
                }
                else {
                    [void]$sb.Append('\', $backslashes)
                    [void]$sb.Append($s[$i])
                }
            }
            [void]$sb.Append('"')
            $sb.ToString()
        }
    }

    return ($parts -join ' ')
}

function Invoke-NativeProcess {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$StdinText
    )

    $commandInfo = Get-Command $Command -ErrorAction Stop
    $commandPath = if (-not [string]::IsNullOrWhiteSpace($commandInfo.Source)) {
        $commandInfo.Source
    }
    elseif (-not [string]::IsNullOrWhiteSpace($commandInfo.Path)) {
        $commandInfo.Path
    }
    else {
        $Command
    }

    $launcherPath = $commandPath
    $launcherArguments = $null
    $wrapperPath = $null
    $argumentsPath = $null
    $extension = [System.IO.Path]::GetExtension($commandPath).ToLowerInvariant()

    # Shim launchers (.ps1/.cmd/.bat — e.g. the npm wrappers for codex/gemini) cannot be
    # Start-Process'd with arbitrary args directly, so we ferry the args through a JSON file and
    # re-apply them inside a child PowerShell. Those CLIs receive their prompt on stdin, so their
    # argument list is simple. Native executables (the claude winget shim, agy.exe) take a single
    # canonical command-line string instead — see the else branch.
    if (@('.ps1', '.cmd', '.bat') -contains $extension) {
        $wrapperPath = Join-Path ([System.IO.Path]::GetTempPath()) ("limitshift-wrapper-" + [guid]::NewGuid() + ".ps1")
        $argumentsPath = Join-Path ([System.IO.Path]::GetTempPath()) ("limitshift-args-" + [guid]::NewGuid() + ".json")

        @($Arguments) | ConvertTo-Json -Compress -Depth 4 | Set-Content -LiteralPath $argumentsPath -Encoding UTF8
@"
param(
    [string]`$CommandPath,
    [string]`$ArgumentsPath,
    [string]`$WorkingDirectory
)

`$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath `$WorkingDirectory

`$arguments = @()
if (Test-Path -LiteralPath `$ArgumentsPath) {
    `$decoded = Get-Content -LiteralPath `$ArgumentsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (`$null -ne `$decoded) {
        `$arguments = @(`$decoded | ForEach-Object { [string]`$_ })
    }
}

& `$CommandPath @arguments
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $wrapperPath -Encoding UTF8

        $launcherPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        # Single quoted string (not an array): the wrapper path, command path, and working directory
        # may all contain spaces, and Start-Process only honours quoting when ArgumentList is one string.
        $launcherArguments = ConvertTo-WindowsArgString -Arguments @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $wrapperPath,
            '-CommandPath', $commandPath,
            '-ArgumentsPath', $argumentsPath,
            '-WorkingDirectory', $WorkingDirectory
        )
    }
    else {
        # Native executable (claude winget shim, agy.exe, ...): pass a single canonical command-line
        # string so spaces, quotes, and newlines in arguments survive CreateProcess / CommandLineToArgvW.
        # This is what lets agy carry its whole multi-line prompt as the value of -p.
        $launcherArguments = ConvertTo-WindowsArgString -Arguments @($Arguments)
    }

    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("limitshift-stdout-" + [guid]::NewGuid() + ".txt")
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("limitshift-stderr-" + [guid]::NewGuid() + ".txt")
    $stdinPath = $null

    try {
        $startProcessParams = @{
            FilePath               = $launcherPath
            WorkingDirectory       = $WorkingDirectory
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError  = $stderrPath
        }
        # Start-Process rejects an empty/null ArgumentList; only add it when there are real args.
        if (-not [string]::IsNullOrEmpty($launcherArguments)) {
            $startProcessParams['ArgumentList'] = $launcherArguments
        }

        if ($PSBoundParameters.ContainsKey('StdinText') -and $null -ne $StdinText) {
            $stdinPath = Join-Path ([System.IO.Path]::GetTempPath()) ("limitshift-stdin-" + [guid]::NewGuid() + ".txt")
            [System.IO.File]::WriteAllText($stdinPath, $StdinText, [System.Text.UTF8Encoding]::new($false))
            $startProcessParams['RedirectStandardInput'] = $stdinPath
        }

        $process = Start-Process @startProcessParams

        $stdout = if (Test-Path -LiteralPath $stdoutPath) {
            [System.IO.File]::ReadAllText($stdoutPath)
        }
        else {
            ''
        }

        $stderr = if (Test-Path -LiteralPath $stderrPath) {
            [System.IO.File]::ReadAllText($stderrPath)
        }
        else {
            ''
        }

        $parts = @()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) { $parts += $stdout.TrimEnd("`r", "`n") }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { $parts += $stderr.TrimEnd("`r", "`n") }

        return @{
            ExitCode   = $process.ExitCode
            StdOut     = $stdout
            StdErr     = $stderr
            OutputText = ($parts -join [Environment]::NewLine)
        }
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($stdoutPath)) {
            Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        }
        if (-not [string]::IsNullOrWhiteSpace($stderrPath)) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
        if (-not [string]::IsNullOrWhiteSpace($wrapperPath)) {
            Remove-Item -LiteralPath $wrapperPath -Force -ErrorAction SilentlyContinue
        }
        if (-not [string]::IsNullOrWhiteSpace($argumentsPath)) {
            Remove-Item -LiteralPath $argumentsPath -Force -ErrorAction SilentlyContinue
        }
        if (-not [string]::IsNullOrWhiteSpace($stdinPath)) {
            Remove-Item -LiteralPath $stdinPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-MarkerStatus {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @{ Status = 'None'; Reason = $null } }
    $lines = @($Text -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -eq 0) { return @{ Status = 'None'; Reason = $null } }
    $last = [string]$lines[-1]

    # Loosened detection (Task 2.2): the marker only has to be CONTAINED in the last
    # non-empty line, not be the whole line. Blocked is checked first so a line that
    # mentions both markers is treated as blocked.
    $blockedIndex = $last.IndexOf($TaskBlockedMarker)
    if ($blockedIndex -ge 0) {
        $reason = $last.Substring($blockedIndex + $TaskBlockedMarker.Length).Trim()
        return @{ Status = 'Blocked'; Reason = $reason }
    }
    if ($last.Contains($TaskCompleteMarker)) { return @{ Status = 'Done'; Reason = $null } }
    return @{ Status = 'None'; Reason = $null }
}

function Save-TaskFailedMarker {
    param([int]$TaskIndex, [string]$Reason, $Task)

    # Task 4: store timestamp<TAB>fingerprint<TAB>reason. The reason keeps its own column so the
    # existing reason text is preserved verbatim. The fingerprint is empty when no task is given.
    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    $fingerprint = if ($null -ne $Task) { Get-TaskFingerprint -Task $Task } else { '' }
    "$((Get-Date).ToString('s'))`t$fingerprint`t$Reason" |
        Set-Content -LiteralPath (Join-Path $StatusStatePath "$taskKey.failed") -Encoding UTF8
}

# For claude/codex/gemini the prompt is intentionally NOT part of the argument list: it is
# delivered via stdin (see Invoke-NativeProcess -StdinText). Passing multi-line prompts as process
# arguments truncates them on Windows (Start-Process + cmd shim layers cannot carry embedded
# newlines). agy is the exception: it has no stdin prompt mode (`-p` REQUIRES its value), so the
# prompt is passed as the -p argument. agy.exe is a native executable, so Invoke-NativeProcess passes
# its arguments as a single canonical command-line string (ConvertTo-WindowsArgString) — that is what
# carries the multi-line -p value through CreateProcess / CommandLineToArgvW intact.
function Get-CliArguments {
    param(
        $Task,
        [ValidateSet('New', 'Resume')] [string]$Mode,
        [string]$SessionId,
        # Task 6: the current rotation model. When omitted, fall back to $Task.Model (the first
        # model in the list). The caller (the task loop) passes Models[currentModelIndex].
        [string]$ModelOverride,
        # agy/copilot only: the prompt becomes the value of -p (the other CLIs receive it on stdin).
        [string]$Prompt
    )

    $model = if ($PSBoundParameters.ContainsKey('ModelOverride') -and -not [string]::IsNullOrWhiteSpace($ModelOverride)) {
        $ModelOverride
    }
    else {
        $Task.Model
    }

    switch ($Task.Cli) {
        'claude' {
            # Local Ollama mode: claude has no native Ollama flag, so when extraArgs request the
            # ollama provider we run claude through `ollama launch claude --model <m> --yes -- <args>`.
            # The model goes to the launcher's --model (not claude's), and the ollama control tokens
            # (--oss / --local-provider ollama) are stripped from what claude itself receives.
            $ollama = Test-IsOllamaTask -Task $Task
            $cliArgs = @('-p')
            if ($Mode -eq 'New')    { $cliArgs += @('--session-id', $SessionId) }
            if ($Mode -eq 'Resume') { $cliArgs += @('--resume', $SessionId) }
            $cliArgs += @('--output-format', 'json')
            if ($model -and -not $ollama) { $cliArgs += @('--model', $model) }
            if ($Task.Effort) { $cliArgs += @('--effort', $Task.Effort) }
            if ($ollama) {
                $cliArgs += @(Remove-OllamaControlArgs -ExtraArgs $Task.ExtraArgs)
                $launcher = @('launch', 'claude')
                if ($model) { $launcher += @('--model', $model) }
                $launcher += @('--yes', '--')
                return $launcher + $cliArgs
            }
            $cliArgs += $Task.ExtraArgs
            return $cliArgs
        }
        'codex' {
            $cliArgs = @('exec')
            $codexExtraArgs = if ($Mode -eq 'Resume') {
                @(Get-CodexResumeExtraArgs -ExtraArgs $Task.ExtraArgs)
            }
            else {
                @($Task.ExtraArgs)
            }

            if ($Mode -eq 'Resume') { $cliArgs += @('resume', $SessionId) }
            $cliArgs += @('--json')
            if ($model)       { $cliArgs += @('-m', $model) }
            if ($Task.Effort) { $cliArgs += @('-c', "model_reasoning_effort=$($Task.Effort)") }
            $cliArgs += $codexExtraArgs
            return $cliArgs
        }
        'gemini' {
            # gemini never carries effort here: Read-QueueConfig rejects gemini+effort at validation (Task 6b).
            $cliArgs = @()
            if ($Mode -eq 'Resume' -and -not [string]::IsNullOrWhiteSpace($SessionId)) {
                $cliArgs += @('--resume', $SessionId)
            }
            $cliArgs += @('--output-format', 'json')
            if ($model) { $cliArgs += @('-m', $model) }
            $cliArgs += $Task.ExtraArgs
            return $cliArgs
        }
        'agy' {
            # Antigravity CLI: no JSON output and no per-conversation session ids. The prompt is the
            # value of -p (agy does not read it from stdin); resume continues the most recent
            # conversation with -c (there is no id to pass). No effort flag (rejected at validation).
            $cliArgs = @()
            if ($Mode -eq 'Resume') { $cliArgs += '-c' }
            $cliArgs += @('-p', $Prompt)
            if ($model) { $cliArgs += @('--model', $model) }
            $cliArgs += $Task.ExtraArgs
            return $cliArgs
        }
        'copilot' {
            # GitHub Copilot CLI: prompt via -p, JSONL output. New runs use --name; resumes use --resume.
            $cliArgs = @()
            if ($Mode -eq 'New')    { $cliArgs += @('--name', $SessionId) }
            if ($Mode -eq 'Resume') { $cliArgs += "--resume=$SessionId" }
            $cliArgs += @('--output-format=json', '--stream=off', '--no-ask-user')
            $cliArgs += @('-p', $Prompt)
            if ($model)       { $cliArgs += @('--model', $model) }
            if ($Task.Effort) { $cliArgs += @('--effort', $Task.Effort) }
            $cliArgs += $Task.ExtraArgs
            return $cliArgs
        }
    }
    throw "No argument builder for cli '$($Task.Cli)'"
}

function New-CliResult {
    param([bool]$Ok, [bool]$IsLimit, [string]$Text, [string]$SessionId, [string]$ErrorText)
    return @{ Ok = $Ok; IsLimit = $IsLimit; Text = $Text; SessionId = $SessionId; ErrorText = $ErrorText }
}

# Decide what to show on the console for a run (Task 2b). The full raw output still goes to
# the per-task output file; the console shows only the agent's parsed response (or the error),
# falling back to the raw output when there is nothing parsed (so failures stay debuggable).
function Get-ConsoleOutputText {
    param(
        $Result,
        [string]$RawOutput,
        [switch]$ShowRawOutput
    )

    if ($ShowRawOutput) { return $RawOutput }

    if ($Result.Ok) {
        if (-not [string]::IsNullOrEmpty($Result.Text)) { return $Result.Text }
    }
    else {
        if (-not [string]::IsNullOrEmpty($Result.ErrorText)) { return $Result.ErrorText }
        if (-not [string]::IsNullOrEmpty($Result.Text)) { return $Result.Text }
    }

    return $RawOutput
}

function ConvertFrom-JsonTolerant {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $trimmed = $Text.Trim()
    if (($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) -or
        ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        try { return ($trimmed | ConvertFrom-Json) } catch { }
    }
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        $candidate = $Text.Substring($start, $end - $start + 1)
        try { return ($candidate | ConvertFrom-Json) } catch { }
    }
    return $null
}

# agy (Antigravity CLI) has no JSON/stdout output mode: in -p/--print it renders the reply to a
# TTY, so a redirected/captured stdout is empty. agy DOES persist every turn as plain JSONL, so
# LimitShift recovers the response from agy's own conversation store instead of from stdout:
#   <dataDir>/cache/last_conversations.json    maps an absolute workspace path -> conversation id
#   <dataDir>/brain/<id>/.system_generated/logs/transcript.jsonl   one JSON object per turn; the
#       agent's user-facing reply is the `content` of the last {"type":"PLANNER_RESPONSE"} line.
# dataDir defaults to ~/.gemini/antigravity-cli (override with LIMITSHIFT_AGY_DATA_DIR, e.g. in tests).
function Get-AgyDataDir {
    $override = [Environment]::GetEnvironmentVariable('LIMITSHIFT_AGY_DATA_DIR')
    if (-not [string]::IsNullOrWhiteSpace($override)) { return $override }
    return (Join-Path $HOME '.gemini/antigravity-cli')
}

function Get-AgyResponseFromTranscript {
    param([string]$ProjectPath, [string]$DataDir)

    if ([string]::IsNullOrWhiteSpace($DataDir)) { $DataDir = Get-AgyDataDir }
    $cacheFile = Join-Path $DataDir 'cache/last_conversations.json'
    if (-not (Test-Path -LiteralPath $cacheFile)) { return $null }

    $cache = $null
    try { $cache = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if ($null -eq $cache) { return $null }

    # Keys are agy's absolute workspace paths; match the task's project path (exact, then case-insensitive).
    $cid = $null
    foreach ($p in $cache.PSObject.Properties) {
        if ($p.Name -eq $ProjectPath) { $cid = [string]$p.Value; break }
    }
    if ([string]::IsNullOrWhiteSpace($cid)) {
        foreach ($p in $cache.PSObject.Properties) {
            if ($p.Name -ieq $ProjectPath) { $cid = [string]$p.Value; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($cid)) { return $null }

    $tx = Join-Path $DataDir "brain/$cid/.system_generated/logs/transcript.jsonl"
    if (-not (Test-Path -LiteralPath $tx)) { return $null }

    # The latest PLANNER_RESPONSE with non-empty content is the agent's most recent reply (after a
    # resume the transcript has grown, so the LAST one is what this run produced).
    $resp = $null
    foreach ($line in (Get-Content -LiteralPath $tx -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        $typeProp = $obj.PSObject.Properties['type']
        if ($null -eq $typeProp -or ([string]$typeProp.Value) -ne 'PLANNER_RESPONSE') { continue }
        $contentProp = $obj.PSObject.Properties['content']
        if ($null -ne $contentProp -and -not [string]::IsNullOrWhiteSpace([string]$contentProp.Value)) {
            $resp = [string]$contentProp.Value
        }
    }
    return $resp
}

function ConvertFrom-CliOutput {
    param(
        [ValidateSet('claude','codex','gemini','agy','copilot')] [string]$Cli,
        [string]$OutputText,
        [int]$ExitCode,
        # agy only: its plain-text response on stdout, captured separately from stderr so a trailing
        # diagnostic line cannot displace the agent's [[TASK_COMPLETE]] last line. Optional/empty for
        # the JSON CLIs (they parse $OutputText directly).
        [string]$StdOut
    )

    $LimitPatterns = @{
        claude = '(?i)(you''ve hit your .{0,40}limit|usage limit)'
        codex  = '(?i)(usage limit|rate limit|too many requests|try again (at|in)|quota)'
        gemini = '(?i)(quota exceeded|resource_exhausted|ratelimitexceeded|model_capacity_exhausted|no capacity available|daily quota|usage limit reached|rate limit|429|too many requests)'
        agy    = '(?i)(quota exceeded|resource_exhausted|model_capacity_exhausted|no capacity available|insufficient quota|out of quota|daily quota|usage limit|rate ?limit|429|too many requests|try again (at|in))'
        copilot = '(?i)(usage limit|rate limit|too many requests|quota|premium requests|billing|try again at|try again in|429)'
    }

    $limitRegex = $LimitPatterns[$Cli]

    switch ($Cli) {
        'claude' {
            $json = ConvertFrom-JsonTolerant -Text $OutputText
            if ($null -eq $json) {
                $isLimit = ($OutputText -match $limitRegex)
                return New-CliResult -Ok $false -IsLimit $isLimit -Text $OutputText -SessionId $null -ErrorText $OutputText
            }
            $text = [string](Get-ObjectPropertyValue -Object $json -Name 'result' -Default '')
            $sessionId = [string](Get-ObjectPropertyValue -Object $json -Name 'session_id' -Default $null)
            $isError = [bool](Get-ObjectPropertyValue -Object $json -Name 'is_error' -Default $false) -or ($ExitCode -ne 0)
            $isLimit = $isError -and ($text -match $limitRegex)
            return New-CliResult -Ok (-not $isError) -IsLimit $isLimit -Text $text `
                -SessionId $sessionId -ErrorText $(if ($isError) { $text } else { $null })
        }
        'codex' {
            $text = $null; $threadId = $null; $errorText = $null
            foreach ($line in ($OutputText -split "`r?`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $evt = $null
                try { $evt = $line | ConvertFrom-Json } catch { continue }
                $eventType = [string](Get-ObjectPropertyValue -Object $evt -Name 'type' -Default $null)
                if ([string]::IsNullOrWhiteSpace($eventType)) { continue }
                switch ($eventType) {
                    'thread.started' {
                        $threadId = [string](Get-ObjectPropertyValue -Object $evt -Name 'thread_id' -Default $threadId)
                    }
                    'item.completed' {
                        $item = Get-ObjectPropertyValue -Object $evt -Name 'item' -Default $null
                        if ([string](Get-ObjectPropertyValue -Object $item -Name 'type' -Default '') -eq 'agent_message') {
                            $text = [string](Get-ObjectPropertyValue -Object $item -Name 'text' -Default $text)
                        }
                    }
                    'error' {
                        $errorText = [string](Get-ObjectPropertyValue -Object $evt -Name 'message' -Default $errorText)
                    }
                    'turn.failed' {
                        $error = Get-ObjectPropertyValue -Object $evt -Name 'error' -Default $null
                        $message = [string](Get-ObjectPropertyValue -Object $error -Name 'message' -Default $null)
                        if (-not [string]::IsNullOrWhiteSpace($message)) {
                            $errorText = $message
                        }
                    }
                }
            }
            $isError = ($null -ne $errorText) -or ($ExitCode -ne 0)
            $isLimit = $isError -and (("$errorText $OutputText") -match $limitRegex)
            return New-CliResult -Ok (-not $isError) -IsLimit $isLimit -Text $text `
                -SessionId $threadId -ErrorText $errorText
        }
        'gemini' {
            $json = ConvertFrom-JsonTolerant -Text $OutputText
            if ($null -eq $json) {
                $isLimit = ($OutputText -match $limitRegex)
                return New-CliResult -Ok $false -IsLimit $isLimit -Text $OutputText -SessionId $null -ErrorText $OutputText
            }
            $sessionId = [string](Get-ObjectPropertyValue -Object $json -Name 'session_id' -Default $null)
            $errorNode = Get-ObjectPropertyValue -Object $json -Name 'error' -Default $null
            if ($null -ne $errorNode) {
                $msg = [string](Get-ObjectPropertyValue -Object $errorNode -Name 'message' -Default '')
                $code = [string](Get-ObjectPropertyValue -Object $errorNode -Name 'code' -Default '')
                $isLimit = ($msg -match $limitRegex) -or ($code -eq '429')
                return New-CliResult -Ok $false -IsLimit $isLimit -Text $msg -SessionId $sessionId -ErrorText $msg
            }
            $text = [string](Get-ObjectPropertyValue -Object $json -Name 'response' -Default '')
            return New-CliResult -Ok ($ExitCode -eq 0) -IsLimit $false -Text $text -SessionId $sessionId `
                -ErrorText $(if ($ExitCode -ne 0) { $OutputText } else { $null })
        }
        'agy' {
            # agy has no JSON/stdout output mode (it renders to a TTY), so the caller recovers the
            # reply from agy's persisted transcript and hands it in as $StdOut (falling back to the
            # captured stdout for stubs / any future build that prints). Success is therefore based on
            # whether a response was recovered — agy's exit code is unreliable under output redirection,
            # so it is NOT used as the signal. agy has no session id to capture (resume is the -c flag).
            $text = ([string]$StdOut).Trim()
            $hasResponse = -not [string]::IsNullOrWhiteSpace($text)
            # Usage-limit detection only applies when NO response came back (a real reply means it was
            # not limited); then scan whatever the process emitted (stderr/stdout) for a limit signal.
            # This also means a successful reply mentioning "429"/"rate limit"/"quota" is never misread.
            $isLimit = (-not $hasResponse) -and ($OutputText -match $limitRegex)
            $errorText = if (-not $hasResponse) {
                if ([string]::IsNullOrWhiteSpace($OutputText)) {
                    'agy produced no capturable response (no transcript reply found and stdout was empty)'
                } else { $OutputText }
            } else { $null }
            return New-CliResult -Ok $hasResponse -IsLimit $isLimit -Text $text -SessionId $null -ErrorText $errorText
        }
        'copilot' {
            $textParts = @(); $sessionId = $null; $errorText = $null
            foreach ($line in ($OutputText -split "`r?`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $evt = $null
                try { $evt = $line | ConvertFrom-Json } catch { continue }
                $eventType = [string](Get-ObjectPropertyValue -Object $evt -Name 'type' -Default $null)
                if ($eventType -in @('assistant.message','assistant','message','response','completion','final') -or
                    ([string](Get-ObjectPropertyValue -Object $evt -Name 'role' -Default '') -eq 'assistant')) {
                    foreach ($contentName in @('content', 'text', 'message')) {
                        $content = [string](Get-ObjectPropertyValue -Object $evt -Name $contentName -Default $null)
                        if (-not [string]::IsNullOrEmpty($content)) { $textParts += $content; break }
                    }
                }
                foreach ($sidName in @('interactionId', 'session_id', 'sessionId', 'conversation_id', 'conversationId', 'thread_id', 'threadId')) {
                    $sid = [string](Get-ObjectPropertyValue -Object $evt -Name $sidName -Default $null)
                    if (-not [string]::IsNullOrWhiteSpace($sid)) { $sessionId = $sid; break }
                }
                $err = Get-ObjectPropertyValue -Object $evt -Name 'error' -Default $null
                if ($null -ne $err) {
                    foreach ($errName in @('message', 'text', 'detail')) {
                        $candidateError = [string](Get-ObjectPropertyValue -Object $err -Name $errName -Default $null)
                        if (-not [string]::IsNullOrWhiteSpace($candidateError)) { $errorText = $candidateError; break }
                    }
                }
                elseif ($eventType -eq 'error') {
                    foreach ($errName in @('message', 'text', 'detail')) {
                        $candidateError = [string](Get-ObjectPropertyValue -Object $evt -Name $errName -Default $null)
                        if (-not [string]::IsNullOrWhiteSpace($candidateError)) { $errorText = $candidateError; break }
                    }
                }
            }
            $text = if ($textParts.Count -gt 0) { $textParts -join '' } else { $OutputText.Trim() }
            $isError = ($null -ne $errorText) -or ($ExitCode -ne 0)
            $isLimit = $isError -and (("$errorText $OutputText") -match $limitRegex)
            return New-CliResult -Ok (-not $isError) -IsLimit $isLimit -Text $text `
                -SessionId $sessionId -ErrorText $errorText
        }
    }
}

function Invoke-CliTaskRun {
    param(
        [int]$TaskIndex,
        $Task,
        [ValidateSet('New','Resume')] [string]$Mode,
        [string]$SessionId,
        # Task 6: the rotation model for this run (Models[currentModelIndex]). Defaults to $Task.Model.
        [string]$ModelOverride
    )

    $outputFilePath = Get-TaskOutputFilePath -TaskIndex $TaskIndex -Task $Task
    if ($Mode -eq 'New' -and (Test-Path -LiteralPath $outputFilePath)) {
        Remove-Item -LiteralPath $outputFilePath -Force
    }

    if ($Mode -eq 'New') {
        $prompt = Get-TaskPromptWithCompletionMarker -Task $Task
    }
    else {
        $prompt = Get-ResumePrompt -Task $Task
    }

    $cliArgsParams = @{ Task = $Task; Mode = $Mode; SessionId = $SessionId; Prompt = $prompt }
    if ($PSBoundParameters.ContainsKey('ModelOverride')) { $cliArgsParams['ModelOverride'] = $ModelOverride }
    $arguments = Get-CliArguments @cliArgsParams
    $exe = Get-CliExecutable -Task $Task

    Write-Step "$Mode run for task $($TaskIndex + 1): $($Task.Name) [$($Task.Cli)]"
    Write-Host "Command: $(Format-CommandForDisplay -Command $exe -Arguments $arguments)"
    $promptChannel = if ($Task.Cli -eq 'agy' -or $Task.Cli -eq 'copilot') { 'passed as the -p argument' } else { 'sent via stdin' }
    Write-Host "(prompt $promptChannel; full text in the output file)"

    if ($DryRun) {
        return New-CliResult -Ok $true -IsLimit $false -Text '[dry-run]' -SessionId $null -ErrorText $null
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    # Log the full prompt before the run; the displayed command line no longer contains it.
    [System.IO.File]::AppendAllText($outputFilePath, $prompt + [Environment]::NewLine + [Environment]::NewLine, $utf8NoBom)

    # agy and copilot take the prompt as the -p argument (not stdin); the other CLIs read it from stdin.
    # agy and copilot still need a CLOSED/EOF stdin: under Start-Process an inherited (unredirected) stdin
    # handle makes them block reading it indefinitely. Hand them an empty stdin so they get immediate
    # EOF — this mirrors limitshift.sh, which runs them with `</dev/null`.
    $invokeParams = @{ Command = $exe; Arguments = $arguments; WorkingDirectory = $Task.ProjectPath }
    $invokeParams['StdinText'] = if ($Task.Cli -eq 'agy' -or $Task.Cli -eq 'copilot') { '' } else { $prompt }
    $processResult = Invoke-NativeProcess @invokeParams
    $exitCode = $processResult.ExitCode
    $outputText = $processResult.OutputText

    # The FULL raw output always goes to the per-task output file (UTF-8, no BOM).
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        [System.IO.File]::AppendAllText($outputFilePath, $outputText + [Environment]::NewLine, $utf8NoBom)
    }

    # Parse first (Task 2b), then show only the agent's response (or the error) on the console.
    # agy renders its reply to a TTY, so the captured stdout is normally empty; recover the real
    # response from agy's persisted transcript (keyed by projectPath), retrying once in case it is
    # still being flushed. Fall back to the captured stdout when no transcript reply is found (covers
    # test stubs and any future agy that prints to stdout).
    $agyStdOut = $processResult.StdOut
    if ($Task.Cli -eq 'agy') {
        $agyResponse = Get-AgyResponseFromTranscript -ProjectPath $Task.ProjectPath
        if ([string]::IsNullOrWhiteSpace($agyResponse)) {
            Start-Sleep -Milliseconds 300
            $agyResponse = Get-AgyResponseFromTranscript -ProjectPath $Task.ProjectPath
        }
        if (-not [string]::IsNullOrWhiteSpace($agyResponse)) { $agyStdOut = $agyResponse }
    }
    $result = ConvertFrom-CliOutput -Cli $Task.Cli -OutputText $outputText -ExitCode $exitCode -StdOut $agyStdOut

    $consoleText = Get-ConsoleOutputText -Result $result -RawOutput $outputText -ShowRawOutput:$ShowRawOutput
    if (-not [string]::IsNullOrWhiteSpace($consoleText)) {
        Write-Host "--- agent response ---"
        Write-Host $consoleText
    }

    return $result
}

function Get-ResetTimeFromErrorText {
    param([string]$ErrorText)

    if ([string]::IsNullOrWhiteSpace($ErrorText)) { return $null }

    $m = [regex]::Match($ErrorText, '(?i)(?:try again at|resets? at|available (?:again )?at)\s+(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)')
    if ($m.Success) {
        foreach ($format in @('h:mmtt','htt','HH:mm','H:mm')) {
            try {
                $t = [datetime]::ParseExact($m.Groups[1].Value.ToUpper() -replace '\s+', '', $format, [System.Globalization.CultureInfo]::InvariantCulture)
                $candidate = (Get-Date).Date.Add($t.TimeOfDay)
                if ($candidate -lt (Get-Date)) { $candidate = $candidate.AddDays(1) }
                return $candidate
            } catch { }
        }
    }

    $m = [regex]::Match($ErrorText, '(?i)try again in\s+(?:(\d+)\s*h(?:ours?)?)?\s*(?:(\d+)\s*m(?:in(?:utes?)?)?)?\s*(?:(\d+)\s*s(?:ec(?:onds?)?)?)?')
    if ($m.Success -and ($m.Groups[1].Success -or $m.Groups[2].Success -or $m.Groups[3].Success)) {
        $h = if ($m.Groups[1].Success) { [int]$m.Groups[1].Value } else { 0 }
        $min = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 }
        $s = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 }
        return (Get-Date).AddHours($h).AddMinutes($min).AddSeconds($s)
    }

    $m = [regex]::Match($ErrorText, '(?i)reset after\s+(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?')
    if ($m.Success -and ($m.Groups[1].Success -or $m.Groups[2].Success -or $m.Groups[3].Success)) {
        $h = if ($m.Groups[1].Success) { [int]$m.Groups[1].Value } else { 0 }
        $min = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 }
        $s = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 }
        return (Get-Date).AddHours($h).AddMinutes($min).AddSeconds($s)
    }

    $m = [regex]::Match($ErrorText, '(?i)"retryDelay"\s*:\s*"(\d+)s"')
    if ($m.Success) {
        return (Get-Date).AddSeconds([int]$m.Groups[1].Value)
    }

    return $null
}

function Wait-ForLimitReset {
    param($Task, $Result, $Settings)

    if ($Task.Cli -eq 'claude') {
        Wait-UntilClaudeUsageReady -RequireFreshSession
        return
    }

    $resetTime = Get-ResetTimeFromErrorText -ErrorText $Result.ErrorText
    if ($null -eq $resetTime) {
        $resetTime = (Get-Date).AddMinutes($Settings.LimitWaitMinutes)
        Write-Step "Limit hit on $($Task.Cli); no reset time found in the error"
        Write-Host "Waiting the configured limitWaitMinutes: $($Settings.LimitWaitMinutes) minutes"
    }
    $wakeTime = $resetTime.AddMinutes($Settings.ResetBufferMinutes)
    $sleepSeconds = [int]($wakeTime - (Get-Date)).TotalSeconds
    if ($sleepSeconds -gt 0) {
        Write-Host "Sleeping until: $wakeTime"
        Start-Sleep -Seconds $sleepSeconds
    }
}

function Test-QueuePreflight {
    param(
        [string]$Path,
        [switch]$RequireCliBinaries
    )

    $config = Read-QueueConfig -Path $Path
    if ($RequireCliBinaries) {
        Test-CliBinariesAvailable -Tasks $config.Tasks
    }
    return $config
}

function Get-EditDistance {
    param([string]$s, [string]$t)
    $m = $s.Length; $n = $t.Length
    $d = New-Object 'int[,]' ($m + 1), ($n + 1)
    for ($i = 0; $i -le $m; $i++) { $d.SetValue($i, $i, 0) }
    for ($j = 0; $j -le $n; $j++) { $d.SetValue($j, 0, $j) }
    for ($i = 1; $i -le $m; $i++) {
        for ($j = 1; $j -le $n; $j++) {
            $cost = if ($s[$i - 1] -eq $t[$j - 1]) { 0 } else { 1 }
            $a = $d.GetValue($i - 1, $j) + 1
            $b = $d.GetValue($i, $j - 1) + 1
            $c = $d.GetValue($i - 1, $j - 1) + $cost
            $d.SetValue([Math]::Min([Math]::Min($a, $b), $c), $i, $j)
        }
    }
    return $d.GetValue($m, $n)
}

function Get-ModelSuggestions {
    param([string]$ModelName, [string[]]$Models, [int]$MaxSuggestions = 3, [int]$MaxDistance = 4)
    $inputLower = $ModelName.ToLower()
    $scored = $Models | ForEach-Object {
        [pscustomobject]@{ Model = $_; Distance = (Get-EditDistance $inputLower $_.ToLower()) }
    } | Sort-Object Distance | Where-Object { $_.Distance -le $MaxDistance }
    return @($scored | Select-Object -First $MaxSuggestions | ForEach-Object { $_.Model })
}

function Get-AvailableModels {
    param([string]$Cli)
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $result = [pscustomobject]@{
        Cli                    = $Cli
        SupportsModelDiscovery = $false
        Models                 = [string[]]@()
        Source                 = ''
        DiscoveredAt           = $ts
        Error                  = ''
    }
    switch ($Cli) {
        'agy' {
            $listCmd = $_
            if (Get-Command $listCmd -ErrorAction SilentlyContinue) {
                try {
                    $out = & $listCmd models 2>&1
                    if ($LASTEXITCODE -eq 0 -and $out) {
                        $models = [string[]]@()
                        try {
                            $json = ($out -join '') | ConvertFrom-Json -ErrorAction Stop
                            if ($json -is [System.Array]) {
                                $models = [string[]]@($json | ForEach-Object {
                                    if ($_.id) { $_.id } elseif ($_.name) { $_.name } else { [string]$_ }
                                } | Where-Object { $_ })
                            }
                        }
                        catch {
                            $models = [string[]]@($out | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                        }
                        if ($models.Count -gt 0) {
                            $result.SupportsModelDiscovery = $true
                            $result.Models = $models
                            $result.Source = "$listCmd models"
                        }
                        else { $result.Error = "$listCmd models: could not parse model list from output" }
                    }
                    else { $result.Error = "$listCmd models: exited $LASTEXITCODE" }
                }
                catch { $result.Error = "$listCmd models threw: $_" }
            }
            else { $result.Error = "$listCmd not on PATH" }
        }
        'copilot' {
            # GitHub Copilot CLI currently has no scriptable model-list subcommand. Leave discovery off
            # and validate user-supplied model names only opportunistically if the CLI adds one later.
            $result.Error = 'copilot does not expose a scriptable model list'
        }
        default { $result.Error = "$Cli does not expose a scriptable model list" }
    }
    return $result
}

function Save-CapabilityCache {
    param([string]$Cli, [string]$CapsDir, $Caps)
    if (-not (Test-Path $CapsDir)) { New-Item -ItemType Directory -Path $CapsDir -Force | Out-Null }
    $Caps | ConvertTo-Json | Set-Content (Join-Path $CapsDir "$Cli.json") -Encoding UTF8
}

function Get-CliCapabilities {
    param([string]$Cli, [string]$CapsDir, [int]$MaxAgeHours = 24, [switch]$Refresh)
    $cacheFile = Join-Path $CapsDir "$Cli.json"
    if (-not $Refresh -and (Test-Path $cacheFile)) {
        try {
            $cached = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $discoveredAt = [DateTime]::ParseExact(
                $cached.DiscoveredAt, 'yyyy-MM-ddTHH:mm:ssZ', $null,
                [System.Globalization.DateTimeStyles]::AssumeUniversal)
            $ageHours = ([DateTime]::UtcNow - $discoveredAt).TotalHours
            if ($ageHours -lt $MaxAgeHours) {
                Write-Verbose "INFO: using cached $Cli capabilities (age: $([Math]::Floor($ageHours))h)"
                return $cached
            }
        }
        catch {}
    }
    $caps = Get-AvailableModels -Cli $Cli
    Save-CapabilityCache -Cli $Cli -CapsDir $CapsDir -Caps $caps
    return $caps
}

function Invoke-ModelValidation {
    param(
        $Config,
        [string]$CapsDir,
        [switch]$Refresh
    )
    $policy = $Config.Settings.ModelValidation
    $cacheHours = $Config.Settings.CapabilityCacheHours
    if ($policy -eq 'off') { return $true }

    $hadError = $false
    $capsCache = @{}

    for ($i = 0; $i -lt $Config.Tasks.Count; $i++) {
        $task = $Config.Tasks[$i]
        $n = $i + 1
        if ($task.Models.Count -eq 0) { continue }

        if (-not $capsCache.ContainsKey($task.Cli)) {
            $capsCache[$task.Cli] = Get-CliCapabilities -Cli $task.Cli -CapsDir $CapsDir `
                -MaxAgeHours $cacheHours -Refresh:$Refresh
        }
        $caps = $capsCache[$task.Cli]

        if ($caps.SupportsModelDiscovery) {
            foreach ($model in $task.Models) {
                if ($caps.Models -notcontains $model) {
                    $suggestions = Get-ModelSuggestions -ModelName $model -Models $caps.Models
                    $sugStr = if ($suggestions) { " (did you mean: $($suggestions -join ', ')?)" } else { '' }
                    switch ($policy) {
                        'strictWhenDiscoverable' {
                            [Console]::Error.WriteLine("ERROR: Task ${n}: model `"$model`" is not available for $($task.Cli) according to $($caps.Source)${sugStr}")
                            $hadError = $true
                        }
                        'warn' {
                            Write-Warning "Task ${n}: model `"$model`" not found in $($task.Cli) model list (continuing)${sugStr}"
                        }
                    }
                }
            }
        }
        else {
            Write-Host "  INFO: Task ${n}: model validation skipped for $($task.Cli) ($($caps.Error))" -ForegroundColor DarkGray
        }
    }
    return (-not $hadError)
}

function Invoke-ModelProbe {
    param($Config)
    Write-Host '--- model probe ---'
    $seen = @{}
    foreach ($task in $Config.Tasks) {
        $modelsToProbe = if ($task.Models.Count -gt 0) { $task.Models } else { @('') }
        foreach ($model in $modelsToProbe) {
            $key = "$($task.Cli):$model"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $modelFlag = if ($model) {
                switch ($task.Cli) {
                    'claude'  { @('--model', $model) }
                    'codex'   { @('-m', $model) }
                    'gemini'  { @('-m', $model) }
                    default   { @('--model', $model) }
                }
            } else { @() }

            $tmpDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "limitshift-probe-$([guid]::NewGuid())")
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            try {
                $cliArgs = switch ($task.Cli) {
                    'claude'  { @('--permission-mode', 'viewOnly', '--output-format', 'json') + $modelFlag + @('-p', 'Respond with only: OK') }
                    'codex'   { @('exec', '--json') + $modelFlag + @('--skip-git-repo-check') }
                    'gemini'  { $modelFlag }
                    'agy'     { @('-p', 'Respond with only: OK', '--dangerously-skip-permissions') + $modelFlag }
                    'copilot' { @('--name', 'limitshift-probe', '--allow-all') + $modelFlag }
                    default   { @() }
                }
                $label = $task.Cli + $(if ($model) { " ($model)" })
                $process = Start-Process -FilePath $task.Cli -ArgumentList $cliArgs `
                    -WorkingDirectory $tmpDir -Wait -PassThru -NoNewWindow `
                    -RedirectStandardOutput (Join-Path $tmpDir 'out.txt') `
                    -RedirectStandardError  (Join-Path $tmpDir 'err.txt') `
                    -ErrorAction SilentlyContinue
                if ($process.ExitCode -eq 0) {
                    Write-Host "  INFO: Probe $label`: OK" -ForegroundColor DarkGray
                } else {
                    $errLine = Get-Content (Join-Path $tmpDir 'err.txt') -TotalCount 1 -ErrorAction SilentlyContinue
                    Write-Warning "Probe ${label}: failed (exit $($process.ExitCode)) - $errLine"
                }
            }
            finally {
                Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

if ($LoadFunctionsOnly) { return }

try {
    $config = Test-QueuePreflight -Path $QueuePath -RequireCliBinaries:($ValidateOnly -or -not $DryRun)
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

if ($ValidateOnly) {
    $capsDir = Join-Path $RunnerStatePath 'capabilities'
    $modelValidationPassed = Invoke-ModelValidation -Config $config -CapsDir $capsDir -Refresh:$RefreshCapabilities
    if (-not $modelValidationPassed) { exit 2 }
    if ($ProbeModels -or $config.Settings.ProbeModels) { Invoke-ModelProbe -Config $config }
    Write-Host "Config OK: $QueuePath"
    Write-Host "Tasks: $($config.Tasks.Count)"
    foreach ($t in $config.Tasks) {
        Write-Host (" - [{0}] {1}  ({2})" -f $t.Cli, $t.Name, $t.ProjectPath)
    }
    exit 0
}

# Pre-check: fail fast if a live lock is held; skip if the state dir (and lock) don't exist yet.
if (Test-Path -LiteralPath $LockPath) {
    $existingPid = [int](Get-Content -LiteralPath $LockPath -ErrorAction SilentlyContinue)
    $existingProc = if ($existingPid) { Get-Process -Id $existingPid -ErrorAction SilentlyContinue } else { $null }
    if ($existingProc) {
        [Console]::Error.WriteLine("ERROR: Another LimitShift process is already running with this queue (PID $existingPid).")
        [Console]::Error.WriteLine("       Queue: $QueuePath")
        [Console]::Error.WriteLine("       To force-unlock: del `"$LockPath`"")
        exit 2
    }
}

$transcriptStarted = $false
$exitCode = 0

try {
    Initialize-RunnerState  # migration + mkdir must happen before we write the lock
    $PID | Set-Content -LiteralPath $LockPath -Encoding UTF8 -NoNewline
    $Tasks = $config.Tasks
    $ResetBufferMinutes = $config.Settings.ResetBufferMinutes

    Start-Transcript -Path $LogPath -Append
    $transcriptStarted = $true

    Write-Step "Script started"
    Write-Host "Started at: $(Get-Date)"
    Write-Host "Queue path: $QueuePath"
    Write-Host "Runner state path: $RunnerStatePath"
    Write-Host "Log path: $LogPath"
    Write-Host "Usage path: $UsagePath"
    Write-Host "Prompt count: $($Tasks.Count)"

    Write-Step "Current folder"
    Get-Location

    for ($i = 0; $i -lt $Tasks.Count; $i++) {
        $task = $Tasks[$i]
        $taskNumber = $i + 1

        if (Test-TaskAlreadyDone -TaskIndex $i) {
            # Task 4: a done marker only counts when its stored fingerprint still matches the
            # current task. If the task's prompt/cli/projectPath/model/effort/extraArgs changed,
            # invalidate the marker (re-run) and drop the stale session id so it starts fresh.
            $savedFingerprint = Get-SavedDoneFingerprint -TaskIndex $i
            $currentFingerprint = Get-TaskFingerprint -Task $task
            if ($savedFingerprint -eq $currentFingerprint) {
                Write-Step "Skipping task $taskNumber of $($Tasks.Count): $($task.Name)"
                Write-Host "Task is already marked as done."
                continue
            }
            Write-Step "Re-running task $taskNumber of $($Tasks.Count): $($task.Name)"
            Write-Host "Task $taskNumber changed since last run; previous done marker invalidated."
            Remove-Item -LiteralPath (Get-TaskDoneFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Get-TaskSessionFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
            # Task 6: also drop the stale model-rotation index so a changed task starts at model #1.
            Remove-Item -LiteralPath (Get-TaskModelIndexFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
        }

        $runCount = 0
        $errorRetryCount = 0
        $mustWaitForFreshSession = $false
        $stallCount = 0
        $previousNoMarkerText = $null

        # Task 6: per-task model-rotation list and the persisted current index (kept across restarts).
        $models = @($task.Models)
        $modelCount = $models.Count
        $currentModelIndex = if ($modelCount -gt 1) { Get-SavedTaskModelIndex -TaskIndex $i } else { 0 }
        if ($currentModelIndex -ge $modelCount) { $currentModelIndex = 0 }

        while ($true) {
            $runCount++
            if ($runCount -gt $config.Settings.MaxRunsPerTask) {
                throw "Task $taskNumber exceeded maxRunsPerTask=$($config.Settings.MaxRunsPerTask)"
            }

            # Local Ollama claude runs never hit Anthropic usage limits, so skip the cloud /usage
            # pre-check (it would otherwise query — and consume — the cloud account).
            if ($task.Cli -eq 'claude' -and -not (Test-IsOllamaTask -Task $task) -and -not $DryRun) {
                Wait-UntilClaudeUsageReady -RequireFreshSession:$mustWaitForFreshSession
            }

            # Task 6: the model used for THIS run is Models[currentModelIndex]. Empty when the task
            # set no model at all (then Get-CliArguments emits no -m/--model, exactly as before).
            $currentModel = if ($modelCount -gt 0) { [string]$models[$currentModelIndex] } else { '' }

            $savedSessionId = Get-SavedTaskSessionId -TaskIndex $i

            if ([string]::IsNullOrWhiteSpace($savedSessionId)) {
                $runMode = 'New'
                $sessionId = $null
                # claude is given a session id up front (passed as --session-id). agy/copilot need a
                # stable session id so the NEXT run can resume the same conversation.
                if ($task.Cli -eq 'claude' -or $task.Cli -eq 'agy' -or $task.Cli -eq 'copilot') { $sessionId = New-TaskSessionId -TaskIndex $i }
                $result = Invoke-CliTaskRun -TaskIndex $i -Task $task -Mode New -SessionId $sessionId -ModelOverride $currentModel
            }
            else {
                $runMode = 'Resume'
                $result = Invoke-CliTaskRun -TaskIndex $i -Task $task -Mode Resume -SessionId $savedSessionId -ModelOverride $currentModel
            }

            if ($DryRun) {
                Write-Step "Dry run for task $taskNumber recorded the command only"
                break
            }

            # Task 4: classify this run's outcome and append one runs.csv row. The status maps the
            # parsed result to a short label (Limit/Error/Done/Blocked/NoMarker) consistently with
            # limitshift.sh. In simple mode an OK run is Done.
            if ($result.IsLimit) {
                $runStatus = 'Limit'
            }
            elseif (-not $result.Ok) {
                $runStatus = 'Error'
            }
            elseif (-not $task.CompletionCheck) {
                $runStatus = 'Done'
            }
            else {
                $runMarker = Get-MarkerStatus -Text $result.Text
                if ($runMarker.Status -eq 'Done')        { $runStatus = 'Done' }
                elseif ($runMarker.Status -eq 'Blocked') { $runStatus = 'Blocked' }
                else                                     { $runStatus = 'NoMarker' }
            }
            Add-RunsCsvRow -Task ("{0}-{1}" -f $taskNumber, $task.Name) -Run $runCount -Mode $runMode -Exit $(if ($result.Ok) { 0 } else { 1 }) -Status $runStatus

            # Persist the session id the CLI reported (this is how codex thread ids get captured)
            if (-not [string]::IsNullOrWhiteSpace($result.SessionId)) {
                $result.SessionId | Set-Content -LiteralPath (Get-TaskSessionFilePath -TaskIndex $i) -Encoding UTF8
            }

            # Gemini-only: the installed CLI version rejected --resume — drop the session and retry without it.
            if ($task.Cli -eq 'gemini' -and -not $result.Ok -and
                $result.ErrorText -match '(?i)unknown option.*resume|not supported in non-interactive|unexpected argument|too many arguments|invalid.*resume') {
                Remove-Item -LiteralPath (Get-TaskSessionFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
                Write-Step "Task $taskNumber`: installed gemini rejects --resume; retrying with continuation prompt only"
                continue
            }

            # A usage limit pauses and resumes, in both simple and completion-check modes.
            if ($result.IsLimit) {
                # Task 6: model rotation. If another model remains in the list, switch to it and
                # retry IMMEDIATELY (same session id — a resume) WITHOUT waiting. Only once every
                # listed model is limit-exhausted do we reset to model #1 and wait for the reset.
                if ($modelCount -gt 1 -and $currentModelIndex -lt ($modelCount - 1)) {
                    $nextModelIndex = $currentModelIndex + 1
                    Write-Step "Task $taskNumber`: limit on $($models[$currentModelIndex]); switching to $($models[$nextModelIndex])"
                    $currentModelIndex = $nextModelIndex
                    Save-TaskModelIndex -TaskIndex $i -ModelIndex $currentModelIndex
                    continue
                }

                if ($modelCount -gt 1) {
                    # Every model in the list is exhausted: reset to model #1, then wait for the reset.
                    $currentModelIndex = 0
                    Save-TaskModelIndex -TaskIndex $i -ModelIndex $currentModelIndex
                }

                $mustWaitForFreshSession = $true
                Write-Step "Task $taskNumber paused by a usage limit on $($task.Cli)"
                Wait-ForLimitReset -Task $task -Result $result -Settings $config.Settings
                continue
            }

            if (-not $result.Ok) {
                $errorRetryCount++
                Write-Step "Task $taskNumber errored: $($result.ErrorText)"
                if ($errorRetryCount -le $config.Settings.MaxRetriesOnError) {
                    Write-Host "Retry $errorRetryCount of $($config.Settings.MaxRetriesOnError); resuming the same session."
                    continue
                }
                if ($config.Settings.StopOnError) {
                    throw "Task $taskNumber failed after $($config.Settings.MaxRetriesOnError) retries: $($result.ErrorText)"
                }
                Write-Host "stopOnError=false; abandoning this task and moving to the next one."
                break
            }

            # Simple mode (completionCheck:false): the first OK run (no limit, no error) is done.
            # No marker parsing, no stall guard.
            if (-not $task.CompletionCheck) {
                Save-TaskDoneMarker -TaskIndex $i -Task $task
                Write-Step "Task $taskNumber completed"
                break
            }

            $marker = Get-MarkerStatus -Text $result.Text
            if ($marker.Status -eq 'Done') {
                Save-TaskDoneMarker -TaskIndex $i -Task $task
                Write-Step "Task $taskNumber completed"
                break
            }
            if ($marker.Status -eq 'Blocked') {
                Save-TaskFailedMarker -TaskIndex $i -Reason $marker.Reason -Task $task
                Write-Step "Task $taskNumber reported itself BLOCKED: $($marker.Reason)"
                if ($config.Settings.StopOnError) {
                    throw "Task $taskNumber is blocked: $($marker.Reason)"
                }
                Write-Host "stopOnError=false; moving to the next task."
                break
            }

            # No-progress guard: an OK run with no marker whose text repeats the previous
            # no-marker response counts as a stall. After maxStalls stalls, fail the task.
            $currentText = if ($null -ne $result.Text) { ([string]$result.Text).Trim() } else { '' }
            if ($null -ne $previousNoMarkerText -and $currentText -eq $previousNoMarkerText) {
                $stallCount++
                if ($stallCount -ge $config.Settings.MaxStalls) {
                    $stallReason = 'no progress: agent repeated the same response without a completion marker'
                    Save-TaskFailedMarker -TaskIndex $i -Reason $stallReason -Task $task
                    Write-Step "Task $taskNumber failed: $stallReason"
                    if ($config.Settings.StopOnError) {
                        throw "Task $taskNumber failed: $stallReason"
                    }
                    Write-Host "stopOnError=false; abandoning this task and moving to the next one."
                    break
                }
            }
            $previousNoMarkerText = $currentText

            # Ran fine, no marker: the agent stopped early. Resume to push it onward.
            $mustWaitForFreshSession = $false
            Write-Step "Task $taskNumber is not complete yet; resuming the same session."
        }
    }

    Write-Step "Script completed"
    Write-Host "All queue tasks are finished."
    Write-Host "Finished at: $(Get-Date)"
    Write-Host "Log saved to: $LogPath"
    Write-Host "Last Claude usage saved to: $UsagePath"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $exitCode = 1
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript
    }
    Remove-Item -LiteralPath $LockPath -ErrorAction SilentlyContinue
}

exit $exitCode
