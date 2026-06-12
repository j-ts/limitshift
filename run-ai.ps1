param(
    [string]$QueuePath = (Join-Path $PSScriptRoot 'ai-run-queue.json'),
    [switch]$ValidateOnly,
    [switch]$DryRun,
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

$FreshSessionThresholdPercent = 0
$PollSecondsAfterResetPassed = 60

$TaskCompleteMarker = "[[TASK_COMPLETE]]"

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

        $extraArgs = @()
        $extraNode = $t.PSObject.Properties['extraArgs']
        if ($null -ne $extraNode -and $null -ne $extraNode.Value) {
            if ($extraNode.Value -is [string]) {
                $extraArgs = @($extraNode.Value -split '\s+' | Where-Object { $_ })
            }
            elseif ($extraNode.Value -is [System.Array]) {
                $extraArgs = @($extraNode.Value | ForEach-Object { [string]$_ })
            }
            else {
                throw "Task $n extraArgs must be a string or an array of strings."
            }
        }

        $model  = $null
        $effort = $null
        if ($t.PSObject.Properties['model'])  { $model  = [string]$t.model }
        if ($t.PSObject.Properties['effort']) { $effort = [string]$t.effort }

        $tasks += [pscustomobject]@{
            Name        = [string]$t.name
            Cli         = $cli
            ProjectPath = $projectPath
            Model       = $model
            Effort      = $effort
            Prompt      = [string]$t.prompt
            ExtraArgs   = $extraArgs
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

function Get-TaskSessionFilePath {
    param([int]$TaskIndex)

    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    return Join-Path $SessionStatePath "$taskKey-session-id.txt"
}

function Get-TaskOutputFilePath {
    param([int]$TaskIndex)

    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    return Join-Path $OutputStatePath "$taskKey-output.txt"
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

function Save-TaskDoneMarker {
    param([int]$TaskIndex)

    $doneFilePath = Get-TaskDoneFilePath -TaskIndex $TaskIndex
    (Get-Date).ToString("s") | Set-Content -LiteralPath $doneFilePath -Encoding UTF8
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

    $usageText | Tee-Object -FilePath $UsagePath | Out-Null

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

function Get-TaskPromptWithCompletionMarker {
    param([string]$Prompt)

    return @"
$Prompt

IMPORTANT AUTOMATION INSTRUCTION:
When and only when this task is fully complete, end your final response with exactly:
$TaskCompleteMarker
"@
}

function Get-ResumePrompt {
    return @"
/goal Continue the previous task in this same session from where you stopped. Do not restart from scratch.

IMPORTANT AUTOMATION INSTRUCTION:
When and only when this task is fully complete, end your final response with exactly:
$TaskCompleteMarker
"@
}

function Get-CliArguments {
    param(
        $Task,
        [ValidateSet('New', 'Resume')] [string]$Mode,
        [string]$SessionId,
        [string]$Prompt
    )

    switch ($Task.Cli) {
        'claude' {
            $args = @('-p')
            if ($Mode -eq 'New')    { $args += @('--session-id', $SessionId) }
            if ($Mode -eq 'Resume') { $args += @('--resume', $SessionId) }
            $args += @('--output-format', 'json')
            if ($Task.Model)  { $args += @('--model', $Task.Model) }
            if ($Task.Effort) { $args += @('--effort', $Task.Effort) }
            $args += $Task.ExtraArgs
            $args += @($Prompt)
            return $args
        }
        'codex' {
            $args = @('exec')
            if ($Mode -eq 'Resume') { $args += @('resume', $SessionId) }
            $args += @('--json', '-C', $Task.ProjectPath)
            if ($Task.Model)  { $args += @('-m', $Task.Model) }
            if ($Task.Effort) { $args += @('-c', "model_reasoning_effort=$($Task.Effort)") }
            $args += $Task.ExtraArgs
            $args += @($Prompt)
            return $args
        }
        'gemini' {
            if ($Task.Effort) { Write-Host "Note: 'effort' is not supported by gemini and is ignored for task '$($Task.Name)'." }
            $args = @()
            if ($Mode -eq 'Resume' -and -not [string]::IsNullOrWhiteSpace($SessionId)) {
                $args += @('--resume', $SessionId)
            }
            $args += @('-p', $Prompt, '--output-format', 'json')
            if ($Task.Model) { $args += @('-m', $Task.Model) }
            $args += $Task.ExtraArgs
            return $args
        }
    }
    throw "No argument builder for cli '$($Task.Cli)'"
}

function New-CliResult {
    param([bool]$Ok, [bool]$IsLimit, [string]$Text, [string]$SessionId, [string]$ErrorText)
    return @{ Ok = $Ok; IsLimit = $IsLimit; Text = $Text; SessionId = $SessionId; ErrorText = $ErrorText }
}

function ConvertFrom-JsonTolerant {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { }
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        try { return ($Text.Substring($start, $end - $start + 1) | ConvertFrom-Json) } catch { }
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
            $text = [string]$json.result
            $isError = [bool]$json.is_error -or ($ExitCode -ne 0)
            $isLimit = $isError -and ($text -match $limitRegex)
            return New-CliResult -Ok (-not $isError) -IsLimit $isLimit -Text $text `
                -SessionId ([string]$json.session_id) -ErrorText $(if ($isError) { $text } else { $null })
        }
        'codex' {
            $text = $null; $threadId = $null; $errorText = $null
            foreach ($line in ($OutputText -split "`r?`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $evt = $null
                try { $evt = $line | ConvertFrom-Json } catch { continue }
                if ($null -eq $evt -or $null -eq $evt.PSObject.Properties['type']) { continue }
                switch ($evt.type) {
                    'thread.started' { $threadId = [string]$evt.thread_id }
                    'item.completed' {
                        if ($evt.item.type -eq 'agent_message') { $text = [string]$evt.item.text }
                    }
                    'error'       { $errorText = [string]$evt.message }
                    'turn.failed' { if ($evt.error.message) { $errorText = [string]$evt.error.message } }
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
            $sessionId = $null
            if ($json.PSObject.Properties['session_id']) { $sessionId = [string]$json.session_id }
            $errorNode = $json.PSObject.Properties['error']
            if ($null -ne $errorNode -and $null -ne $errorNode.Value) {
                $msg = [string]$errorNode.Value.message
                $isLimit = ($msg -match $limitRegex) -or ("$($errorNode.Value.code)" -eq '429')
                return New-CliResult -Ok $false -IsLimit $isLimit -Text $msg -SessionId $sessionId -ErrorText $msg
            }
            $text = [string]$json.response
            return New-CliResult -Ok ($ExitCode -eq 0) -IsLimit $false -Text $text -SessionId $sessionId `
                -ErrorText $(if ($ExitCode -ne 0) { $OutputText } else { $null })
        }
    }
}

function Test-TaskCompletedFromOutput {
    param([string]$OutputText)

    if ([string]::IsNullOrWhiteSpace($OutputText)) {
        return $false
    }

    return ($OutputText -match [regex]::Escape($TaskCompleteMarker))
}

function Test-ClaudeLimitOutput {
    param([string]$OutputText)

    if ([string]::IsNullOrWhiteSpace($OutputText)) {
        return $false
    }

    return ($OutputText -match "(?i)you've hit your .+ limit")
}

function Invoke-ClaudeRaw {
    param(
        [string[]]$Arguments,
        [string]$OutputFilePath
    )

    $outputLines = & claude @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = $outputLines | Out-String

    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        $outputText | Tee-Object -FilePath $OutputFilePath -Append | Out-Host
    }

    return @{
        ExitCode   = $exitCode
        OutputText = $outputText
    }
}

function Start-ClaudeTaskRun {
    param(
        [int]$TaskIndex,
        $Task
    )

    $sessionId = New-TaskSessionId -TaskIndex $TaskIndex
    $outputFilePath = Get-TaskOutputFilePath -TaskIndex $TaskIndex

    if (Test-Path -LiteralPath $outputFilePath) {
        Remove-Item -LiteralPath $outputFilePath -Force
    }

    Write-Step "Starting new Claude session for task $($TaskIndex + 1): $($Task.Name)"
    Write-Host "Session ID: $sessionId"
    Write-Host "Project path: $($Task.ProjectPath)"
    Write-Host "Model: $($Task.Model)"
    Write-Host "Effort: $($Task.Effort)"

    Set-Location $Task.ProjectPath

    $arguments = @(
        "-p",
        "--session-id", $sessionId,
        "--output-format", "json",
        "--model", $Task.Model,
        "--effort", $Task.Effort,
        (Get-TaskPromptWithCompletionMarker -Prompt $Task.Prompt)
    )

    $result = Invoke-ClaudeRaw -Arguments $arguments -OutputFilePath $outputFilePath

    return @{
        ExitCode   = $result.ExitCode
        OutputText = $result.OutputText
        SessionId  = $sessionId
    }
}

function Resume-ClaudeTaskRun {
    param(
        [int]$TaskIndex,
        $Task,
        [string]$SessionId
    )

    $outputFilePath = Get-TaskOutputFilePath -TaskIndex $TaskIndex

    Write-Step "Resuming Claude session for task $($TaskIndex + 1): $($Task.Name)"
    Write-Host "Session ID: $SessionId"
    Write-Host "Project path: $($Task.ProjectPath)"
    Write-Host "Model: $($Task.Model)"
    Write-Host "Effort: $($Task.Effort)"

    Set-Location $Task.ProjectPath

    $arguments = @(
        "-p",
        "--resume", $SessionId,
        "--output-format", "json",
        "--model", $Task.Model,
        "--effort", $Task.Effort,
        (Get-ResumePrompt)
    )

    $result = Invoke-ClaudeRaw -Arguments $arguments -OutputFilePath $outputFilePath

    return @{
        ExitCode   = $result.ExitCode
        OutputText = $result.OutputText
        SessionId  = $SessionId
    }
}

if ($LoadFunctionsOnly) { return }

if ($ValidateOnly) {
    $config = Read-QueueConfig -Path $QueuePath
    Test-CliBinariesAvailable -Tasks $config.Tasks
    Write-Host "Config OK: $QueuePath"
    Write-Host "Tasks: $($config.Tasks.Count)"
    foreach ($t in $config.Tasks) {
        Write-Host (" - [{0}] {1}  ({2})" -f $t.Cli, $t.Name, $t.ProjectPath)
    }
    exit 0
}

$transcriptStarted = $false

try {
    Initialize-RunnerState
    $config = Read-QueueConfig -Path $QueuePath
    $ClaudeTasks = $config.Tasks
    $ResetBufferMinutes = $config.Settings.ResetBufferMinutes

    Start-Transcript -Path $LogPath -Append
    $transcriptStarted = $true

    Write-Step "Script started"
    Write-Host "Started at: $(Get-Date)"
    Write-Host "Queue path: $QueuePath"
    Write-Host "Runner state path: $RunnerStatePath"
    Write-Host "Log path: $LogPath"
    Write-Host "Usage path: $UsagePath"
    Write-Host "Prompt count: $($ClaudeTasks.Count)"

    Write-Step "Current folder"
    Get-Location

    for ($i = 0; $i -lt $ClaudeTasks.Count; $i++) {
        $task = $ClaudeTasks[$i]
        $taskNumber = $i + 1

        if (Test-TaskAlreadyDone -TaskIndex $i) {
            Write-Step "Skipping task $taskNumber of $($ClaudeTasks.Count): $($task.Name)"
            Write-Host "Task is already marked as done."
            continue
        }

        $runCount = 0
        $errorRetryCount = 0
        $mustWaitForFreshSession = $false

        while ($true) {
            $runCount++

            if ($runCount -gt $config.Settings.MaxRunsPerTask) {
                throw "Task $taskNumber exceeded MaxRunsPerTask=$config.Settings.MaxRunsPerTask"
            }

            if (-not (Test-Path -LiteralPath $task.ProjectPath)) {
                throw "Project path does not exist for task $taskNumber`: $($task.ProjectPath)"
            }

            Wait-UntilClaudeUsageReady -RequireFreshSession:$mustWaitForFreshSession

            $savedSessionId = Get-SavedTaskSessionId -TaskIndex $i

            if ([string]::IsNullOrWhiteSpace($savedSessionId)) {
                $runResult = Start-ClaudeTaskRun -TaskIndex $i -Task $task
            }
            else {
                $runResult = Resume-ClaudeTaskRun -TaskIndex $i -Task $task -SessionId $savedSessionId
            }

            # Required: always check usage after Claude returns.
            $usage = Get-ClaudeUsage

            $taskCompleted = Test-TaskCompletedFromOutput -OutputText $runResult.OutputText
            $usageExhausted = (Test-ClaudeWeekExhausted -Usage $usage) -or (Test-ClaudeSessionExhausted -Usage $usage)
            $limitOutput = Test-ClaudeLimitOutput -OutputText $runResult.OutputText

            if ($taskCompleted) {
                Save-TaskDoneMarker -TaskIndex $i
                Write-Step "Task $taskNumber completed"
                Write-Host "Completion marker detected. Proceeding to the next prompt."
                break
            }

            if ($runResult.ExitCode -ne 0) {
                Write-Step "Claude returned a non-zero exit code for task $taskNumber"
                Write-Host "Claude exit code: $($runResult.ExitCode)"

                if ($limitOutput -and $usageExhausted) {
                    $mustWaitForFreshSession = $true
                    Write-Host "Claude was cut by usage limit."
                    Write-Host "The same session will be resumed after reset."
                    continue
                }

                if ($config.Settings.StopOnError) {
                    $errorRetryCount++

                    if ($errorRetryCount -le $config.Settings.MaxRetriesOnError) {
                        $mustWaitForFreshSession = $false
                        Write-Host "Transient error (attempt $errorRetryCount of $config.Settings.MaxRetriesOnError). Resuming same session."
                        continue
                    }

                    throw "Claude failed on task $taskNumber with exit code $($runResult.ExitCode) after $config.Settings.MaxRetriesOnError retries."
                }

                # Clear session to avoid resuming a broken session repeatedly.
                $sessionFilePath = Get-TaskSessionFilePath -TaskIndex $i
                if (Test-Path -LiteralPath $sessionFilePath) {
                    Remove-Item -LiteralPath $sessionFilePath -Force
                }

                $mustWaitForFreshSession = $false
                Write-Host "StopOnClaudeError is disabled. Starting a fresh session for next attempt."
                continue
            }

            if ($usageExhausted -and $limitOutput) {
                $mustWaitForFreshSession = $true
                Write-Step "Task $taskNumber paused by Claude limit"
                Write-Host "The same session will be resumed after reset."
                continue
            }

            if ($usageExhausted -and -not $limitOutput) {
                Save-TaskDoneMarker -TaskIndex $i
                Write-Step "Task $taskNumber likely completed (no limit message, usage exhausted)"
                Write-Host "No limit text in output. Treating as complete. Proceeding to next task."
                break
            }

            $mustWaitForFreshSession = $false
            Write-Step "Task $taskNumber is not complete yet"
            Write-Host "Usage is still available. Resuming the same session immediately instead of moving to the next prompt."
        }
    }

    Write-Step "Script completed"
    Write-Host "All Claude queue tasks are finished."
    Write-Host "PC will stay on."
    Write-Host "Finished at: $(Get-Date)"
    Write-Host "Log saved to: $LogPath"
    Write-Host "Last Claude usage saved to: $UsagePath"
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript
    }
}
