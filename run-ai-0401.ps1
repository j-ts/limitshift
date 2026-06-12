param(
    [string]$QueuePath = "C:\Users\Admin\Desktop\ai-run-queue.json"
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
$RunnerStatePath = Join-Path $QueueRootPath ".claude-runner-$RunnerName"
$SessionStatePath = Join-Path $RunnerStatePath "sessions"
$OutputStatePath = Join-Path $RunnerStatePath "outputs"
$StatusStatePath = Join-Path $RunnerStatePath "status"
$LogPath = Join-Path $RunnerStatePath "ai-run-log.txt"
$UsagePath = Join-Path $RunnerStatePath "claude-usage-last.txt"

$FreshSessionThresholdPercent = 0
$ResetBufferMinutes = 2
$PollSecondsAfterResetPassed = 60
$MaxRunsPerTask = 20
$MaxRetriesOnError = 2
$StopOnClaudeError = $true

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

function Get-QueueTasks {
    if (-not (Test-Path -LiteralPath $QueuePath)) {
        throw "Queue file does not exist: $QueuePath"
    }

    $queue = Get-Content -LiteralPath $QueuePath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($queue.PSObject.Properties.Name -contains "tasks") {
        $tasks = @($queue.tasks)
    }
    else {
        $tasks = @($queue)
    }

    if ($tasks.Count -eq 0) {
        throw "Queue file contains no tasks: $QueuePath"
    }

    for ($i = 0; $i -lt $tasks.Count; $i++) {
        $task = $tasks[$i]
        $taskNumber = $i + 1

        foreach ($propertyName in @("name", "projectPath", "model", "effort", "prompt")) {
            $property = $task.PSObject.Properties[$propertyName]

            if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                throw "Task $taskNumber is missing required JSON property: $propertyName"
            }
        }

        if (-not (Test-Path -LiteralPath $task.projectPath)) {
            throw "Project path does not exist for task $taskNumber`: $($task.projectPath)"
        }
    }

    return $tasks
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

$transcriptStarted = $false

try {
    Initialize-RunnerState
    $ClaudeTasks = Get-QueueTasks

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

            if ($runCount -gt $MaxRunsPerTask) {
                throw "Task $taskNumber exceeded MaxRunsPerTask=$MaxRunsPerTask"
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

                if ($StopOnClaudeError) {
                    $errorRetryCount++

                    if ($errorRetryCount -le $MaxRetriesOnError) {
                        $mustWaitForFreshSession = $false
                        Write-Host "Transient error (attempt $errorRetryCount of $MaxRetriesOnError). Resuming same session."
                        continue
                    }

                    throw "Claude failed on task $taskNumber with exit code $($runResult.ExitCode) after $MaxRetriesOnError retries."
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
