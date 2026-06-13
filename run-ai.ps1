param(
    [string]$QueuePath = (Join-Path $PSScriptRoot 'ai-run-queue.json'),
    [switch]$ValidateOnly,
    [switch]$DryRun,
    [switch]$ShowRawOutput,
    [switch]$LoadFunctionsOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Utf8Encoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = $Utf8Encoding
[Console]::OutputEncoding = $Utf8Encoding
$OutputEncoding = $Utf8Encoding

$QueuePath = [System.IO.Path]::GetFullPath($QueuePath)
$QueueRootPath = Split-Path -Parent $QueuePath
$QueueName = [System.IO.Path]::GetFileNameWithoutExtension($QueuePath)
$RunnerName = $QueueName -replace '[^A-Za-z0-9._-]', '-'
$RunnerStatePath = Join-Path $QueueRootPath ".ai-runner-$RunnerName"
$SessionStatePath = Join-Path $RunnerStatePath "sessions"
$OutputStatePath = Join-Path $RunnerStatePath "outputs"
$StatusStatePath = Join-Path $RunnerStatePath "status"
$LogPath = Join-Path $RunnerStatePath "ai-run-log.txt"
$UsagePath = Join-Path $RunnerStatePath "claude-usage-last.txt"
$RunsCsvPath = Join-Path $RunnerStatePath "runs.csv"
$StateReadmePath = Join-Path $RunnerStatePath "_README.txt"
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
  ai-run-log.txt        The full runner transcript.
  claude-usage-last.txt The last Claude /usage report.

Re-running:
  Delete this whole folder to start completely from scratch.
  Delete status/task-NN.done to force ONE task to run again.
  Editing a task's prompt, cli, projectPath, model, effort, or extraArgs now AUTO-INVALIDATES
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

$AllowedClis = @('claude', 'codex', 'gemini')

function Read-QueueConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path`nCopy ai-run-queue.example.json to ai-run-queue.json and fill in your tasks."
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
        StopOnError       = $true
        MaxRunsPerTask    = 20
        MaxRetriesOnError = 2
        LimitWaitMinutes  = 30
        ResetBufferMinutes = 2
        CompletionCheck   = $true
        MaxStalls         = 2
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

        $model  = $null
        $effort = $null
        if ($t.PSObject.Properties['model'])  { $model  = [string]$t.model }
        if ($t.PSObject.Properties['effort']) { $effort = [string]$t.effort }

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

    $missing = @()
    foreach ($cli in ($Tasks | ForEach-Object { $_.Cli } | Sort-Object -Unique)) {
        if (-not (Get-Command $cli -ErrorAction SilentlyContinue)) {
            $missing += $cli
        }
    }
    if ($missing.Count -gt 0) {
        throw ("The following CLI(s) are used in the queue but not found on PATH: $($missing -join ', ')`n" +
               "Install instructions:`n" +
               "  claude : npm install -g @anthropic-ai/claude-code`n" +
               "  codex  : npm install -g @openai/codex`n" +
               "  gemini : npm install -g @google/gemini-cli")
    }
}


function Get-TaskKey {
    param([int]$TaskIndex)

    return ("task-{0:d2}" -f ($TaskIndex + 1))
}

# Task 4: slugify a task name for the output filename. Keep the original case, replace any
# run of characters outside [A-Za-z0-9._-] with a single dash, trim leading/trailing dashes,
# and cap the length at 40. Mirrored byte-for-byte in run-ai.sh (get_task_slug).
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
# CANONICAL FORMAT (must match run-ai.sh get_task_fingerprint exactly so a queue is portable):
#   fields, in this exact order:  Name, Cli, ProjectPath, Model, Effort, Prompt, ExtraArgs-joined
#   ExtraArgs-joined = the args joined by a single space (" ").
#   null/empty Model/Effort contribute an empty string.
#   joined with the ASCII unit separator U+001F (0x1F), which is unlikely to appear in any value.
#   SHA256 of the UTF-8 bytes of that string, rendered as lowercase hex.
function Get-TaskFingerprint {
    param($Task)

    $us = [char]0x1f
    $extraArgs = @($Task.ExtraArgs)
    $extraJoined = ($extraArgs -join ' ')
    $model  = if ($null -ne $Task.Model)  { [string]$Task.Model }  else { '' }
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

function Get-TaskOutputFilePath {
    param(
        [int]$TaskIndex,
        $Task
    )

    # Task 4: name the output file with the zero-padded index AND a slug of the task name,
    # e.g. task-03-fix-the-thing-output.txt. Identical pattern in run-ai.sh.
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
    $launcherArguments = @($Arguments)
    $wrapperPath = $null
    $argumentsPath = $null
    $extension = [System.IO.Path]::GetExtension($commandPath).ToLowerInvariant()

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
        $launcherArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $wrapperPath,
            '-CommandPath', $commandPath,
            '-ArgumentsPath', $argumentsPath,
            '-WorkingDirectory', $WorkingDirectory
        )
    }

    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("limitshift-stdout-" + [guid]::NewGuid() + ".txt")
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("limitshift-stderr-" + [guid]::NewGuid() + ".txt")
    $stdinPath = $null

    try {
        $startProcessParams = @{
            FilePath               = $launcherPath
            ArgumentList           = $launcherArguments
            WorkingDirectory       = $WorkingDirectory
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError  = $stderrPath
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

# The prompt is intentionally NOT part of the argument list: it is delivered via stdin
# (see Invoke-NativeProcess -StdinText). Passing multi-line prompts as process arguments
# truncates them on Windows (Start-Process + cmd shim layers cannot carry embedded newlines).
function Get-CliArguments {
    param(
        $Task,
        [ValidateSet('New', 'Resume')] [string]$Mode,
        [string]$SessionId
    )

    switch ($Task.Cli) {
        'claude' {
            $cliArgs = @('-p')
            if ($Mode -eq 'New')    { $cliArgs += @('--session-id', $SessionId) }
            if ($Mode -eq 'Resume') { $cliArgs += @('--resume', $SessionId) }
            $cliArgs += @('--output-format', 'json')
            if ($Task.Model)  { $cliArgs += @('--model', $Task.Model) }
            if ($Task.Effort) { $cliArgs += @('--effort', $Task.Effort) }
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
            if ($Task.Model)  { $cliArgs += @('-m', $Task.Model) }
            if ($Task.Effort) { $cliArgs += @('-c', "model_reasoning_effort=$($Task.Effort)") }
            $cliArgs += $codexExtraArgs
            return $cliArgs
        }
        'gemini' {
            if ($Task.Effort) { Write-Host "Note: 'effort' is not supported by gemini and is ignored for task '$($Task.Name)'." }
            $cliArgs = @()
            if ($Mode -eq 'Resume' -and -not [string]::IsNullOrWhiteSpace($SessionId)) {
                $cliArgs += @('--resume', $SessionId)
            }
            $cliArgs += @('--output-format', 'json')
            if ($Task.Model) { $cliArgs += @('-m', $Task.Model) }
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

function ConvertFrom-CliOutput {
    param(
        [ValidateSet('claude','codex','gemini')] [string]$Cli,
        [string]$OutputText,
        [int]$ExitCode
    )

    $LimitPatterns = @{
        claude = '(?i)(you''ve hit your .{0,40}limit|usage limit)'
        codex  = '(?i)(usage limit|rate limit|too many requests|try again (at|in)|quota)'
        gemini = '(?i)(quota exceeded|resource_exhausted|ratelimitexceeded|model_capacity_exhausted|no capacity available|daily quota|usage limit reached|rate limit|429|too many requests)'
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
    }
}

function Invoke-CliTaskRun {
    param(
        [int]$TaskIndex,
        $Task,
        [ValidateSet('New','Resume')] [string]$Mode,
        [string]$SessionId
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

    $arguments = Get-CliArguments -Task $Task -Mode $Mode -SessionId $SessionId

    Write-Step "$Mode run for task $($TaskIndex + 1): $($Task.Name) [$($Task.Cli)]"
    Write-Host "Command: $(Format-CommandForDisplay -Command $Task.Cli -Arguments $arguments)"
    Write-Host "(prompt sent via stdin; full text in the output file)"

    if ($DryRun) {
        return New-CliResult -Ok $true -IsLimit $false -Text '[dry-run]' -SessionId $null -ErrorText $null
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    # Log the full prompt before the run; the displayed command line no longer contains it.
    [System.IO.File]::AppendAllText($outputFilePath, $prompt + [Environment]::NewLine + [Environment]::NewLine, $utf8NoBom)

    $processResult = Invoke-NativeProcess -Command $Task.Cli -Arguments $arguments -WorkingDirectory $Task.ProjectPath -StdinText $prompt
    $exitCode = $processResult.ExitCode
    $outputText = $processResult.OutputText

    # The FULL raw output always goes to the per-task output file (UTF-8, no BOM).
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        [System.IO.File]::AppendAllText($outputFilePath, $outputText + [Environment]::NewLine, $utf8NoBom)
    }

    # Parse first (Task 2b), then show only the agent's response (or the error) on the console.
    $result = ConvertFrom-CliOutput -Cli $Task.Cli -OutputText $outputText -ExitCode $exitCode

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

if ($LoadFunctionsOnly) { return }

try {
    $config = Test-QueuePreflight -Path $QueuePath -RequireCliBinaries:($ValidateOnly -or -not $DryRun)
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

if ($ValidateOnly) {
    Write-Host "Config OK: $QueuePath"
    Write-Host "Tasks: $($config.Tasks.Count)"
    foreach ($t in $config.Tasks) {
        Write-Host (" - [{0}] {1}  ({2})" -f $t.Cli, $t.Name, $t.ProjectPath)
    }
    exit 0
}

$transcriptStarted = $false
$exitCode = 0

try {
    Initialize-RunnerState
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
        }

        $runCount = 0
        $errorRetryCount = 0
        $mustWaitForFreshSession = $false
        $stallCount = 0
        $previousNoMarkerText = $null

        while ($true) {
            $runCount++
            if ($runCount -gt $config.Settings.MaxRunsPerTask) {
                throw "Task $taskNumber exceeded maxRunsPerTask=$($config.Settings.MaxRunsPerTask)"
            }

            if ($task.Cli -eq 'claude' -and -not $DryRun) {
                Wait-UntilClaudeUsageReady -RequireFreshSession:$mustWaitForFreshSession
            }

            $savedSessionId = Get-SavedTaskSessionId -TaskIndex $i

            if ([string]::IsNullOrWhiteSpace($savedSessionId)) {
                $runMode = 'New'
                $sessionId = $null
                if ($task.Cli -eq 'claude') { $sessionId = New-TaskSessionId -TaskIndex $i }
                $result = Invoke-CliTaskRun -TaskIndex $i -Task $task -Mode New -SessionId $sessionId
            }
            else {
                $runMode = 'Resume'
                $result = Invoke-CliTaskRun -TaskIndex $i -Task $task -Mode Resume -SessionId $savedSessionId
            }

            if ($DryRun) {
                Write-Step "Dry run for task $taskNumber recorded the command only"
                break
            }

            # Task 4: classify this run's outcome and append one runs.csv row. The status maps the
            # parsed result to a short label (Limit/Error/Done/Blocked/NoMarker) consistently with
            # run-ai.sh. In simple mode an OK run is Done.
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

            # A usage limit always pauses and resumes, in both simple and completion-check modes.
            if ($result.IsLimit) {
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
}

exit $exitCode
