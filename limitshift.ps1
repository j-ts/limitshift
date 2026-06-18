param(
    [string]$QueuePath,
    [switch]$ValidateOnly,
    [switch]$DryRun,
    [switch]$ShowRawOutput,
    [switch]$Demo,
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
    # `-QueuePath project-a-queue.json` is equivalent to placing the file next to the script.
    # A relative path WITH separators resolves from the current working directory.
    if ($QueuePath -notmatch '[/\\]') {
        $QueuePath = Join-Path $PSScriptRoot $QueuePath
    } else {
        $QueuePath = [System.IO.Path]::GetFullPath($QueuePath)
    }
    $QueueRootPath = Split-Path -Parent $QueuePath
    $QueueName = [System.IO.Path]::GetFileNameWithoutExtension($QueuePath)
    $RunnerName = $QueueName -replace '[^A-Za-z0-9._-]', '-'
    # State folder is named exactly after the queue file (sanitized) — no "limitshift-" prefix added.
    # The default queue limitshift-queue.json keeps its limitshift-queue/ folder (its name already
    # starts with limitshift-); every other queue gets a folder matching its own name
    # (career-ops_01.json -> career-ops_01/). Folder naming is forward-only: existing limitshift-<name>
    # folders from older versions are left untouched, not migrated.
    $RunnerStatePath = Join-Path $QueueRootPath $RunnerName
    $SessionStatePath = Join-Path $RunnerStatePath "sessions"
    $OutputStatePath = Join-Path $RunnerStatePath "outputs"
    $StatusStatePath = Join-Path $RunnerStatePath "status"
    $LogPath = Join-Path $RunnerStatePath "limitshift-log.txt"
    $StopFlagPath = Join-Path $RunnerStatePath 'stop-after-step.flag'
    $script:__StopFlagPath = $StopFlagPath

    # Can we read single keys? Only on an interactive console with non-redirected input.
    $script:CanReadStopKey = $false
    try {
        if (-not [Console]::IsInputRedirected) { $null = [Console]::KeyAvailable; $script:CanReadStopKey = $true }
    } catch { $script:CanReadStopKey = $false }

    # A stale flag from a previous run must never auto-stop a fresh run.
    if (Test-Path -LiteralPath $StopFlagPath) {
        Remove-Item -LiteralPath $StopFlagPath -Force -ErrorAction SilentlyContinue
    }
    $RunsCsvPath = Join-Path $RunnerStatePath "runs.csv"
    $StateReadmePath = Join-Path $RunnerStatePath "_README.txt"
    $StateGitignorePath = Join-Path $RunnerStatePath '.gitignore'
    $LockPath = Join-Path $RunnerStatePath 'limitshift.lock'
}

$RunsCsvHeader = "timestamp,task,run,mode,exit,status,cli,model"

$TaskCompleteMarker = "[[TASK_COMPLETE]]"
$TaskBlockedMarker  = "[[TASK_BLOCKED]]"

# ---- UI output theme (prototype) ------------------------------------------------
# Cosmetic only; runner behavior, flags and exit codes are unchanged. Colors use
# Write-Host -ForegroundColor (works on Windows PowerShell 5.1 with no ANSI). Live
# animations use [Console]::Write so they redraw in place AND stay out of the
# Start-Transcript log; they auto-disable when stdout is redirected / not a TTY.
# Every glyph is a [char] code (not literal Unicode) so the file stays ASCII-source.
$script:UiAccentColor = [System.ConsoleColor]::Magenta
$script:UiTaskTotal   = 0
$script:UiTaskStart   = $null

$script:GlyphStar = [char]0x2726   # four-pointed star
$script:GlyphTask  = [char]0x25B8   # small right triangle
$script:GlyphDone  = [char]0x2713   # check mark
$script:GlyphErr   = [char]0x2717   # ballot x
$script:GlyphArrow = [char]0x2192   # rightwards arrow
$script:GlyphDot   = [char]0x00B7   # middle dot
$script:GlyphMoon    = [char]0x263E   # last-quarter moon
$script:GlyphDash    = [char]0x2014   # em dash
$script:GlyphRetry   = [char]0x21BB   # clockwise open-circle arrow
$script:GlyphDiamond = [char]0x25C6   # black diamond, used only on the final summary line

$script:StopHintActive = 'Ctrl+C stop now ' + [char]0x00B7 + ' s stop after this task'
$script:StopHintArmed  = 'stopping after this task' + [char]0x2026
$script:UiSessionTotalSeconds = 0.0
$script:UiSessionTotalPrinted = $false

# Milestone lines (task done / all done) are indented farther so they read as section end-caps.
$script:UiMilestoneIndent = '      '

function Test-UiAnimatable {
    # Animate only on a real interactive console: not when stdout is redirected to a file/pipe.
    try { return -not [Console]::IsOutputRedirected } catch { return $false }
}

function Get-StopHint {
    param([switch]$Armed)
    if ($Armed) { return $script:StopHintArmed }
    return $script:StopHintActive
}

function Test-StopRequested {
    if ([string]::IsNullOrWhiteSpace($script:__StopFlagPath)) { return $false }
    return (Test-Path -LiteralPath $script:__StopFlagPath)
}

function Request-Stop {
    if ([string]::IsNullOrWhiteSpace($script:__StopFlagPath)) { return }
    $null | Set-Content -LiteralPath $script:__StopFlagPath -Encoding UTF8
}

function Read-StopKey {
    # Drain buffered keys; if any is 's'/'S', request stop. Safe to call every poll tick.
    if (-not $script:CanReadStopKey) { return }
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.KeyChar -eq 's' -or $k.KeyChar -eq 'S') { Request-Stop }
        }
    } catch {}
}

function Format-UiDuration {
    # Human-friendly time spans: '2 seconds', '5 minutes', '1 hour 23 minutes'. Used by the
    # past-tense limit beat after a usage-reset rest.
    param([TimeSpan]$Span)
    if ($null -eq $Span) { return '0 seconds' }
    if ($Span.TotalSeconds -lt 60) {
        $s = [int][Math]::Round($Span.TotalSeconds)
        if ($s -le 1) { return '1 second' }
        return "$s seconds"
    }
    if ($Span.TotalMinutes -lt 60) {
        $m = [int][Math]::Round($Span.TotalMinutes)
        if ($m -eq 1) { return '1 minute' }
        return "$m minutes"
    }
    $h = [int][Math]::Floor($Span.TotalHours)
    $m = $Span.Minutes
    $hpart = if ($h -eq 1) { '1 hour' } else { "$h hours" }
    if ($m -eq 0) { return $hpart }
    $mpart = if ($m -eq 1) { '1 minute' } else { "$m minutes" }
    return "$hpart $mpart"
}

function Add-UiSessionTotalTime {
    param([TimeSpan]$Span)
    if ($null -eq $Span) { return }
    $script:UiSessionTotalSeconds += $Span.TotalSeconds
}

function Write-UiSessionTotalTime {
    if ($script:UiSessionTotalPrinted) { return }
    $script:UiSessionTotalPrinted = $true
    $span = [TimeSpan]::FromSeconds($script:UiSessionTotalSeconds)
    Write-Host ("  Total time: " + (Format-UiDuration -Span $span)) -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Message)

    # Softer, lower-key section marker than the old ==== ... ==== banner.
    Write-Host ""
    Write-Host ("  " + $script:GlyphDot + " ") -ForegroundColor DarkGray -NoNewline
    Write-Host $Message -ForegroundColor Gray
}

function Write-UiBeat {
    # One accented status line. Reserved for the big beats (limits, summary).
    param([string]$Glyph, [string]$Message, [System.ConsoleColor]$Color = $script:UiAccentColor)
    Write-Host ("  " + $Glyph + " ") -ForegroundColor $Color -NoNewline
    Write-Host $Message -ForegroundColor Gray
}

function Write-UiHeader {
    # The app header, printed the instant the run launches (right after Start-Transcript) so the
    # user sees the brand before the queue is read. The queue details follow once the config loads.
    Write-Host ""
    Write-Host ("  " + $script:GlyphStar + " LimitShift") -ForegroundColor $script:UiAccentColor
}

function Write-UiQueueLine {
    # The "N tasks queued · <clis>" line. Its leading dot aligns under the header's star.
    param([int]$TaskCount, [string[]]$Clis)
    $cliList = (@($Clis) | Select-Object -Unique) -join ', '
    $plural = if ($TaskCount -eq 1) { '' } else { 's' }
    Write-Host ("  " + $script:GlyphDot + "   " + $TaskCount + " task" + $plural + " queued " + $script:GlyphDot + " " + $cliList) -ForegroundColor DarkGray
}

function Write-UiBannerDetails {
    # Queue details printed once the config is read: the "N tasks queued · <clis>" line plus a
    # "started <ddd HH:mm> · <queue path>" line stamped with the run's start time.
    param([int]$TaskCount, [string[]]$Clis, [datetime]$StartTime = (Get-Date), [string]$QueuePath)
    Write-UiQueueLine -TaskCount $TaskCount -Clis $Clis
    Write-Host ("    started " + $StartTime.ToString('ddd HH:mm') + " " + $script:GlyphDot + " " + $QueuePath) -ForegroundColor DarkGray
}

function Get-UiPromptPreview {
    # First up-to-2 non-blank lines of the user's prompt, each trimmed to a sensible width,
    # with the automation-marker boilerplate stripped so the user sees THEIR words.
    param([string]$PromptText, [int]$MaxLines = 2, [int]$Width = 72)

    $ellipsis   = [char]0x2026
    $openQuote  = [char]0x201C
    $closeQuote = [char]0x201D

    if ([string]::IsNullOrWhiteSpace($PromptText)) { return @('(empty prompt)') }

    $text = $PromptText
    $cut = $text.IndexOf('IMPORTANT AUTOMATION INSTRUCTIONS')
    if ($cut -ge 0) { $text = $text.Substring(0, $cut) }

    $lines = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) { return @('(empty prompt)') }

    $take = [Math]::Min($MaxLines, $lines.Count)
    $preview = New-Object System.Collections.Generic.List[string]
    $truncatedLast = $false
    for ($k = 0; $k -lt $take; $k++) {
        $l = $lines[$k]
        if ($l.Length -gt $Width) {
            $l = $l.Substring(0, $Width - 1).TrimEnd() + $ellipsis
            $truncatedLast = $true
        }
        else {
            $truncatedLast = $false
        }
        $preview.Add($l)
    }

    $more = ($lines.Count -gt $take) -or $truncatedLast
    $lastIdx = $preview.Count - 1
    $preview[0] = [string]$openQuote + $preview[0]
    if ($more -and -not $truncatedLast) { $preview[$lastIdx] = $preview[$lastIdx] + $ellipsis }
    $preview[$lastIdx] = $preview[$lastIdx] + $closeQuote
    return $preview.ToArray()
}

function Write-UiTaskHeader {
    param([int]$TaskNumber, [int]$TaskTotal, $Task, [string]$Mode, [string]$Model, [string]$PromptText)

    $modeWord = if ($Mode -eq 'New') { 'new' } else { 'resume' }
    $meta = "   " + $Task.Cli
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $meta += " " + $script:GlyphDot + " " + $Model }
    $meta += " " + $script:GlyphDot + " " + $modeWord

    Write-Host ""
    Write-Host ("  " + $script:GlyphTask + " ") -ForegroundColor $script:UiAccentColor -NoNewline
    Write-Host ("Task " + $TaskNumber + "/" + $TaskTotal + " " + $script:GlyphDot + " " + $Task.Name) -ForegroundColor White -NoNewline
    Write-Host $meta -ForegroundColor DarkGray

    # On Resume the prompt is unchanged from the previous run and the full text is already in the
    # output file - skip the preview block so the resume header is a single compact line.
    if ($Mode -eq 'New') {
        foreach ($line in (Get-UiPromptPreview -PromptText $PromptText)) {
            Write-Host ("  " + $line) -ForegroundColor DarkYellow
        }
        Write-Host ("  " + $script:GlyphArrow + " full prompt saved to the output file") -ForegroundColor DarkGray
    }

    $script:UiTaskStart = Get-Date
}

function Write-UiTaskDone {
    param([int]$TaskNumber)
    $tail = ''
    if ($null -ne $script:UiTaskStart) {
        $e = (Get-Date) - $script:UiTaskStart
        $tail = '  ' + $script:GlyphDot + '  ' + ('{0}:{1:00}' -f [int][Math]::Floor($e.TotalMinutes), $e.Seconds)
    }
    Write-Host ""
    Write-Host ($script:UiMilestoneIndent + $script:GlyphDone + " ") -ForegroundColor Green -NoNewline
    Write-Host ("Task " + $TaskNumber + " done" + $tail) -ForegroundColor Gray
}

function Write-UiSummary {
    # The final summary line. Five variants, distinguished by what actually happened this run:
    #   - dry-run                                          -> "Dry run complete"
    #   - all tasks were already done (nothing ran)        -> "Nothing to do" + redo-hint
    #   - any task failed                                  -> bulleted breakdown (+ skipped row + redo-hint if any)
    #   - some new + some skipped                          -> "Done - N of M ran" breakdown + redo-hint
    #   - all new, every task had completionCheck:true     -> "executed successfully"
    #   - all new, any task was completionCheck:false      -> "executed. Please check the work manually"
    # The accent glyph is the diamond (GlyphDiamond), not the four-pointed star (GlyphStar) - the
    # star is already the "response" header glyph. -StatePath is the runner state folder that holds
    # the .done markers; deleting it forces every task to re-run.
    param(
        [int]$TaskCount,
        [int]$DoneCount,
        [int]$FailedCount,
        [int]$SkippedCount,
        [int]$NeedsHumanCount,
        [bool]$AllCompletionCheck,
        [string]$LogPath,
        [string]$StatePath,
        [switch]$DryRun,
        [switch]$StoppedEarly,
        [int]$NotReachedCount = 0
    )
    

    Write-Host ""
    Write-UiSeparator
    Write-Host ""

    if ($StoppedEarly) {
        $ranCount = $DoneCount + $FailedCount
        Write-Host ("  " + $script:GlyphDiamond + " Stopped early - " + $ranCount + " of " + $TaskCount + " ran (" + $NotReachedCount + " not reached). Rerun the same command to continue.") -ForegroundColor $script:UiAccentColor
        Write-Host ("    log saved to " + $LogPath) -ForegroundColor DarkGray
        Write-UiSessionTotalTime
        return
    }

    if ($DryRun) {
        $plural = if ($TaskCount -eq 1) { '' } else { 's' }
        Write-Host ("  " + $script:GlyphDiamond + " Dry run complete") -ForegroundColor $script:UiAccentColor -NoNewline
        Write-Host (" " + $script:GlyphDash + " recorded " + $TaskCount + " task command" + $plural + ", no CLIs were run.") -ForegroundColor Gray
        Write-UiSessionTotalTime
        return
    }

    # All tasks were already done from a previous run - nothing actually ran this time.
    if ($SkippedCount -eq $TaskCount -and $TaskCount -gt 0) {
        $plural = if ($TaskCount -eq 1) { '' } else { 's' }
        $was = if ($TaskCount -eq 1) { 'was' } else { 'were' }
        Write-Host ("  " + $script:GlyphDiamond + " Nothing to do") -ForegroundColor $script:UiAccentColor -NoNewline
        Write-Host (" " + $script:GlyphDash + " all " + $TaskCount + " queued task" + $plural + " " + $was + " already done in a previous run.") -ForegroundColor Gray
        if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
            Write-Host ("    To redo one task, delete its marker in " + $StatePath + "\status\") -ForegroundColor DarkGray
            Write-Host ("    To redo all, delete the state folder: " + $StatePath) -ForegroundColor DarkGray
        }
        Write-UiSessionTotalTime
        return
    }

    if ($FailedCount -gt 0) {
        $ranCount = $DoneCount + $FailedCount
        Write-Host ("  " + $script:GlyphDiamond + " Done") -ForegroundColor $script:UiAccentColor -NoNewline
        Write-Host (" " + $script:GlyphDash + " " + $ranCount + " of " + $TaskCount + " queued tasks ran this turn:") -ForegroundColor Gray
        Write-Host ("      " + $script:GlyphDot + " " + $DoneCount + " newly completed") -ForegroundColor Green
        if ($NeedsHumanCount -gt 0) {
            Write-Host ("      " + $script:GlyphDot + " " + $NeedsHumanCount + " need human review") -ForegroundColor Yellow
        }
        $otherFailed = $FailedCount - $NeedsHumanCount
        if ($otherFailed -gt 0) {
            Write-Host ("      " + $script:GlyphDot + " " + $otherFailed + " failed") -ForegroundColor Red
        }
        if ($SkippedCount -gt 0) {
            Write-Host ("      " + $script:GlyphDot + " " + $SkippedCount + " already done (skipped)") -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host ("    See a detailed transcript in " + $LogPath) -ForegroundColor DarkGray
        if ($SkippedCount -gt 0 -and -not [string]::IsNullOrWhiteSpace($StatePath)) {
            Write-Host ("    To redo one task, delete its marker in " + $StatePath + "\status\") -ForegroundColor DarkGray
            Write-Host ("    To redo all, delete the state folder: " + $StatePath) -ForegroundColor DarkGray
        }
        Write-UiSessionTotalTime
        return
    }

    # Some skipped, some newly executed - no failures.
    if ($SkippedCount -gt 0) {
        Write-Host ("  " + $script:GlyphDiamond + " Done") -ForegroundColor $script:UiAccentColor -NoNewline
        Write-Host (" " + $script:GlyphDash + " " + $DoneCount + " of " + $TaskCount + " queued tasks ran this turn:") -ForegroundColor Gray
        Write-Host ("      " + $script:GlyphDot + " " + $DoneCount + " newly completed") -ForegroundColor Green
        Write-Host ("      " + $script:GlyphDot + " " + $SkippedCount + " already done (skipped)") -ForegroundColor DarkGray
        if (-not $AllCompletionCheck) {
            Write-Host ""
            Write-Host ("    completionCheck is off for at least one task " + $script:GlyphDash + " please check the work manually.") -ForegroundColor DarkGray
        }
        Write-Host ("    log saved to " + $LogPath) -ForegroundColor DarkGray
        if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
            Write-Host ("    To redo one task, delete its marker in " + $StatePath + "\status\") -ForegroundColor DarkGray
            Write-Host ("    To redo all, delete the state folder: " + $StatePath) -ForegroundColor DarkGray
        }
        Write-UiSessionTotalTime
        return
    }

    # All new, no failures, no skips - the "everything went great" path.
    $plural = if ($TaskCount -eq 1) { '' } else { 's' }
    if ($AllCompletionCheck) {
        Write-Host ("  " + $script:GlyphDiamond + " All done") -ForegroundColor $script:UiAccentColor -NoNewline
        Write-Host (" " + $script:GlyphDash + " all " + $TaskCount + " queued task" + $plural + " were executed successfully.") -ForegroundColor Gray
    }
    else {
        Write-Host ("  " + $script:GlyphDiamond + " All done") -ForegroundColor $script:UiAccentColor -NoNewline
        Write-Host (" " + $script:GlyphDash + " all " + $TaskCount + " queued task" + $plural + " were executed. Please check the work manually.") -ForegroundColor Gray
    }
    Write-Host ("    log saved to " + $LogPath) -ForegroundColor DarkGray
    Write-UiSessionTotalTime
}

function Invoke-UiSpinner {
    # Redraws the "working" line in place while $Process runs. Uses [Console]::Write so frames
    # never reach the transcript. The little light glides back and forth across a fixed track.
    param([System.Diagnostics.Process]$Process)

    $verbs = @('running', 'reading', 'operating', 'considering', 'still on it', 'wondering', 'progressing', 'performing')
    $track = 7
    $pos = 0
    $dir = 1
    $dot = [char]0x00B7
    $star = [char]0x2726
    $start = Get-Date
    $cr = [string][char]13
    $cursorRestore = $null
    try { $cursorRestore = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch {}

    try {
        while (-not $Process.HasExited) {
            $sb = New-Object System.Text.StringBuilder
            for ($i = 0; $i -lt $track; $i++) {
                $d = [Math]::Abs($i - $pos)
                $ch = if ($d -eq 0) { [char]0x25CF } elseif ($d -eq 1) { [char]0x25CB } elseif ($d -eq 2) { [char]0x2218 } else { [char]0x00B7 }
                [void]$sb.Append($ch)
            }
            $elapsed = (Get-Date) - $start
            $mmss = '{0}:{1:00}' -f [int][Math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
            $verb = $verbs[[int]([Math]::Floor($elapsed.TotalSeconds / 3) % $verbs.Count)]

            [Console]::Write($cr)
            $prev = [Console]::ForegroundColor
            try {
                [Console]::ForegroundColor = $script:UiAccentColor
                [Console]::Write("  " + $star + " " + $sb.ToString() + " ")
                [Console]::ForegroundColor = [System.ConsoleColor]::DarkGray
                [Console]::Write(($verb + " " + $dot + " " + $mmss).PadRight(20))
            }
            finally { [Console]::ForegroundColor = $prev }

            Read-StopKey
            $armed = Test-StopRequested
            $hint = Get-StopHint -Armed:$armed
            $hintColor = if ($armed) { [System.ConsoleColor]::Yellow } else { [System.ConsoleColor]::DarkGray }
            Write-EphemeralFooter -Text ("   " + $hint) -ForegroundColor $hintColor

            $pos += $dir
            if ($pos -ge ($track - 1) -or $pos -le 0) { $dir = -$dir }
            Start-Sleep -Milliseconds 140
        }
    }
    finally {
        Clear-EphemeralFooter
        [Console]::Write($cr + (' ' * ([Math]::Max(60, [Console]::WindowWidth - 1))) + $cr) # This line was originally clearing the spinner. I'll keep it as a double clear for safety for the existing spinner animation
        if ($null -ne $cursorRestore) { try { [Console]::CursorVisible = $cursorRestore } catch {} }
    }
}

function Write-EphemeralFooter {
    param(
        [string]$Text,
        [ConsoleColor]$ForegroundColor = 'DarkGray',
        [ConsoleColor]$BackgroundColor = 'Black'
    )
    if (-not (Test-UiAnimatable)) {
        return
    }

    if (-not $script:ForceColor -and $Host.UI.RawUI.BackgroundColor -eq $BackgroundColor) {
        # Avoid explicit background color when it's the system default to let `term-background` rules apply.
        $BackgroundColor = $null
    }

    $originalCursorLeft = [Console]::CursorLeft
    $originalCursorTop = [Console]::CursorTop

    $footerLine = [Console]::WindowHeight - 1
    if ($footerLine -lt 0) { $footerLine = 0 } # Handle very small windows

    # Move cursor to the footer line, clear it, write text, then restore cursor.
    try {
        [Console]::CursorVisible = $false
        [Console]::SetCursorPosition(0, $footerLine)
        [Console]::Write(' ' * [Console]::WindowWidth) # Clear the line
        [Console]::SetCursorPosition(0, $footerLine) # Move back to start of line

        # Store original colors to restore later
        $originalFg = [Console]::ForegroundColor
        $originalBg = [Console]::BackgroundColor

        [Console]::ForegroundColor = $ForegroundColor
        if ($null -ne $BackgroundColor) {
            [Console]::BackgroundColor = $BackgroundColor
        }
        [Console]::Write($Text)

        # Restore original colors and cursor position
        [Console]::ForegroundColor = $originalFg
        [Console]::BackgroundColor = $originalBg
    }
    finally {
        [Console]::SetCursorPosition($originalCursorLeft, $originalCursorTop)
        [Console]::CursorVisible = $true
    }
}

function Clear-EphemeralFooter {
    if (-not (Test-UiAnimatable)) {
        return
    }

    # Clear the footer line by overwriting it with spaces.
    $originalCursorLeft = [Console]::CursorLeft
    $originalCursorTop = [Console]::CursorTop

    $footerLine = [Console]::WindowHeight - 1
    if ($footerLine -lt 0) { $footerLine = 0 } # Handle very small windows

    try {
        [Console]::CursorVisible = $false
        [Console]::SetCursorPosition(0, $footerLine)
        [Console]::Write(' ' * [Console]::WindowWidth) # Clear the line
    }
    finally {
        [Console]::SetCursorPosition($originalCursorLeft, $originalCursorTop)
        [Console]::CursorVisible = $true
    }
}
Register-EngineEvent -SourceIdentifier 'PowerShell.Exiting' -Action { Clear-EphemeralFooter }

function Invoke-UiRestWithSummary {
    # Show 'Hit a usage limit on <cli>, resting now till <when>' with a live countdown directly
    # below it. When the wait ends, the countdown line is erased and the header line is rewritten
    # in past tense: 'Hit a usage limit on <cli>, rested for X time'. Refuses to wait > 24h
    # (likely a weekly reset) - throws so the runner surfaces the error instead of blocking.
    param([string]$Cli, [datetime]$WakeTime)

    $now = Get-Date
    $waitSpan = $WakeTime - $now
    if ($waitSpan.TotalHours -gt 24) {
        $human = Format-UiDuration -Span $waitSpan
        $when = $WakeTime.ToString('ddd MMM d, h:mm tt')
        $msg = "Hit a usage limit on $Cli, reset not until $when (in $human). That is more than 24 hours - too long to wait, refusing (likely a weekly reset)."
        Write-Host ""
        Write-Host ("  " + $script:GlyphErr + " " + $msg) -ForegroundColor Red
        throw $msg
    }

    $wakeStr = if ($WakeTime.Date -eq $now.Date) {
        $WakeTime.ToString('h:mm tt')
    } else {
        $WakeTime.ToString('ddd MMM d, h:mm tt')
    }
    $presentMsg = "Hit a usage limit on " + $Cli + ", resting now till " + $wakeStr

    $start = Get-Date

    if (-not (Test-UiAnimatable)) {
        Write-Host ""
        Write-UiBeat -Glyph ([string]$script:GlyphMoon) -Message $presentMsg -Color Blue
        Invoke-UiRest -WakeTime $WakeTime
        $elapsed = (Get-Date) - $start
        if ($elapsed.TotalSeconds -ge 1) {
            Write-UiBeat -Glyph ([string]$script:GlyphMoon) -Message ("Hit a usage limit on " + $Cli + ", rested for " + (Format-UiDuration -Span $elapsed)) -Color Blue
        }
        return
    }

    # Animated: print the present-tense header via [Console]::Write so it can be overwritten in
    # place when the timer ends. Only the final past-tense line goes through Write-Host, so the
    # transcript records exactly one moon line per rest.
    Write-Host ""
    $prev = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = [System.ConsoleColor]::Blue
        [Console]::Write("  " + $script:GlyphMoon + " ")
        [Console]::ForegroundColor = [System.ConsoleColor]::Gray
        [Console]::Write($presentMsg)
    } finally { [Console]::ForegroundColor = $prev }
    [Console]::WriteLine()

    Invoke-UiRest -WakeTime $WakeTime
    $elapsed = (Get-Date) - $start

    # After Invoke-UiRest, the cursor sits at column 0 of the (now blank) countdown line; the
    # header is the line directly above. Wipe it before writing the past-tense replacement.
    try {
        $top = [Console]::CursorTop
        if ($top -gt 0) {
            $w = [Math]::Max(1, [Console]::WindowWidth - 1)
            [Console]::SetCursorPosition(0, $top - 1)
            [Console]::Write((' ' * $w))
            [Console]::SetCursorPosition(0, $top - 1)
        }
    } catch {}

    if ($elapsed.TotalSeconds -ge 1) {
        Write-UiBeat -Glyph ([string]$script:GlyphMoon) -Message ("Hit a usage limit on " + $Cli + ", rested for " + (Format-UiDuration -Span $elapsed)) -Color Blue
    }
}

function Invoke-UiRest {
    # Calm "resting" indicator with a live countdown while waiting out a usage limit. Falls back
    # to a plain Start-Sleep when output is redirected.
    param([datetime]$WakeTime)

    if (-not (Test-UiAnimatable)) {
        $secs = [int]($WakeTime - (Get-Date)).TotalSeconds
        if ($secs -gt 0) { Start-Sleep -Seconds $secs }
        return
    }

    $moons = @([char]0x25D0, [char]0x25D3, [char]0x25D1, [char]0x25D2)
    $mi = 0
    $cr = [string][char]13
    $cursorRestore = $null
    try { $cursorRestore = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch {}

    try {
        while ((Get-Date) -lt $WakeTime) {
            $remain = $WakeTime - (Get-Date)
            $cd = '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($remain.TotalHours), $remain.Minutes, $remain.Seconds
            [Console]::Write($cr)
            $prev = [Console]::ForegroundColor
            try {
                [Console]::ForegroundColor = [System.ConsoleColor]::Blue
                [Console]::Write("     " + $moons[$mi % $moons.Count] + " ")
                [Console]::ForegroundColor = [System.ConsoleColor]::DarkGray
                [Console]::Write("resting " + [char]0x00B7 + " " + $cd + " until " + $WakeTime.ToString('h:mm tt') + "   ")
            }
            finally { [Console]::ForegroundColor = $prev }

            Read-StopKey
            $armed = Test-StopRequested
            $hint = Get-StopHint -Armed:$armed
            $hintColor = if ($armed) { [System.ConsoleColor]::Yellow } else { [System.ConsoleColor]::DarkGray }
            Write-EphemeralFooter -Text ("   " + $hint) -ForegroundColor $hintColor
            if ($armed) { # Clear the active hint when armed - this is probably redundant, as the Write-EphemeralFooter should overwrite it.
                # I'll keep it as a safeguard, it won't hurt.
            }
            if (Test-StopRequested) { break }
            $mi++
            Start-Sleep -Milliseconds 1000
        }
    }
    finally {
        Clear-EphemeralFooter
        [Console]::Write($cr + (' ' * ([Math]::Max(60, [Console]::WindowWidth - 1))) + $cr) # Keep for safety
        if ($null -ne $cursorRestore) { try { [Console]::CursorVisible = $cursorRestore } catch {} }
    }
}

function Start-UiFakeWork {
    # Demo helper: drive the real spinner against a tiny sleeper process (no CLI is run).
    param([int]$Seconds = 4)
    if (-not (Test-UiAnimatable)) {
        Write-Host ("  " + $script:GlyphStar + " working...") -ForegroundColor $script:UiAccentColor
        Start-Sleep -Seconds $Seconds
        return
    }
    $p = Start-Process -FilePath (Get-Command powershell.exe).Source `
        -ArgumentList @('-NoProfile', '-Command', "Start-Sleep -Seconds $Seconds") `
        -NoNewWindow -PassThru
    Invoke-UiSpinner -Process $p
    try { $p.WaitForExit() } catch {}
}

function Write-UiResponseHeader {
    Write-Host ""
    Write-Host ("  " + $script:GlyphStar + " ") -ForegroundColor $script:UiAccentColor -NoNewline
    Write-Host "response" -ForegroundColor DarkGray
}

function Write-UiReason {
    # Format a failure reason: quoted on one line if short and single-line; otherwise Write-UiBody.
    # Used by error / blocked / stall messages so the agent's reason is always visible.
    param([string]$Text, [int]$MaxLines = 10)
    $r = if ($null -eq $Text) { '' } else { [string]$Text }
    $lines = @($r -split "`r?`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) {
        Write-Host '  "(no detail)"' -ForegroundColor Gray
        return
    }
    if ($lines.Count -eq 1) {
        Write-Host ('  "' + $lines[0] + '"') -ForegroundColor Gray
        return
    }
    Write-UiBody -Text $r -MaxLines $MaxLines -Color Gray
}

function Write-UiBody {
    # Print at most $MaxLines of a (possibly huge) block, then a dim "trimmed" note pointing at the
    # output file. Replies and especially errors can run to hundreds of lines; the FULL text is always
    # written to the per-task output file, so trimming the console view loses nothing.
    param([string]$Text, [int]$MaxLines = 10, [System.ConsoleColor]$Color)

    if ($null -eq $Text) { return }
    $hasColor = $PSBoundParameters.ContainsKey('Color')
    $lines = $Text -split "`r?`n"
    $show = [Math]::Min($MaxLines, $lines.Count)
    for ($i = 0; $i -lt $show; $i++) {
        if ($hasColor) { Write-Host $lines[$i] -ForegroundColor $Color } else { Write-Host $lines[$i] }
    }
    if ($lines.Count -gt $MaxLines) {
        $hidden = $lines.Count - $MaxLines
        $plural = if ($hidden -eq 1) { '' } else { 's' }
        Write-Host ("  " + $script:GlyphDot + " " + $hidden + " more line" + $plural + " trimmed " + $script:GlyphDot + " full text in the output file") -ForegroundColor DarkGray
    }
}

function Write-UiSeparator {
    # A dim rule drawn between tasks so each one reads as its own block.
    $rule = [string][char]0x2500
    Write-Host ""
    Write-Host ("  " + ($rule * 54)) -ForegroundColor DarkGray
}

function Invoke-UiDemo {
    # Scripted, no-network preview driven by limitshift-queue.example-workflow.json
    # (the shipped review -> fix -> verify pipeline). No CLIs run, no quota used.
    # The usage-limit / resting state plays on task 2 (Fix bugs with Copilot).
    #   .\limitshift-preview.ps1 -Demo

    $root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $workflowPath = Join-Path $root 'limitshift-queue.example-workflow.json'
    if (-not (Test-Path -LiteralPath $workflowPath)) {
        Write-Host ("  " + $script:GlyphErr + " Demo file not found: " + $workflowPath) -ForegroundColor Red
        return
    }
    $workflow = Get-Content -LiteralPath $workflowPath -Raw | ConvertFrom-Json
    $tasks = @($workflow.tasks)
    $count = $tasks.Count
    $script:UiTaskTotal = $count

    # Canned demo replies aligned with the workflow's review -> fix -> verify intent. The workflow
    # JSON sets completionCheck:true (see its "settings"), so each agent reply must end with the
    # [[TASK_COMPLETE]] marker on the very last line - that is the protocol the real runner parses.
    $replies = @(
        "Wrote bugs.md with 7 numbered issues found in src/ (auth, parsing, error handling).`n[[TASK_COMPLETE]]",
        "Walked bugs.md top to bottom; applied fixes and appended ' - FIXED' to each item.`n[[TASK_COMPLETE]]",
        "Audited bugs.md against current src/: 6 items verified fixed, 1 still broken (src/auth/token.ts: race on expired refresh).`n[[TASK_COMPLETE]]"
    )

    Write-UiHeader
    Write-UiQueueLine -TaskCount $count -Clis @($tasks | ForEach-Object { $_.cli })
    Write-Host ("    started " + (Get-Date).ToString('ddd HH:mm') + " " + $script:GlyphDot + " demo from " + (Split-Path -Leaf $workflowPath) + " (no CLIs are run)") -ForegroundColor DarkGray

    for ($k = 0; $k -lt $count; $k++) {
        $t = $tasks[$k]
        $taskNumber = $k + 1
        if ($k -gt 0) { Write-UiSeparator }

        # Optional model from the JSON (StrictMode 2 needs a property-presence check).
        $model = if ($t.PSObject.Properties['model']) { [string]$t.model } else { '' }

        # First run: full header with prompt preview.
        Write-UiTaskHeader -TaskNumber $taskNumber -TaskTotal $count -Task $t -Mode New -Model $model -PromptText $t.prompt
        Start-UiFakeWork -Seconds 4

        # Usage-limit / resting state plays on task 2 only. Mirrors the real runner:
        # silent during rest (the countdown is the indicator), past-tense beat after the timer is up,
        # then the resumed work starts straight from the spinner - NO repeated task header.
        if ($taskNumber -eq 2) {
            Invoke-UiRestWithSummary -Cli ([string]$t.cli) -WakeTime ((Get-Date).AddSeconds(2))
            Start-UiFakeWork -Seconds 2
        }

        Write-UiResponseHeader
        Write-UiBody -Text $replies[$k] -MaxLines 10
        Write-UiTaskDone -TaskNumber $taskNumber
    }

    # Real loop's settings.completionCheck applies to all tasks by default in this workflow JSON,
    # so the demo summary takes the "all completion-check, all succeeded" variant. Log path here
    # is illustrative only - nothing is written.
    Write-UiSummary -TaskCount $count -DoneCount $count -SkippedCount 0 -FailedCount 0 -NeedsHumanCount 0 -AllCompletionCheck $true `
        -LogPath '.\limitshift-queue\limitshift-log.txt' -StatePath '.\limitshift-queue'
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

    # Drop a self-explaining README inside the state folder (overwritten every init), keep the folder
    # out of git regardless of its name, and make sure runs.csv has its header row.
    Write-StateReadme
    Write-StateGitignore
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

Re-running:
  Delete this whole folder to start completely from scratch.
  Delete status/task-NN.done to force ONE task to run again.
  Editing a task's name, prompt, cli, projectPath, model, effort, or extraArgs now AUTO-INVALIDATES
  its done marker: the runner notices the change and re-runs that task with a fresh session.
"@
    Set-Content -LiteralPath $StateReadmePath -Value $readme -Encoding UTF8
}

function Write-StateGitignore {
    # Keep the state folder out of git no matter what it is named. The repo's global "limitshift-*/"
    # ignore rule only matches the default queue's folder; a queue named e.g. career-ops_01.json now
    # produces a career-ops_01/ folder that rule would miss. A self-ignoring ".gitignore" (excludes
    # everything, including itself) makes the folder invisible to git regardless of its name, so
    # private transcripts/prompts never get committed.
    Set-Content -LiteralPath $StateGitignorePath -Value '*' -Encoding UTF8
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
        [string]$Status,
        [string]$Cli,
        [string]$Model
    )

    $row = @(
        (ConvertTo-CsvField -Value ((Get-Date).ToString('s'))),
        (ConvertTo-CsvField -Value $Task),
        (ConvertTo-CsvField -Value ([string]$Run)),
        (ConvertTo-CsvField -Value $Mode),
        (ConvertTo-CsvField -Value ([string]$Exit)),
        (ConvertTo-CsvField -Value $Status),
        (ConvertTo-CsvField -Value $Cli),
        (ConvertTo-CsvField -Value $Model)
    ) -join ','

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($RunsCsvPath, $row + [Environment]::NewLine, $utf8NoBom)
}

$script:AllowedClis = @('claude', 'codex', 'gemini', 'agy', 'copilot')

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

function Test-IsOllamaRunner {
    param($Runner)
    if ($Runner.Cli -ne 'claude') { return $false }
    return (Test-ExtraArgsRequestOllama -ExtraArgs $Runner.ExtraArgs)
}

# Git state does not change during a single run, and a fallbacks queue probes the same projectPath
# once per task. A direct `& git` call is ~56ms; the old Start-Process -Wait was ~1s each, so 2
# probes per task x N tasks froze startup for many seconds (e.g. ~22s on an 11-task queue). Use a
# direct call (stderr discarded, exit code read) and memoize per path so each probe runs once.
$script:GitProbeCache = @{}

function Invoke-GitProbe {
    param([string]$Path, [string[]]$GitArgs, [string]$CacheKind)
    $key = $CacheKind + [char]0x1F + $Path
    if ($script:GitProbeCache.ContainsKey($key)) { return $script:GitProbeCache[$key] }
    $ok = $false
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & git -C "$Path" @GitArgs 2>$null | Out-Null
            $ok = ($LASTEXITCODE -eq 0)
        } catch { $ok = $false }
        finally { $ErrorActionPreference = $prevEAP }
    }
    $script:GitProbeCache[$key] = $ok
    return $ok
}

function Test-IsGitRepo {
    param([string]$Path)
    return (Invoke-GitProbe -Path $Path -GitArgs @('rev-parse', '--is-inside-work-tree') -CacheKind 'repo')
}

function Test-HasCommits {
    param([string]$Path)
    return (Invoke-GitProbe -Path $Path -GitArgs @('rev-parse', 'HEAD') -CacheKind 'head')
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

    function Parse-Runner {
        param($Node, $TaskNumber, $Label)

        $displayLabel = if ($Label -eq 'task') { "" } else { " ($Label)" }

        $cliProp = $Node.PSObject.Properties['cli']
        if ($null -eq $cliProp -or [string]::IsNullOrWhiteSpace([string]$cliProp.Value)) {
            throw "Task $TaskNumber$displayLabel is missing required JSON property: cli"
        }
        $cli = ([string]$cliProp.Value).ToLower()
        if ($script:AllowedClis -notcontains $cli) {
            throw "Task $TaskNumber$displayLabel has unknown cli `"$($cliProp.Value)`". Allowed values: $($script:AllowedClis -join ', ')"
        }

        $extraArgs = [string[]]@()
        $extraNode = $Node.PSObject.Properties['extraArgs']
        if ($null -ne $extraNode -and $null -ne $extraNode.Value) {
            if ($extraNode.Value -is [string]) {
                $extraArgs = [string[]]@($extraNode.Value -split '\s+' | Where-Object { $_ })
            }
            elseif ($extraNode.Value -is [System.Array]) {
                $extraArgs = [string[]]@($extraNode.Value | ForEach-Object { [string]$_ })
            }
            else {
                throw "Task $TaskNumber$displayLabel extraArgs must be a string or an array of strings."
            }
        }

        # Task 6: model may be a single string OR an ordered array of strings (preference order).
        $models = [string[]]@()
        $modelNode = $Node.PSObject.Properties['model']
        if ($null -ne $modelNode -and $null -ne $modelNode.Value) {
            $modelValue = $modelNode.Value
            if ($modelValue -is [string]) {
                $models = [string[]]@($modelValue)
            }
            elseif ($modelValue -is [System.Array]) {
                if (@($modelValue).Count -eq 0) {
                    throw "Task $TaskNumber$displayLabel model array must not be empty. Use a single string, or list one or more model names in preference order."
                }
                foreach ($element in $modelValue) {
                    if ($null -eq $element -or -not ($element -is [string])) {
                        throw "Task $TaskNumber$displayLabel model array must contain only strings (got a non-string element)."
                    }
                }
                $models = [string[]]@($modelValue | ForEach-Object { [string]$_ })
            }
            else {
                throw "Task $TaskNumber$displayLabel model must be a string or an array of strings."
            }
        }
        $model = if ($models.Count -gt 0) { $models[0] } else { $null }

        # Local Ollama mode (claude): the model is selected by `ollama launch --model`, so it is
        # required. (codex reaches Ollama natively and needs no model-for-launcher.)
        if ($cli -eq 'claude' -and (Test-ExtraArgsRequestOllama -ExtraArgs $extraArgs) -and $models.Count -eq 0) {
            throw "Task $TaskNumber$($displayLabel): a local Ollama claude task needs a model (it is passed to 'ollama launch --model'). Set `"model`" to your Ollama model, e.g. `"qwen3.5:9b`"."
        }

        # Claude headless (-p) doesn't expand dotted aliases the way the TUI does, so a queue model
        # like "claude-opus-4.6" reaches the API verbatim and 404s mid-run. Reject the dot form at
        # validation. Ollama-launched claude tasks pass the model to `ollama launch --model`, where
        # dots are normal (e.g. "qwen3.5:9b"), so skip them.
        if ($cli -eq 'claude' -and -not (Test-ExtraArgsRequestOllama -ExtraArgs $extraArgs)) {
            foreach ($m in $models) {
                if ($m -like '*.*') {
                    throw "Task $TaskNumber$($displayLabel): claude model `"$m`" contains a dot. Claude headless mode (-p) does not expand the dotted form; use the hyphenated id (e.g. `"claude-opus-4-6`") or an alias (`"opus`", `"sonnet`", `"haiku`")."
                }
            }
        }

        # Effort normalization: treat absent, JSON null, and "" all as "no effort" (null).
        $effort = $null
        if ($Node.PSObject.Properties['effort'] -and $null -ne $Node.effort) {
            $effortText = ([string]$Node.effort).Trim()
            if ($effortText.Length -gt 0) { $effort = $effortText }
        }

        # Task 6b: enforce the SAME per-CLI effort rules the schema declares (editor-only), so a
        # misconfigured queue fails at validation (exit 2) instead of mid-run.
        if ($null -ne $effort) {
            switch ($cli) {
                'gemini' {
                    throw "Task $TaskNumber$($displayLabel): gemini has no effort flag; set `"effort`": null (use thinkingLevel/thinkingBudget via gemini settings instead)."
                }
                'agy' {
                    throw "Task $TaskNumber$($displayLabel): agy (Antigravity CLI) has no --effort flag; set `"effort`": null."
                }
                'claude' {
                    $claudeEfforts = @('low', 'medium', 'high', 'xhigh', 'max')
                    if ($effort -eq 'ultracode') {
                        throw "Task $TaskNumber$($displayLabel): 'ultracode' is only available from the interactive /effort menu, not the --effort flag. Use low|medium|high|xhigh|max."
                    }
                    if ($claudeEfforts -notcontains $effort) {
                        throw "Task $TaskNumber$($displayLabel): claude effort must be one of low, medium, high, xhigh, max (or null)."
                    }
                    # Haiku 4.5 supports no effort. Model may be a list (Task 6): reject if ANY matches haiku.
                    $haikuMatch = @($models | Where-Object { $_ -match '(?i)haiku' }).Count -gt 0
                    if ($haikuMatch) {
                        throw "Task $TaskNumber$($displayLabel): claude model haiku does not support effort; set `"effort`": null."
                    }
                }
                'codex' {
                    $codexEfforts = @('minimal', 'low', 'medium', 'high', 'xhigh')
                    if ($codexEfforts -notcontains $effort) {
                        throw "Task $TaskNumber$($displayLabel): codex effort must be one of minimal, low, medium, high, xhigh (or null). 'none' is plan-mode only."
                    }
                }
                'copilot' {
                    $copilotEfforts = @('low', 'medium', 'high', 'xhigh', 'max')
                    if ($copilotEfforts -notcontains $effort) {
                        throw "Task $TaskNumber$($displayLabel): copilot effort must be one of low, medium, high, xhigh, max (or null)."
                    }
                }
            }
        }

        return [pscustomobject]@{
            Cli       = $cli
            Model     = $model
            Models    = $models
            Effort    = $effort
            ExtraArgs = $extraArgs
        }
    }

    # recoveryAttempts: non-negative integer, default 0.
    $globalRecoveryAttempts = 0
    $globalRecoveryAttemptsPresent = $false
    if ($null -ne $settingsNode -and $null -ne $settingsNode.Value) {
        $recoveryNode = $settingsNode.Value.PSObject.Properties['recoveryAttempts']
        if ($null -ne $recoveryNode -and $null -ne $recoveryNode.Value) {
            $globalRecoveryAttemptsPresent = $true
            if ($recoveryNode.Value -isnot [int] -or $recoveryNode.Value -lt 0) {
                throw "settings.recoveryAttempts must be an integer >= 0."
            }
            $globalRecoveryAttempts = [int]$recoveryNode.Value
        }
    }
    $settings['RecoveryAttempts'] = $globalRecoveryAttempts

    $tasks = @()
    for ($i = 0; $i -lt $rawTasks.Count; $i++) {
        $t = $rawTasks[$i]
        $n = $i + 1

        # Base fields required for every task. cli/model/effort/extraArgs are parsed into
        # the first runner by Parse-Runner.
        foreach ($required in @('name', 'projectPath', 'prompt')) {
            $p = $t.PSObject.Properties[$required]
            if ($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.Value)) {
                throw "Task $n is missing required JSON property: $required"
            }
        }

        $projectPath = $t.projectPath
        if (-not [System.IO.Path]::IsPathRooted($projectPath)) {
            $projectPath = Join-Path (Get-Location) $projectPath
        }
        $projectPath = [System.IO.Path]::GetFullPath($projectPath)
        if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) {
            throw "Project path does not exist for task $n (`"$($t.name)`"): $projectPath"
        }

        # recoveryAttempts: placement is strictly either/or.
        $taskRecoveryAttempts = 0
        $tRecoveryNode = $t.PSObject.Properties['recoveryAttempts']
        if ($null -ne $tRecoveryNode -and $null -ne $tRecoveryNode.Value) {
            if ($tRecoveryNode.Value -isnot [int] -or $tRecoveryNode.Value -lt 0) {
                throw "Task $n recoveryAttempts must be an integer >= 0."
            }
            $taskRecoveryAttempts = [int]$tRecoveryNode.Value

            # Either/or placement (spec 5.2).
            if ($globalRecoveryAttemptsPresent) {
                throw "recoveryAttempts may be set in settings OR on individual tasks, not both - found in settings and on task $n."
            }
        }

        $effectiveRecoveryAttempts = if ($null -ne $tRecoveryNode -and $null -ne $tRecoveryNode.Value) { $taskRecoveryAttempts } else { $globalRecoveryAttempts }

        # Parse the flat task fields as Runner 0.
        $runners = @(Parse-Runner -Node $t -TaskNumber $n -Label 'task')

        # Parse the fallbacks list (Task 2.1).
        $fallbackNode = $t.PSObject.Properties['fallbacks']
        if ($null -ne $fallbackNode -and $null -ne $fallbackNode.Value) {
            $rawFallbacks = @($fallbackNode.Value)
            for ($k = 0; $k -lt $rawFallbacks.Count; $k++) {
                $runners += Parse-Runner -Node $rawFallbacks[$k] -TaskNumber $n -Label "fallback $($k+1)"
            }
        }

        # Task 4.1: Require a git working tree for tasks with fallbacks.
        if ($runners.Count -gt 1) {
            if (-not (Test-IsGitRepo -Path $projectPath)) {
                throw "Task $n (`"$($t.name)`") has fallbacks, which requires the projectPath to be a git repository. The provided projectPath is not a git repository: $projectPath"
            }
            if (-not (Test-HasCommits -Path $projectPath)) {
                Write-Host "[$GlyphStar] Task $n WARNING: projectPath $projectPath is a git repository but has no commits. Fingerprinting and handoff (git diff) will be less precise. Guidance: commit a baseline before starting rotation work." -ForegroundColor Yellow
            }
        }

        # completionCheck: per-task override beats the global setting, which defaults to true.
        $completionCheck = [bool]$settings['CompletionCheck']
        $completionCheckNode = $t.PSObject.Properties['completionCheck']
        if ($null -ne $completionCheckNode -and $null -ne $completionCheckNode.Value) {
            $completionCheck = [bool]$completionCheckNode.Value
        }

        # Completion-check dependency (spec 5.3).
        if ($effectiveRecoveryAttempts -gt 0 -and -not $completionCheck) {
            throw "Task $n (`"$($t.name)`") has recoveryAttempts > 0 but completionCheck is false. Recovery requires completion checking."
        }

        # The task object keeps the runner 0 fields at the top level for back-compat (Mode,
        # Effort, etc used by fingerprinting and the UI) and carries the full runner list.
        $tasks += [pscustomobject]@{
            Name             = [string]$t.name
            Cli              = $runners[0].Cli
            ProjectPath      = $projectPath
            Model            = $runners[0].Model
            Models           = $runners[0].Models
            Effort           = $runners[0].Effort
            Prompt           = [string]$t.prompt
            ExtraArgs        = $runners[0].ExtraArgs
            Runners          = $runners
            CompletionCheck  = $completionCheck
            RecoveryAttempts = $effectiveRecoveryAttempts
        }
    }

    return @{ Settings = $settings; Tasks = $tasks }
}

function Test-CliBinariesAvailable {
    param($Tasks)

    $needed = @()
    foreach ($t in $Tasks) {
        foreach ($r in $t.Runners) {
            $needed += $r.Cli
            # A claude task targeting a local Ollama model is launched via `ollama`, so it must be present too.
            if ($r.Cli -eq 'claude' -and (Test-ExtraArgsRequestOllama -ExtraArgs $r.ExtraArgs)) {
                $needed += 'ollama'
            }
        }
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

    # Phase 3: include fallbacks in the task fingerprint (Task 3.1).
    # Skip runner 0 (it is already represented by the existing fields above).
    # Append the segment ONLY when there is at least one fallback runner.
    $runnersProp = $Task.PSObject.Properties['Runners']
    if ($null -ne $runnersProp -and @($runnersProp.Value).Count -gt 1) {
        $fbParts = foreach ($r in @($runnersProp.Value)[1..(@($runnersProp.Value).Count - 1)]) {
            $rModels = if ($r.PSObject.Properties['Models'] -and $r.Models) { (@($r.Models) -join ' ') } else { '' }
            $rEffort = if ($null -ne $r.Effort) { [string]$r.Effort } else { '' }
            $rExtra  = if ($r.PSObject.Properties['ExtraArgs'] -and $r.ExtraArgs) { (@($r.ExtraArgs) -join ' ') } else { '' }
            ($r.Cli, $rModels, $rEffort, $rExtra) -join ([char]0x1F)
        }
        $canonical = $canonical + ([char]0x1E) + ($fbParts -join ([char]0x1E))
    }

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

# Task 9.1: runner-index and per-runner model-index persistence (fallbacks tasks only).
# These files are created ONLY when a task has fallbacks (Runners.Count > 1). The runner-index
# file records which runner is active so a Ctrl-C restart resumes the same runner; the per-runner
# model-index scopes the existing model-rotation index to the specific runner.
function Get-TaskRunnerIndexFilePath {
    param([int]$TaskIndex)
    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    return Join-Path $SessionStatePath "$taskKey-runner-index.txt"
}

function Get-SavedTaskRunnerIndex {
    param([int]$TaskIndex)
    $path = Get-TaskRunnerIndexFilePath -TaskIndex $TaskIndex
    if (Test-Path -LiteralPath $path) {
        $raw = (Get-Content -LiteralPath $path -Raw).Trim()
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
    }
    return 0
}

function Save-TaskRunnerIndex {
    param([int]$TaskIndex, [int]$RunnerIndex)
    $path = Get-TaskRunnerIndexFilePath -TaskIndex $TaskIndex
    [string]$RunnerIndex | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-TaskRunnerModelIndexFilePath {
    param([int]$TaskIndex, [int]$RunnerIndex)
    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    return Join-Path $SessionStatePath "$taskKey-runner-$RunnerIndex-model-index.txt"
}

function Get-SavedTaskRunnerModelIndex {
    param([int]$TaskIndex, [int]$RunnerIndex)
    $path = Get-TaskRunnerModelIndexFilePath -TaskIndex $TaskIndex -RunnerIndex $RunnerIndex
    if (Test-Path -LiteralPath $path) {
        $raw = (Get-Content -LiteralPath $path -Raw).Trim()
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
    }
    return 0
}

function Save-TaskRunnerModelIndex {
    param([int]$TaskIndex, [int]$RunnerIndex, [int]$ModelIndex)
    $path = Get-TaskRunnerModelIndexFilePath -TaskIndex $TaskIndex -RunnerIndex $RunnerIndex
    [string]$ModelIndex | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-TaskRecoveryAttemptsFilePath {
    param([int]$TaskIndex)
    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    return Join-Path $SessionStatePath "$taskKey-recovery-attempts.txt"
}

function Get-SavedTaskRecoveryAttempts {
    param([int]$TaskIndex)
    $path = Get-TaskRecoveryAttemptsFilePath -TaskIndex $TaskIndex
    if (Test-Path -LiteralPath $path) {
        $raw = (Get-Content -LiteralPath $path -Raw).Trim()
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
    }
    return 0
}

function Save-TaskRecoveryAttempts {
    param([int]$TaskIndex, [int]$Attempts)
    $path = Get-TaskRecoveryAttemptsFilePath -TaskIndex $TaskIndex
    [string]$Attempts | Set-Content -LiteralPath $path -Encoding UTF8
}

function Clear-TaskRecoveryAttempts {
    param([int]$TaskIndex)
    Remove-Item -LiteralPath (Get-TaskRecoveryAttemptsFilePath -TaskIndex $TaskIndex) -Force -ErrorAction SilentlyContinue
}

function Save-TaskNeedsHumanMarker {
    param([int]$TaskIndex, [string]$Reason)
    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    $Reason | Set-Content -LiteralPath (Join-Path $StatusStatePath "$taskKey.needs-human") -Encoding UTF8
}

function Get-TaskOutputTail {
    param([string]$FilePath, [int]$MaxLines = 40, [int]$MaxBytes = 2048)
    if (-not (Test-Path -LiteralPath $FilePath)) { return '' }
    $lines = @(Get-Content -LiteralPath $FilePath -Tail $MaxLines)
    $text = $lines -join [Environment]::NewLine
    if ($text.Length -gt $MaxBytes) {
        $text = $text.Substring($text.Length - $MaxBytes)
    }
    return $text
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
    $taskKey = Get-TaskKey -TaskIndex $TaskIndex
    Remove-Item -LiteralPath (Join-Path $StatusStatePath "$taskKey.needs-human") -Force -ErrorAction SilentlyContinue
    Clear-TaskRecoveryAttempts -TaskIndex $TaskIndex
}

# NOTE: As of 1.2.x the runner no longer calls `claude -p "/usage"` as a pre-check. Anthropic's
# `/usage` output changed for subscription accounts (a one-line notice instead of percentages) and
# is going to bifurcate further when the Agent-SDK / `claude -p` credit pool ships separately from
# the interactive subscription. The pre-check was speculative and tied to a parser we no longer
# control. Limit handling is now entirely reactive: classify the CLI's response (Anthropic's limit
# wording in stderr/stdout) via `ConvertFrom-CliOutput` and the per-CLI `$LimitPatterns`, then
# rotate / wait. Reset times come from the limit-error text via `Get-ResetTimeFromErrorText`,
# falling back to `settings.limitWaitMinutes`.
$script:HandoffNoteBase = "A previous AI tool started this task and was interrupted (usage limit or failure). Partial work may already exist in the working tree. Before doing anything, inspect both ``git status`` (for new/untracked files) and ``git diff`` (for changes to tracked files) to see what has already been done. Continue from there; do not redo finished work."

$script:RecoveryNudgeBase = @"
You ended with $($TaskBlockedMarker): {0}.
Recovery is enabled - do not stop yet. Reconsider and find another way to finish this task.
Inspect ``git status`` and ``git diff`` first so you do not redo work already done.

- If you finish, end your final response with $($TaskCompleteMarker).
- If you genuinely need a human (secrets/credentials you cannot access, an irreversible
  or destructive action, a product/design decision, or something you cannot verify
  yourself), end with $($TaskBlockedMarker) HUMAN: <one-line reason> and stop.
- If you are still stuck but it is not a human-only blocker, end with $($TaskBlockedMarker) <reason>.
"@

function Get-TaskPromptWithHandoff {
    param($Task, [string]$FailureReason = $null, [string]$FailureOutputTail = $null)

    $note = $script:HandoffNoteBase
    $recoveryAttempts = [int](Get-ObjectPropertyValue -Object $Task -Name 'RecoveryAttempts' -Default 0)
    if ($recoveryAttempts -gt 0 -and (-not [string]::IsNullOrWhiteSpace($FailureReason) -or -not [string]::IsNullOrWhiteSpace($FailureOutputTail))) {
        $note = "A previous AI tool worked on this task and could not continue ($FailureReason). Partial work may already exist - inspect ``git status`` and ``git diff`` first; continue from there, do not redo finished work.`n`nThis is why the previous attempt did not finish:`n"
        if ($FailureReason) { $note += "$FailureReason`n" }
        if ($FailureOutputTail) { $note += "$FailureOutputTail`n" }
    }

    if ([bool](Get-ObjectPropertyValue -Object $Task -Name 'CompletionCheck' -Default $true)) {
        $note += " End your final response with ``$TaskCompleteMarker`` when the task is fully done, or ``$TaskBlockedMarker <reason>`` if it genuinely cannot be completed."
    }

    $base = Get-TaskPromptWithCompletionMarker -Task $Task
    return $note + "`n`n" + $base
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
    param($Task, [string]$RecoveryReason = $null)

    $preamble = "Continue the previous task in this same session from where you stopped. Do not restart from scratch.`nIf the session has no prior progress, start the task now."
    $recoveryAttempts = [int](Get-ObjectPropertyValue -Object $Task -Name 'RecoveryAttempts' -Default 0)
    if ($recoveryAttempts -gt 0 -and $RecoveryReason) {
        $preamble = $script:RecoveryNudgeBase -f $RecoveryReason
    }

    # The marker block is only appended when completion checking is on (Task 2).
    $completionCheck = [bool](Get-ObjectPropertyValue -Object $Task -Name 'CompletionCheck' -Default $true)
    $markerBlock = if ($completionCheck) { "`n`n" + (Get-CompletionMarkerInstructions) } else { '' }

    # Task 3 (Bug C): one unified resume template for all three CLIs. The resume prompt now
    # repeats the original task verbatim so a thin session and slash commands (e.g. /goal)
    # survive the resume instead of leaving the agent with nothing to continue.
    return @"
$preamble

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
        [string]$StdinText,
        [string]$Cli,
        [switch]$Spinner
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
    $processTimer = $null

    try {
        # When animating the working indicator we must NOT block on Start-Process; we launch and
        # poll the process while redrawing the spinner in place. Every other call (and any run with
        # redirected output) keeps the original blocking -Wait behavior unchanged.
        $animate = $Spinner -and (Test-UiAnimatable)

        $startProcessParams = @{
            FilePath               = $launcherPath
            WorkingDirectory       = $WorkingDirectory
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError  = $stderrPath
        }
        if ((Get-Command Start-Process).Parameters.ContainsKey('CreateNoWindow')) {
            $startProcessParams['CreateNoWindow'] = ($Cli -eq 'agy')
        }
        if (-not $animate) { $startProcessParams['Wait'] = $true }

        # Start-Process rejects an empty/null ArgumentList; only add it when there are real args.
        if (-not [string]::IsNullOrEmpty($launcherArguments)) {
            $startProcessParams['ArgumentList'] = $launcherArguments
        }

        if ($PSBoundParameters.ContainsKey('StdinText') -and $null -ne $StdinText) {
            $stdinPath = Join-Path ([System.IO.Path]::GetTempPath()) ("limitshift-stdin-" + [guid]::NewGuid() + ".txt")
            [System.IO.File]::WriteAllText($stdinPath, $StdinText, [System.Text.UTF8Encoding]::new($false))
            $startProcessParams['RedirectStandardInput'] = $stdinPath
        }

        # Redirected output (no TTY) can't animate: print one static line so logs aren't silent.
        if ($Spinner -and -not $animate) {
            Write-Host ("  " + $script:GlyphStar + " working...") -ForegroundColor $script:UiAccentColor
        }

        $processTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $process = Start-Process @startProcessParams

        if ($animate) {
            # Cache the process handle so .ExitCode survives after a non-blocking (-PassThru, no -Wait)
            # process exits. Without this the exit code reads back as $null and breaks output
            # classification. The blocking (-Wait) path populates ExitCode on its own.
            try { $null = $process.Handle } catch {}
            Invoke-UiSpinner -Process $process
        }
        # Make sure the process has fully exited and its redirected files are flushed before reading.
        try { $process.WaitForExit() } catch {}
        if ($null -ne $processTimer) {
            $processTimer.Stop()
            Add-UiSessionTotalTime -Span $processTimer.Elapsed
            $processTimer = $null
        }

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
        if ($null -ne $processTimer) {
            try { $processTimer.Stop() } catch {}
            Add-UiSessionTotalTime -Span $processTimer.Elapsed
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
    param(
        [bool]$Ok,
        [bool]$IsLimit,
        [string]$Text,
        [string]$SessionId,
        [string]$ErrorText,
        [bool]$SessionLost = $false,
        [bool]$SlashRejected = $false
    )
    return @{
        Ok            = $Ok
        IsLimit       = $IsLimit
        Text          = $Text
        SessionId     = $SessionId
        ErrorText     = $ErrorText
        # SessionLost: claude returned 'No conversation found with session ID' (or equivalent).
        # The runner deletes the saved session id and re-runs as Mode=New on the SAME runner;
        # the attempt does not count against recoveryAttempts (the state file drifted from claude's
        # local conversation store — not the agent's fault).
        SessionLost   = $SessionLost
        # SlashRejected: claude returned 'Unknown command: /xxx' because the prompt began with a
        # slash and `-p` parsed it as a slash command. The task is flagged for a human; retrying
        # cannot fix it without editing the prompt.
        SlashRejected = $SlashRejected
    }
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
        # Anthropic's interactive-subscription limit wording, plus the credit-pool wording that is
        # likely to appear when `claude -p` / Agent-SDK moves to a separate monthly credit. The
        # regex stays permissive on purpose — it only matters when the run already failed.
        claude = '(?i)(you''ve hit your .{0,40}limit|usage limit|out of credits?|credits? (exceeded|exhausted|remaining)|monthly credit|insufficient credits|agent sdk.{0,30}limit|429|too many requests)'
        codex  = '(?i)(usage limit|rate limit|too many requests|try again (at|in)|quota)'
        gemini = '(?i)(quota exceeded|resource_exhausted|ratelimitexceeded|model_capacity_exhausted|no capacity available|daily quota|usage limit reached|rate limit|429|too many requests)'
        agy    = '(?i)(quota exceeded|resource_exhausted|model_capacity_exhausted|no capacity available|insufficient quota|out of quota|daily quota|usage limit|rate ?limit|429|too many requests|try again (at|in))'
        copilot = '(?i)(usage limit|rate limit|too many requests|quota|premium requests|billing|try again at|try again in|429)'
    }

    # Claude-specific recoverable signals (see New-CliResult notes for handling).
    $ClaudeSessionLostPattern = '(?i)No conversation found with session ID'
    $ClaudeSlashRejectedPattern = '(?i)Unknown command:\s*/'

    $limitRegex = $LimitPatterns[$Cli]

    switch ($Cli) {
        'claude' {
            $json = ConvertFrom-JsonTolerant -Text $OutputText
            if ($null -eq $json) {
                $isLimit = ($OutputText -match $limitRegex)
                $sessionLost = ($OutputText -match $ClaudeSessionLostPattern)
                $slashRejected = ($OutputText -match $ClaudeSlashRejectedPattern)
                return New-CliResult -Ok $false -IsLimit $isLimit -Text $OutputText -SessionId $null `
                    -ErrorText $OutputText -SessionLost $sessionLost -SlashRejected $slashRejected
            }
            $text = [string](Get-ObjectPropertyValue -Object $json -Name 'result' -Default '')
            $sessionId = [string](Get-ObjectPropertyValue -Object $json -Name 'session_id' -Default $null)
            $isError = [bool](Get-ObjectPropertyValue -Object $json -Name 'is_error' -Default $false) -or ($ExitCode -ne 0)
            $isLimit = $isError -and ($text -match $limitRegex)
            # The session-lost / slash-rejected messages may surface either in the JSON `result`
            # field (claude returned a JSON envelope with the error inside) or in raw stderr that
            # bypassed JSON parsing (claude failed before producing JSON). Check both surfaces.
            $sessionLost = ($text -match $ClaudeSessionLostPattern) -or ($OutputText -match $ClaudeSessionLostPattern)
            $slashRejected = ($text -match $ClaudeSlashRejectedPattern) -or ($OutputText -match $ClaudeSlashRejectedPattern)
            return New-CliResult -Ok (-not $isError) -IsLimit $isLimit -Text $text `
                -SessionId $sessionId -ErrorText $(if ($isError) { $text } else { $null }) `
                -SessionLost $sessionLost -SlashRejected $slashRejected
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
                # Copilot wraps the payload inside `data` (e.g. {type:'assistant.message', data:{content:'...'}})
                # so look in BOTH places. This is a preview-only fix - upstream limitshift.ps1 has the same gap.
                $evtData = Get-ObjectPropertyValue -Object $evt -Name 'data' -Default $null
                if ($eventType -in @('assistant.message','assistant','message','response','completion','final') -or
                    ([string](Get-ObjectPropertyValue -Object $evt -Name 'role' -Default '') -eq 'assistant') -or
                    ([string](Get-ObjectPropertyValue -Object $evtData -Name 'role' -Default '') -eq 'assistant')) {
                    foreach ($contentName in @('content', 'text', 'message')) {
                        $content = [string](Get-ObjectPropertyValue -Object $evt -Name $contentName -Default $null)
                        if ([string]::IsNullOrEmpty($content) -and $null -ne $evtData) {
                            $content = [string](Get-ObjectPropertyValue -Object $evtData -Name $contentName -Default $null)
                        }
                        if (-not [string]::IsNullOrEmpty($content)) { $textParts += $content; break }
                    }
                }
                foreach ($sidName in @('interactionId', 'session_id', 'sessionId', 'conversation_id', 'conversationId', 'thread_id', 'threadId')) {
                    $sid = [string](Get-ObjectPropertyValue -Object $evt -Name $sidName -Default $null)
                    if ([string]::IsNullOrWhiteSpace($sid) -and $null -ne $evtData) {
                        $sid = [string](Get-ObjectPropertyValue -Object $evtData -Name $sidName -Default $null)
                    }
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
        [string]$ModelOverride,
        # When set, suppress the task header. The caller (main loop) is responsible for printing a
        # contextual one-liner (limit summary, retry line, no-marker resume) BEFORE this call instead.
        # Used for any within-run continuation so the task header doesn't repeat.
        [switch]$Quiet,
        # When set on a New-mode run, prepend the runner-handoff preamble so the incoming runner
        # knows partial work may already exist in the working tree.
        [switch]$UseHandoffNote,
        # Block recovery: pass the failure context for Variant B (New mode) or Variant A (Resume).
        [string]$RecoveryReason,
        [string]$RecoveryOutputTail
    )

    $outputFilePath = Get-TaskOutputFilePath -TaskIndex $TaskIndex -Task $Task
    if ($Mode -eq 'New' -and (Test-Path -LiteralPath $outputFilePath)) {
        Remove-Item -LiteralPath $outputFilePath -Force
    }

    if ($Mode -eq 'New') {
        $prompt = if ($UseHandoffNote) { Get-TaskPromptWithHandoff -Task $Task -FailureReason $RecoveryReason -FailureOutputTail $RecoveryOutputTail } else { Get-TaskPromptWithCompletionMarker -Task $Task }
    }
    else {
        $prompt = Get-ResumePrompt -Task $Task -RecoveryReason $RecoveryReason
    }

    $cliArgsParams = @{ Task = $Task; Mode = $Mode; SessionId = $SessionId; Prompt = $prompt }
    if ($PSBoundParameters.ContainsKey('ModelOverride')) { $cliArgsParams['ModelOverride'] = $ModelOverride }
    $arguments = Get-CliArguments @cliArgsParams
    $exe = Get-CliExecutable -Task $Task

    if (-not $Quiet) {
        Write-UiTaskHeader -TaskNumber ($TaskIndex + 1) -TaskTotal $script:UiTaskTotal -Task $Task -Mode $Mode -Model $ModelOverride -PromptText $Task.Prompt
    }
    if ($DryRun) {
        # Dry-run prints the assembled command at column 0 so it's greppable - the whole point of
        # dry-run is "show me what would run". Format matches the pre-preview-UI style intentionally.
        Write-Host "Command: $(Format-CommandForDisplay -Command $exe -Arguments $arguments)"
        return New-CliResult -Ok $true -IsLimit $false -Text '[dry-run]' -SessionId $null -ErrorText $null
    }
    if ($ShowRawOutput) {
        Write-Host ("  " + $script:GlyphDot + " command: " + (Format-CommandForDisplay -Command $exe -Arguments $arguments)) -ForegroundColor DarkGray
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    # Log the full prompt before the run; the displayed command line no longer contains it.
    [System.IO.File]::AppendAllText($outputFilePath, $prompt + [Environment]::NewLine + [Environment]::NewLine, $utf8NoBom)

    # agy and copilot take the prompt as the -p argument (not stdin); the other CLIs read it from stdin.
    # agy and copilot still need a CLOSED/EOF stdin: under Start-Process an inherited (unredirected) stdin
    # handle makes them block reading it indefinitely. Hand them an empty stdin so they get immediate
    # EOF — this mirrors limitshift.sh, which runs them with `</dev/null`.
    $invokeParams = @{
        Command = $exe;
        Arguments = $arguments;
        WorkingDirectory = $Task.ProjectPath;
        Spinner = if ($Task.Cli -eq 'agy') { $false } else { $true } # Disable spinner for agy
    }
    $invokeParams['StdinText'] = if ($Task.Cli -eq 'agy' -or $Task.Cli -eq 'copilot') { '' } else { $prompt }

    # If agy, show a static "agy working..." message instead of the animated spinner.
    if ($Task.Cli -eq 'agy' -and -not $Quiet) {
        Write-Host ("  " + $script:GlyphStar + " agy working...") -ForegroundColor $script:UiAccentColor
    }
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
        # -ShowRawOutput dumps the full text. Otherwise show the reply only for a successful run,
        # trimmed to the first lines; failures and limits are reported with their reason by the loop.
        if ($ShowRawOutput) {
            Write-UiResponseHeader
            Write-Host $consoleText
        }
        elseif ($result.Ok) {
            Write-UiResponseHeader
            Write-UiBody -Text $consoleText -MaxLines 10
        }
    }

    return $result
}

# Build a DateTime from an optional date token and a clock token recovered from a CLI's
# usage-limit error. With no date the clock is taken as today and rolled to tomorrow if already
# past; with a date but no explicit year the current year is assumed and rolled to next year if
# already past. Returns $null when nothing parses. Uses TryParseExact (no exceptions in the loop)
# so a misparse can never silently abort the caller.
function Convert-ResetClockToDateTime {
    param([string]$DateText, [string]$TimeText)

    $inv  = [System.Globalization.CultureInfo]::InvariantCulture
    $none = [System.Globalization.DateTimeStyles]::None
    $now  = Get-Date
    # Normalize the clock: "7:21 PM" -> "7:21PM", "19:21" stays as-is.
    $time = ($TimeText.ToUpper() -replace '\s+', '')

    if ([string]::IsNullOrWhiteSpace($DateText)) {
        foreach ($fmt in @('h:mmtt', 'htt', 'HH:mm', 'H:mm')) {
            [datetime]$parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact($time, $fmt, $inv, $none, [ref]$parsed)) {
                $candidate = $now.Date.Add($parsed.TimeOfDay)
                if ($candidate -lt $now) { $candidate = $candidate.AddDays(1) }
                return $candidate
            }
        }
        return $null
    }

    # Strip abbreviation dots ("Jun." -> "Jun") and collapse runs of whitespace.
    $date    = (($DateText.Trim() -replace '\.', '') -replace '\s+', ' ')
    $hasYear = ($date -match '\d{4}')
    $value   = $date + ' ' + $time

    $formats = @(
        'yyyy-MM-dd h:mmtt', 'yyyy-MM-dd htt', 'yyyy-MM-dd HH:mm', 'yyyy-MM-dd H:mm',
        'MMM d h:mmtt', 'MMM d htt', 'MMM d HH:mm', 'MMM d H:mm',
        'MMMM d h:mmtt', 'MMMM d htt', 'MMMM d HH:mm', 'MMMM d H:mm'
    )
    foreach ($fmt in $formats) {
        [datetime]$parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($value, $fmt, $inv, $none, [ref]$parsed)) {
            $candidate = $parsed
            # ParseExact with no year token defaults to the current year; advance if already past.
            if (-not $hasYear -and $candidate -lt $now.AddMinutes(-5)) { $candidate = $candidate.AddYears(1) }
            return $candidate
        }
    }

    # Last resort: a free-form parse of the original "<date> <time>" text (handles ISO with 'T',
    # 4-digit-year forms, and month spellings the explicit formats above miss, e.g. "Sept").
    [datetime]$loose = [datetime]::MinValue
    if ([datetime]::TryParse(($date + ' ' + $TimeText.Trim()), $inv,
            [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$loose)) {
        $candidate = $loose
        if (-not $hasYear -and $candidate -lt $now.AddMinutes(-5)) { $candidate = $candidate.AddYears(1) }
        return $candidate
    }
    return $null
}

function Get-ResetTimeFromErrorText {
    param([string]$ErrorText)

    if ([string]::IsNullOrWhiteSpace($ErrorText)) { return $null }

    # "...try again at <when>" / "resets at <when>" / "available (again) at <when>". <when> is a
    # clock time, optionally preceded by a date: codex emits a bare clock ("7:21 PM"); other CLIs
    # sometimes add a date ("Jun 16, 7:21 PM", "2026-06-16 19:21", "2026-06-16T19:21"). Capture the
    # optional date and the clock separately, then combine and parse.
    $m = [regex]::Match($ErrorText,
        '(?i)(?:try again at|resets? at|available (?:again )?at)\s+' +
        '(?<date>(?:\d{4}-\d{2}-\d{2})|(?:[A-Za-z]{3,9}\.?\s+\d{1,2}))?' +
        '[ ,T]*' +
        '(?<time>\d{1,2}(?::\d{2})?\s*(?:am|pm)?)')
    if ($m.Success) {
        $reset = Convert-ResetClockToDateTime -DateText $m.Groups['date'].Value -TimeText $m.Groups['time'].Value
        if ($null -ne $reset) { return $reset }
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

function Get-RunnerResetTime {
    param([string]$Cli, [string]$ErrorText, [int]$LimitWaitMinutes)

    # $Cli is kept on the signature so future CLI-specific reset extractors can hook in here
    # without rippling every call site; today every CLI follows the same shape: try to parse a
    # reset timestamp out of the error text, otherwise wait the configured $LimitWaitMinutes.
    $null = $Cli
    $parsed = Get-ResetTimeFromErrorText -ErrorText $ErrorText
    if ($null -ne $parsed) { return $parsed }
    return (Get-Date).AddMinutes($LimitWaitMinutes)
}

function Select-NextRunner {
    param([object[]]$States, [int]$StartIndex, [datetime]$Now)
    $count = $States.Count
    for ($k = 0; $k -lt $count; $k++) {
        $i = ($StartIndex + $k) % $count
        $s = $States[$i]
        if ($s.SetAside) { continue }
        if ($null -ne $s.LimitedUntil -and $s.LimitedUntil -gt $Now) { continue }
        return @{ Action = 'Run'; Index = $i }
    }
    # Nothing runnable: consider live (not set aside) runners with a reset within 24h.
    $waitable = @()
    for ($i = 0; $i -lt $count; $i++) {
        $s = $States[$i]
        if (-not $s.SetAside -and $null -ne $s.LimitedUntil -and ($s.LimitedUntil - $Now).TotalHours -le 24) {
            $waitable += @{ Index = $i; At = $s.LimitedUntil }
        }
    }
    if ($waitable.Count -eq 0) { return @{ Action = 'Fail' } }
    $soonest = $waitable | Sort-Object { $_.At } | Select-Object -First 1
    return @{ Action = 'Wait'; Index = $soonest.Index; WaitUntil = $soonest.At }
}

function Wait-ForLimitReset {
    param($Task, $Result, $Settings)

    # Single code path for every CLI as of 1.2.x: parse a reset hint out of the limit error text,
    # otherwise wait the configured limitWaitMinutes. Previously claude went through a separate
    # `/usage` poll that no longer returns parseable data on subscription accounts.
    $resetTime = Get-ResetTimeFromErrorText -ErrorText $Result.ErrorText
    if ($null -eq $resetTime) {
        $resetTime = (Get-Date).AddMinutes($Settings.LimitWaitMinutes)
        Write-Host ("     no reset time in the error " + $script:GlyphDot + " waiting the configured " + $Settings.LimitWaitMinutes + " min") -ForegroundColor DarkGray
    }
    $wakeTime = $resetTime.AddMinutes($Settings.ResetBufferMinutes)
    # Always call the wrapper, even when the reset is "in 0s" (a real case some CLIs emit and
    # what stubs in the test suite produce). The wrapper prints the "Hit a usage limit" beat
    # regardless and skips the actual sleep when WakeTime is already in the past.
    Invoke-UiRestWithSummary -Cli ([string]$Task.Cli) -WakeTime $wakeTime
}

function Wait-ForRunnerReset {
    param([datetime]$Until, [string]$Cli, $Settings)
    $wakeTime = $Until.AddMinutes($Settings.ResetBufferMinutes)
    Invoke-UiRestWithSummary -Cli $Cli -WakeTime $wakeTime
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
        [switch]$Refresh,
        [switch]$ValidateOnly
    )
    $policy = $Config.Settings.ModelValidation
    $cacheHours = $Config.Settings.CapabilityCacheHours
    if ($policy -eq 'off') { return $true }

    $profile = $null
    if ($ValidateOnly) {
        $profilePath = Join-Path $PSScriptRoot "limitshift-profile.json"
        if (Test-Path $profilePath) {
            $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        }
    }

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
            $validated = $false
            if ($profile -ne $null -and $profile.clis.PSObject.Properties[$task.Cli] -ne $null) {
                $declaredModels = $profile.clis.($task.Cli).models
                foreach ($model in $task.Models) {
                    if ($declaredModels -notcontains $model) {
                         switch ($policy) {
                            'strictWhenDiscoverable' {
                                [Console]::Error.WriteLine("ERROR: Task ${n}: model `"$model`" is not available for $($task.Cli) in profile")
                                $hadError = $true
                            }
                            'warn' {
                                Write-Warning "Task ${n}: model `"$model`" not found in profile for $($task.Cli) (continuing)"
                            }
                        }
                        $validated = $true
                    }
                }
            }
            
            if (-not $validated) {
                Write-Host "  INFO: Task ${n}: model validation skipped for $($task.Cli) ($($caps.Error))" -ForegroundColor DarkGray
            }
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

if ($Demo) {
    Invoke-UiDemo
    exit 0
}

try {
    $config = Test-QueuePreflight -Path $QueuePath -RequireCliBinaries:($ValidateOnly -or -not $DryRun)
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

if ($ValidateOnly) {
    $capsDir = Join-Path $RunnerStatePath 'capabilities'
    $modelValidationPassed = Invoke-ModelValidation -Config $config -CapsDir $capsDir -Refresh:$RefreshCapabilities -ValidateOnly:$ValidateOnly
    if (-not $modelValidationPassed) { exit 2 }
    if ($ProbeModels -or $config.Settings.ProbeModels) { Invoke-ModelProbe -Config $config }
    Write-Host "Config OK: $QueuePath"
    Write-Host "Tasks: $($config.Tasks.Count)"
    foreach ($t in $config.Tasks) {
        Write-Host (" - [{0}] {1}  ({2})" -f $t.Cli, $t.Name, $t.ProjectPath)
    }
    exit 0
}

$transcriptStarted = $false
$exitCode = 0

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

try {
    Initialize-RunnerState  # migration + mkdir must happen before we write the lock
    $PID | Set-Content -LiteralPath $LockPath -Encoding UTF8 -NoNewline

    $Tasks = $config.Tasks
    $ResetBufferMinutes = $config.Settings.ResetBufferMinutes

    Start-Transcript -Path $LogPath -Append
    $transcriptStarted = $true
    $runStartTime = Get-Date
    Write-UiHeader

    $script:UiTaskTotal = $Tasks.Count
    Write-UiBannerDetails -TaskCount $Tasks.Count -Clis @($Tasks | ForEach-Object { $_.Cli }) -StartTime $runStartTime -QueuePath $QueuePath
    if ($ShowRawOutput) {
        Write-Host ("    state " + $script:GlyphDot + " " + $RunnerStatePath) -ForegroundColor DarkGray
        Write-Host ("    log   " + $script:GlyphDot + " " + $LogPath) -ForegroundColor DarkGray
    }

    # Per-run outcome counts, consulted by the final summary.
    #   $doneCount    - tasks that actually ran AND finished successfully this run
    #                   (simple-mode OK, or completion-marker Done).
    #   $skippedCount - tasks that did NOT run because they were already marked done
    #                   from a previous run (and their fingerprint still matches).
    #   $failedCount  - tasks that ran and failed but we kept going (stopOnError:false;
    #                   error retries exhausted, blocked, or stall).
    # Tasks that throw (stopOnError:true) skip the summary entirely.
    $doneCount = 0
    $skippedCount = 0
    $failedCount = 0
    $needsHumanCount = 0
    $stoppedEarly = $false
    $notReachedCount = 0

    for ($i = 0; $i -lt $Tasks.Count; $i++) {
        $task = $Tasks[$i]
        $taskNumber = $i + 1

        if (Test-StopRequested) {
            $stoppedEarly = $true
            # Count tasks that haven't been done yet (not reached).
            for ($j = $i; $j -lt $Tasks.Count; $j++) {
                if (-not (Test-TaskAlreadyDone -TaskIndex $j)) {
                    $notReachedCount++
                }
            }
            Write-Host ""
            Write-UiBeat -Glyph ([string]$script:GlyphMoon) -Message ("Stopping after the current step (you pressed s). " + $doneCount + " task(s) done this run; rerun the same command to continue.") -Color Yellow
            break
        }

        # Visual separator between tasks (not before the first one).
        if ($i -gt 0) { Write-UiSeparator }

        if (Test-TaskAlreadyDone -TaskIndex $i) {
            # Task 4: a done marker only counts when its stored fingerprint still matches the
            # current task. If the task's prompt/cli/projectPath/model/effort/extraArgs changed,
            # invalidate the marker (re-run) and drop the stale session id so it starts fresh.
            $savedFingerprint = Get-SavedDoneFingerprint -TaskIndex $i
            $currentFingerprint = Get-TaskFingerprint -Task $task
            if ($savedFingerprint -eq $currentFingerprint) {
                Write-Step "Skipping task $taskNumber of $($Tasks.Count): $($task.Name)"
                Write-Host "Task is already marked as done."
                $skippedCount++
                continue
            }
            Write-Step "Re-running task $taskNumber of $($Tasks.Count): $($task.Name)"
            Write-Host "Task $taskNumber changed since last run; previous done marker invalidated."
            Remove-Item -LiteralPath (Get-TaskDoneFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Get-TaskSessionFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Get-TaskRecoveryAttemptsFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
            # Task 6: also drop the stale model-rotation index so a changed task starts at model #1.
            Remove-Item -LiteralPath (Get-TaskModelIndexFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
            # Task 9.1: drop runner-index and per-runner model-indices (exist only for fallbacks tasks).
            Remove-Item -LiteralPath (Get-TaskRunnerIndexFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
            $reRunRunners = @($task.Runners)
            for ($r = 0; $r -lt $reRunRunners.Count; $r++) {
                Remove-Item -LiteralPath (Get-TaskRunnerModelIndexFilePath -TaskIndex $i -RunnerIndex $r) -Force -ErrorAction SilentlyContinue
            }
        }

        $runners = @($task.Runners)
        $runnerCount = $runners.Count

        if ($runnerCount -eq 1) {

        # --- NO-FALLBACKS PATH (single runner) ---
        $runCount = 0
        $errorRetryCount = 0
        $mustWaitForFreshSession = $false
        $stallCount = 0
        $previousNoMarkerText = $null
        $recoveryReason = $null
        $recoveryOutputTail = $null

        # Task 6: per-task model-rotation list and the persisted current index (kept across restarts).
        $models = @($task.Models)
        $modelCount = $models.Count
        $currentModelIndex = if ($modelCount -gt 1) { Get-SavedTaskModelIndex -TaskIndex $i } else { 0 }
        if ($currentModelIndex -ge $modelCount) { $currentModelIndex = 0 }

        while ($true) {
            $runCount++
            if ($runCount -gt $config.Settings.MaxRunsPerTask) {
                if ($task.RecoveryAttempts -gt 0 -and (Get-SavedTaskRecoveryAttempts -TaskIndex $i) -gt 0) {
                    $failReason = "run budget exhausted during block recovery (maxRunsPerTask=$($config.Settings.MaxRunsPerTask))"
                    Save-TaskFailedMarker -TaskIndex $i -Reason $failReason -Task $task
                    Save-TaskNeedsHumanMarker -TaskIndex $i -Reason $failReason
                    $needsHumanCount++
                    Write-Host ""
                    Write-UiBeat -Glyph ([string]$script:GlyphErr) -Message ("Task " + $taskNumber + " needs human review: " + $failReason) -Color Yellow
                    if ($config.Settings.StopOnError) { throw "Task $taskNumber $failReason" }
                    $failedCount++
                    break
                }
                throw "Task $taskNumber exceeded maxRunsPerTask=$($config.Settings.MaxRunsPerTask)"
            }

            if (Test-StopRequested) { break }

            # As of 1.2.x the runner no longer pre-checks `claude -p "/usage"` — Anthropic changed
            # the output format for subscription accounts and a separate credit pool for the Agent
            # SDK / `claude -p` is incoming. Limits are detected reactively from the CLI's response
            # via `$LimitPatterns` and rotated/waited on from there. $mustWaitForFreshSession is
            # kept on the state machine for symmetry but is now a no-op for cloud claude too.
            $null = $mustWaitForFreshSession

            # Task 6: the model used for THIS run is Models[currentModelIndex]. Empty when the task
            # set no model at all (then Get-CliArguments emits no -m/--model, exactly as before).
            $currentModel = if ($modelCount -gt 0) { [string]$models[$currentModelIndex] } else { '' }

            $savedSessionId = Get-SavedTaskSessionId -TaskIndex $i

            # Any iteration after the first is a WITHIN-RUN continuation (limit/rest, error retry,
            # no-marker resume). Suppress the task header on those: the contextual one-liner
            # printed by the prior iteration is the resume marker. First iteration always shows
            # the header (Mode=New gives the full header; Mode=Resume on $runCount==1 is a
            # fresh-start resume from a prior script run, which still benefits from a header).
            $quietHeader = ($runCount -gt 1)
            if ([string]::IsNullOrWhiteSpace($savedSessionId)) {
                $runMode = 'New'
                $sessionId = $null
                # claude is given a session id up front (passed as --session-id). agy/copilot need a
                # stable session id so the NEXT run can resume the same conversation.
                if ($task.Cli -eq 'claude' -or $task.Cli -eq 'agy' -or $task.Cli -eq 'copilot') { $sessionId = New-TaskSessionId -TaskIndex $i }
                $result = Invoke-CliTaskRun -TaskIndex $i -Task $task -Mode New -SessionId $sessionId -ModelOverride $currentModel -Quiet:$quietHeader -UseHandoffNote:([bool]$recoveryReason) -RecoveryReason $recoveryReason -RecoveryOutputTail $recoveryOutputTail
            }
            else {
                $runMode = 'Resume'
                $result = Invoke-CliTaskRun -TaskIndex $i -Task $task -Mode Resume -SessionId $savedSessionId -ModelOverride $currentModel -Quiet:$quietHeader -RecoveryReason $recoveryReason
            }

            $recoveryReason = $null
            $recoveryOutputTail = $null
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
            Add-RunsCsvRow -Task ("{0}-{1}" -f $taskNumber, $task.Name) -Run $runCount -Mode $runMode -Exit $(if ($result.Ok) { 0 } else { 1 }) -Status $runStatus -Cli $task.Cli -Model $currentModel

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

            # Claude-only: the saved session id is no longer in claude's local conversation store
            # ("No conversation found with session ID: ..."). State-file drift, not an agent failure.
            # Drop the session id, refund the run-budget tick, and let the next iteration start fresh.
            if ($task.Cli -eq 'claude' -and $result.SessionLost) {
                Remove-Item -LiteralPath (Get-TaskSessionFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
                Write-Step "Task $taskNumber`: claude's saved session id is no longer in claude's conversation store; starting a fresh session"
                if ($runCount -gt 0) { $runCount-- }
                continue
            }

            # Claude-only: `claude -p` rejected the prompt as a slash command (e.g. the prompt
            # begins with `/goal:` and claude parses it as `/goal`). Retrying cannot fix this
            # without editing the prompt, so flag for human and stop the task — never burn
            # recoveryAttempts or rotate to a fallback on a prompt-authoring mistake.
            if ($task.Cli -eq 'claude' -and $result.SlashRejected) {
                $blockReason = "claude -p rejected the prompt as a slash command (Unknown command in output). Edit the task prompt so it does not begin with a leading slash word; claude -p interprets that as a slash command, not as plain text."
                Save-TaskFailedMarker -TaskIndex $i -Reason $blockReason -Task $task
                Save-TaskNeedsHumanMarker -TaskIndex $i -Reason $blockReason
                $needsHumanCount++
                Write-Host ""
                Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " needs human review: " + $blockReason) -ForegroundColor Red
                if ($config.Settings.StopOnError) { throw "Task $taskNumber blocked: $blockReason" }
                $failedCount++
                break
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
                # Past-tense 'â˜¾ Hit a usage limit on <cli>, rested for X min' is printed by the
                # helper INSIDE Wait-ForLimitReset, after the rest countdown ends — no upfront beat.
                Wait-ForLimitReset -Task $task -Result $result -Settings $config.Settings
                continue
            }

            if (-not $result.Ok) {
                $errorRetryCount++
                Write-Host ""
                Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " hit an error:") -ForegroundColor Red
                Write-UiReason -Text $result.ErrorText
                if ($errorRetryCount -le $config.Settings.MaxRetriesOnError) {
                    Write-Host ""
                    Write-Host ("  " + $script:GlyphRetry + " retry " + $errorRetryCount + " of " + $config.Settings.MaxRetriesOnError + " for Task " + $taskNumber + "/" + $Tasks.Count + " " + $script:GlyphDot + " " + $task.Name + " " + $script:GlyphDot + " resume") -ForegroundColor Yellow
                    continue
                }
                if ($config.Settings.StopOnError) {
                    throw "Task $taskNumber failed after $($config.Settings.MaxRetriesOnError) retries: $($result.ErrorText)"
                }
                Write-Host ""
                Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " gave up after " + $config.Settings.MaxRetriesOnError + " retries " + $script:GlyphDot + " moving to the next task") -ForegroundColor Red
                $failedCount++
                break
            }

            # Simple mode (completionCheck:false): the first OK run (no limit, no error) is done.
            # No marker parsing, no stall guard.
            if (-not $task.CompletionCheck) {
                Save-TaskDoneMarker -TaskIndex $i -Task $task
                Write-UiTaskDone -TaskNumber $taskNumber
                $doneCount++
                break
            }

            $marker = Get-MarkerStatus -Text $result.Text
            if ($marker.Status -eq 'Done') {
                Save-TaskDoneMarker -TaskIndex $i -Task $task
                Write-UiTaskDone -TaskNumber $taskNumber
                $doneCount++
                break
            }
            if ($marker.Status -eq 'Blocked') {
                # HUMAN: short-circuit (spec 7.2).
                if ($marker.Reason -match '^HUMAN:') {
                    Save-TaskFailedMarker -TaskIndex $i -Reason $marker.Reason -Task $task
                    Save-TaskNeedsHumanMarker -TaskIndex $i -Reason $marker.Reason
                    $needsHumanCount++
                    Write-Host ""
                    Write-UiBeat -Glyph ([string]$script:GlyphErr) -Message ("Task " + $taskNumber + " needs human review: " + $marker.Reason) -Color Yellow
                    Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " is blocked (HUMAN: short-circuit):") -ForegroundColor Yellow
                    Write-UiReason -Text $marker.Reason
                    if ($config.Settings.StopOnError) { throw "Task $taskNumber is blocked: $($marker.Reason)" }
                    $failedCount++
                    break
                }

                # Recovery rounds (spec 7.1).
                $currentRecoveryAttempts = Get-SavedTaskRecoveryAttempts -TaskIndex $i
                if ($task.RecoveryAttempts -gt 0 -and $currentRecoveryAttempts -lt $task.RecoveryAttempts) {
                    $currentRecoveryAttempts++
                    Save-TaskRecoveryAttempts -TaskIndex $i -Attempts $currentRecoveryAttempts
                    $errorRetryCount = 0; $stallCount = 0; $previousNoMarkerText = $null
                    $mustWaitForFreshSession = $false

                    Write-Host ""
                    Write-UiBeat -Glyph ([string]$script:GlyphRetry) -Message ("Task " + $taskNumber + " blocked; recovery round " + $currentRecoveryAttempts + " of " + $task.RecoveryAttempts + "...") -Color Yellow
                    Write-UiReason -Text $marker.Reason

                    # Same-session recovery uses Variant A in the resume prompt.
                    $recoveryReason = $marker.Reason
                    continue
                }

                # Recovery exhausted or off.
                Save-TaskFailedMarker -TaskIndex $i -Reason $marker.Reason -Task $task
                if ($task.RecoveryAttempts -gt 0) {
                    Save-TaskNeedsHumanMarker -TaskIndex $i -Reason $marker.Reason
                    $needsHumanCount++
                    Write-Host ""
                    Write-UiBeat -Glyph ([string]$script:GlyphErr) -Message ("Task " + $taskNumber + " needs human review: " + $marker.Reason) -Color Yellow
                }
                Write-Host ""
                Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " is blocked:") -ForegroundColor Yellow
                Write-UiReason -Text $marker.Reason
                if ($config.Settings.StopOnError) {
                    throw "Task $taskNumber is blocked: $($marker.Reason)"
                }
                $failedCount++
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
                    Write-Host ""
                    Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " failed:") -ForegroundColor Red
                    Write-UiReason -Text $stallReason
                    if ($config.Settings.StopOnError) {
                        throw "Task $taskNumber failed: $stallReason"
                    }
                    $failedCount++
                    break
                }
            }
            $previousNoMarkerText = $currentText

            # Ran fine, no marker: the agent stopped early. Resume to push it onward.
            $mustWaitForFreshSession = $false
            Write-Host ""
            Write-Host ("  " + $script:GlyphRetry + " Task " + $taskNumber + "/" + $Tasks.Count + " " + $script:GlyphDot + " " + $task.Name + " not finished yet " + $script:GlyphDot + " resuming the same session") -ForegroundColor DarkGray
        }

        } else {

        # --- FALLBACKS PATH (multiple runners) ---
        $setAside          = New-Object 'bool[]'   $runnerCount
        $limitedUntil      = New-Object 'object[]' $runnerCount
        $runnerModelIndices = New-Object 'int[]'   $runnerCount
        $runnerReasons     = New-Object 'string[]' $runnerCount
        # Task 9.1: restore the persisted runner index and per-runner model indices across restarts.
        $currentRunnerIndex = Get-SavedTaskRunnerIndex -TaskIndex $i
        if ($currentRunnerIndex -ge $runnerCount) { $currentRunnerIndex = 0 }
        for ($r = 0; $r -lt $runnerCount; $r++) {
            $runnerModelIndices[$r] = Get-SavedTaskRunnerModelIndex -TaskIndex $i -RunnerIndex $r
        }
        $pendingHandoff    = $false
        $runCount          = 0
        $errorRetryCount   = 0
        $stallCount        = 0
        $previousNoMarkerText = $null
        $mustWaitForFreshSession = $false
        $recoveryReason    = $null
        $recoveryOutputTail = $null
        $pendingHandoffReason = $null
        $pendingHandoffOutputTail = $null

        while ($true) {
            # Runner selection
            $states = @(for ($j = 0; $j -lt $runnerCount; $j++) {
                @{ SetAside = $setAside[$j]; LimitedUntil = $limitedUntil[$j] }
            })
            $sel = Select-NextRunner -States $states -StartIndex $currentRunnerIndex -Now (Get-Date)

            if ($sel.Action -eq 'Fail') {
                $parts = @(for ($j = 0; $j -lt $runnerCount; $j++) {
                    if ($runnerReasons[$j]) { "$($runners[$j].Cli): $($runnerReasons[$j])" }
                })
                $failReason = "all runners exhausted" + $(if ($parts.Count -gt 0) { ": " + ($parts -join '; ') } else { '' })
                Save-TaskFailedMarker -TaskIndex $i -Reason $failReason -Task $task
                Write-Host ""
                Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " failed (all runners exhausted):") -ForegroundColor Red
                Write-UiReason -Text $failReason
                if ($config.Settings.StopOnError) { throw "Task $taskNumber $failReason" }
                $failedCount++
                break
            }

            if ($sel.Action -eq 'Wait') {
                $waitRunnerIdx = $sel.Index
                Wait-ForRunnerReset -Until $sel.WaitUntil -Cli ([string]$runners[$waitRunnerIdx].Cli) -Settings $config.Settings
                $limitedUntil[$waitRunnerIdx] = $null
                # Do NOT advance $currentRunnerIndex here: the cleared runner is now the only
                # runnable one, so the next Select-NextRunner returns it, and the Run branch's
                # switch detection treats resuming into a runner different from the one that last
                # ran as a runner change (fresh session + handoff note + counter reset, spec 6.1/7).
                continue
            }

            # Action = 'Run'
            $newRunnerIdx = $sel.Index
            if ($newRunnerIdx -ne $currentRunnerIndex) {
                if ($task.RecoveryAttempts -gt 0) {
                    $pendingHandoffReason = $runnerReasons[$currentRunnerIndex]
                    $pendingHandoffOutputTail = Get-TaskOutputTail -FilePath (Get-TaskOutputFilePath -TaskIndex $i -Task $task)
                }
                else {
                    $pendingHandoffReason = $null
                    $pendingHandoffOutputTail = $null
                }
                Remove-Item -LiteralPath (Get-TaskSessionFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
                $errorRetryCount = 0; $stallCount = 0
                $previousNoMarkerText = $null; $mustWaitForFreshSession = $false
                # Block recovery is runner-specific; discard same-session recovery context if we rotate.
                $recoveryReason = $null; $recoveryOutputTail = $null
                Write-Step "Task ${taskNumber}: switching to $($runners[$newRunnerIdx].Cli)"
                $currentRunnerIndex = $newRunnerIdx
                # Task 9.1: persist the new runner index so a restart resumes the correct runner.
                Save-TaskRunnerIndex -TaskIndex $i -RunnerIndex $currentRunnerIndex
                $pendingHandoff = $true
            }

            $activeRunner = $runners[$currentRunnerIndex]
            $runnerModels = @($activeRunner.Models)
            $runnerModelCount = $runnerModels.Count
            $currentModelIndexForRunner = $runnerModelIndices[$currentRunnerIndex]
            if ($currentModelIndexForRunner -ge $runnerModelCount) { $currentModelIndexForRunner = 0 }
            $currentModel = if ($runnerModelCount -gt 0) { [string]$runnerModels[$currentModelIndexForRunner] } else { '' }

            $effectiveTask = [pscustomobject]@{
                Name             = $task.Name
                Cli              = $activeRunner.Cli
                ProjectPath      = $task.ProjectPath
                Model            = if ($runnerModels.Count -gt 0) { [string]$runnerModels[0] } else { '' }
                Models           = $runnerModels
                Effort           = $activeRunner.Effort
                Prompt           = $task.Prompt
                ExtraArgs        = @($activeRunner.ExtraArgs)
                CompletionCheck  = $task.CompletionCheck
                RecoveryAttempts = $task.RecoveryAttempts
            }

            # The cloud-claude `/usage` pre-check was removed in 1.2.x — see top-of-file note.
            # Rotation on cap now happens reactively from the limit signal in the CLI's response.
            $mustWaitForFreshSession = $false

            $runCount++
            if ($runCount -gt $config.Settings.MaxRunsPerTask) {
                $failReason = "run budget exhausted (maxRunsPerTask=$($config.Settings.MaxRunsPerTask))"
                Save-TaskFailedMarker -TaskIndex $i -Reason $failReason -Task $task
                if ($task.RecoveryAttempts -gt 0 -and (Get-SavedTaskRecoveryAttempts -TaskIndex $i) -gt 0) {
                    Save-TaskNeedsHumanMarker -TaskIndex $i -Reason $failReason
                    $needsHumanCount++
                }
                Write-Host ""
                Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " exceeded run budget") -ForegroundColor Red
                if ($config.Settings.StopOnError) { throw "Task $taskNumber $failReason" }
                $failedCount++
                break
            }

            if (Test-StopRequested) { break }

            $quietHeader = ($runCount -gt 1)
            $savedSessionId = Get-SavedTaskSessionId -TaskIndex $i

            if ([string]::IsNullOrWhiteSpace($savedSessionId)) {
                $runMode = 'New'
                $sessionId = $null
                if ($effectiveTask.Cli -eq 'claude' -or $effectiveTask.Cli -eq 'agy' -or $effectiveTask.Cli -eq 'copilot') {
                    $sessionId = New-TaskSessionId -TaskIndex $i
                }
                $useHandoff = $pendingHandoff; $pendingHandoff = $false
                $result = Invoke-CliTaskRun -TaskIndex $i -Task $effectiveTask -Mode New -SessionId $sessionId -ModelOverride $currentModel -Quiet:$quietHeader -UseHandoffNote:$useHandoff -RecoveryReason $pendingHandoffReason -RecoveryOutputTail $pendingHandoffOutputTail
                $pendingHandoffReason = $null
                $pendingHandoffOutputTail = $null
            } else {
                $runMode = 'Resume'
                $result = Invoke-CliTaskRun -TaskIndex $i -Task $effectiveTask -Mode Resume -SessionId $savedSessionId -ModelOverride $currentModel -Quiet:$quietHeader -RecoveryReason $recoveryReason
            }

            $recoveryReason = $null
            $recoveryOutputTail = $null
            if ($DryRun) { Write-Step "Dry run for task $taskNumber recorded the command only"; break }

            if ($result.IsLimit) {
                $runStatus = 'Limit'
            } elseif (-not $result.Ok) {
                $runStatus = 'Error'
            } elseif (-not $task.CompletionCheck) {
                $runStatus = 'Done'
            } else {
                $runMarker = Get-MarkerStatus -Text $result.Text
                if ($runMarker.Status -eq 'Done')    { $runStatus = 'Done' }
                elseif ($runMarker.Status -eq 'Blocked') { $runStatus = 'Blocked' }
                else                                      { $runStatus = 'NoMarker' }
            }
            Add-RunsCsvRow -Task ("{0}-{1}" -f $taskNumber, $task.Name) -Run $runCount -Mode $runMode -Exit $(if ($result.Ok) { 0 } else { 1 }) -Status $runStatus -Cli $activeRunner.Cli -Model $currentModel

            if (-not [string]::IsNullOrWhiteSpace($result.SessionId)) {
                $result.SessionId | Set-Content -LiteralPath (Get-TaskSessionFilePath -TaskIndex $i) -Encoding UTF8
            }

            # Gemini-only: installed CLI rejected --resume — drop session and retry without it
            if ($effectiveTask.Cli -eq 'gemini' -and -not $result.Ok -and
                $result.ErrorText -match '(?i)unknown option.*resume|not supported in non-interactive|unexpected argument|too many arguments|invalid.*resume') {
                Remove-Item -LiteralPath (Get-TaskSessionFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
                Write-Step "Task ${taskNumber}: installed gemini rejects --resume; retrying with continuation prompt only"
                continue
            }

            # Claude-only: state-file drift — the saved session id is no longer in claude's local
            # conversation store. Drop the id, refund the run-budget tick, retry on the same runner
            # as Mode=New. Never rotate to a fallback for this — it's not a CLI failure.
            if ($activeRunner.Cli -eq 'claude' -and $result.SessionLost) {
                Remove-Item -LiteralPath (Get-TaskSessionFilePath -TaskIndex $i) -Force -ErrorAction SilentlyContinue
                Write-Step "Task ${taskNumber}: claude's saved session id is no longer in claude's conversation store; starting a fresh session"
                if ($runCount -gt 0) { $runCount-- }
                continue
            }

            # Claude-only: `claude -p` rejected the prompt as a slash command. Flag for human;
            # never rotate to a fallback (the same prompt would just fail the same way on the next
            # tool too if anything peeked at the leading `/`).
            if ($activeRunner.Cli -eq 'claude' -and $result.SlashRejected) {
                $blockReason = "claude -p rejected the prompt as a slash command (Unknown command in output). Edit the task prompt so it does not begin with a leading slash word; claude -p interprets that as a slash command, not as plain text."
                Save-TaskFailedMarker -TaskIndex $i -Reason $blockReason -Task $task
                Save-TaskNeedsHumanMarker -TaskIndex $i -Reason $blockReason
                $needsHumanCount++
                Write-Host ""
                Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " needs human review: " + $blockReason) -ForegroundColor Red
                if ($config.Settings.StopOnError) { throw "Task $taskNumber blocked: $blockReason" }
                $failedCount++
                break
            }

            if ($result.IsLimit) {
                if ($runnerModelCount -gt 1 -and $currentModelIndexForRunner -lt ($runnerModelCount - 1)) {
                    $nextModelIdx = $currentModelIndexForRunner + 1
                    Write-Step "Task ${taskNumber}: limit on $($runnerModels[$currentModelIndexForRunner]); switching to $($runnerModels[$nextModelIdx])"
                    $runnerModelIndices[$currentRunnerIndex] = $nextModelIdx
                    # Task 9.1: persist the per-runner model index so a restart resumes at the right model.
                    Save-TaskRunnerModelIndex -TaskIndex $i -RunnerIndex $currentRunnerIndex -ModelIndex $nextModelIdx
                    continue
                }
                if ($runnerModelCount -gt 1) {
                    $runnerModelIndices[$currentRunnerIndex] = 0
                    Save-TaskRunnerModelIndex -TaskIndex $i -RunnerIndex $currentRunnerIndex -ModelIndex 0
                }
                $limitedUntil[$currentRunnerIndex] = Get-RunnerResetTime -Cli ([string]$activeRunner.Cli) -ErrorText $result.ErrorText -LimitWaitMinutes $config.Settings.LimitWaitMinutes
                $runnerReasons[$currentRunnerIndex] = 'limited'
                continue
            }

            if (-not $result.Ok) {
                $errorRetryCount++
                Write-Host ""
                Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " hit an error:") -ForegroundColor Red
                Write-UiReason -Text $result.ErrorText
                if ($errorRetryCount -le $config.Settings.MaxRetriesOnError) {
                    Write-Host ""
                    Write-Host ("  " + $script:GlyphRetry + " retry " + $errorRetryCount + " of " + $config.Settings.MaxRetriesOnError + " for Task " + $taskNumber + "/" + $Tasks.Count + " " + $script:GlyphDot + " " + $task.Name + " " + $script:GlyphDot + " resume") -ForegroundColor Yellow
                    continue
                }
                $setAside[$currentRunnerIndex] = $true
                $runnerReasons[$currentRunnerIndex] = "error: $($result.ErrorText)"
                $errorRetryCount = 0
                continue
            }

            if (-not $task.CompletionCheck) {
                Save-TaskDoneMarker -TaskIndex $i -Task $task
                Write-UiTaskDone -TaskNumber $taskNumber
                $doneCount++
                break
            }

            $marker = Get-MarkerStatus -Text $result.Text
            if ($marker.Status -eq 'Done') {
                Save-TaskDoneMarker -TaskIndex $i -Task $task
                Write-UiTaskDone -TaskNumber $taskNumber
                $doneCount++
                break
            }
            if ($marker.Status -eq 'Blocked') {
                # HUMAN: short-circuit (spec 7.2).
                if ($marker.Reason -match '^HUMAN:') {
                    Save-TaskFailedMarker -TaskIndex $i -Reason $marker.Reason -Task $task
                    Save-TaskNeedsHumanMarker -TaskIndex $i -Reason $marker.Reason
                    $needsHumanCount++
                    Write-Host ""
                    Write-UiBeat -Glyph ([string]$script:GlyphErr) -Message ("Task " + $taskNumber + " needs human review: " + $marker.Reason) -Color Yellow
                    Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " is blocked (HUMAN: short-circuit):") -ForegroundColor Yellow
                    Write-UiReason -Text $marker.Reason
                    if ($config.Settings.StopOnError) { throw "Task $taskNumber is blocked: $($marker.Reason)" }
                    $failedCount++
                    break
                }

                # Recovery rounds (spec 7.1).
                $currentRecoveryAttempts = Get-SavedTaskRecoveryAttempts -TaskIndex $i
                if ($task.RecoveryAttempts -gt 0 -and $currentRecoveryAttempts -lt $task.RecoveryAttempts) {
                    $currentRecoveryAttempts++
                    Save-TaskRecoveryAttempts -TaskIndex $i -Attempts $currentRecoveryAttempts
                    $errorRetryCount = 0; $stallCount = 0; $previousNoMarkerText = $null
                    $mustWaitForFreshSession = $false

                    Write-Host ""
                    Write-UiBeat -Glyph ([string]$script:GlyphRetry) -Message ("Task " + $taskNumber + " blocked; recovery round " + $currentRecoveryAttempts + " of " + $task.RecoveryAttempts + "...") -Color Yellow
                    Write-UiReason -Text $marker.Reason

                    # Same-session recovery uses Variant A in the resume prompt.
                    $recoveryReason = $marker.Reason
                    continue
                }

                # Recovery exhausted or off.
                Save-TaskFailedMarker -TaskIndex $i -Reason $marker.Reason -Task $task
                if ($task.RecoveryAttempts -gt 0) {
                    Save-TaskNeedsHumanMarker -TaskIndex $i -Reason $marker.Reason
                    $needsHumanCount++
                    Write-Host ""
                    Write-UiBeat -Glyph ([string]$script:GlyphErr) -Message ("Task " + $taskNumber + " needs human review: " + $marker.Reason) -Color Yellow
                    Write-Host ""
                    Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " is blocked:") -ForegroundColor Yellow
                    Write-UiReason -Text $marker.Reason
                    if ($config.Settings.StopOnError) { throw "Task $taskNumber is blocked: $($marker.Reason)" }
                    $failedCount++
                    break
                }

                # If no recovery enabled, blocked is handled by rotation (spec 8).
                # Wait, spec says: "a [[TASK_BLOCKED]] from an AI tool WITHOUT recoveryAttempts > 0... stops execution of that task immediately.
                # Do NOT rotate to the next fallback."
                # My previous logic for fallbacks (L3352) already broke the loop on Blocked.
                Save-TaskFailedMarker -TaskIndex $i -Reason $marker.Reason -Task $task
                Write-Host ""
                Write-Host ("  " + $script:GlyphErr + " Task " + $taskNumber + " is blocked:") -ForegroundColor Yellow
                Write-UiReason -Text $marker.Reason
                if ($config.Settings.StopOnError) { throw "Task $taskNumber is blocked: $($marker.Reason)" }
                $failedCount++
                break
            }

            # Stall: with fallbacks, set runner aside and try the next one
            $currentText = if ($null -ne $result.Text) { ([string]$result.Text).Trim() } else { '' }
            if ($null -ne $previousNoMarkerText -and $currentText -eq $previousNoMarkerText) {
                $stallCount++
                if ($stallCount -ge $config.Settings.MaxStalls) {
                    $stallReason = 'no progress: agent repeated the same response without a completion marker'
                    $setAside[$currentRunnerIndex] = $true
                    $runnerReasons[$currentRunnerIndex] = $stallReason
                    $stallCount = 0; $previousNoMarkerText = $null
                    continue
                }
            }
            $previousNoMarkerText = $currentText

            Write-Host ""
            Write-Host ("  " + $script:GlyphRetry + " Task " + $taskNumber + "/" + $Tasks.Count + " " + $script:GlyphDot + " " + $task.Name + " not finished yet " + $script:GlyphDot + " resuming the same session") -ForegroundColor DarkGray
        }

        } # end else (fallbacks path)
    }

    Write-UiSummary -TaskCount $Tasks.Count -DoneCount $doneCount -SkippedCount $skippedCount -FailedCount $failedCount `
        -NeedsHumanCount $needsHumanCount `
        -AllCompletionCheck (-not ($Tasks | Where-Object { -not $_.CompletionCheck })) `
        -LogPath $LogPath -StatePath $RunnerStatePath -DryRun:$DryRun `
        -StoppedEarly:$stoppedEarly -NotReachedCount:$notReachedCount
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $exitCode = 1
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript
    }
    Write-UiSessionTotalTime
    Remove-Item -LiteralPath $LockPath -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StopFlagPath -Force -ErrorAction SilentlyContinue
    Clear-EphemeralFooter
}

exit $exitCode
