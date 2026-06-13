Describe 'run-ai.ps1' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path $repoRoot 'run-ai.ps1'
        $configFixtures = Join-Path $PSScriptRoot 'fixtures\configs'
        $outputFixtures = Join-Path $PSScriptRoot 'fixtures\outputs'
        $powershellExe = (Get-Command powershell.exe).Source
        $tempRoots = @()

        . $scriptPath -LoadFunctionsOnly

        function New-TestRoot {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("limitshift-tests-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $script:__limitshiftTempRoots += $root
            return $root
        }

        function Write-TestQueue {
            param(
                [string]$Path,
                [hashtable]$Config
            )

            $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
        }

        function Invoke-RunnerProcess {
            param([string[]]$Arguments)

            $captureRoot = New-TestRoot
            $stdoutPath = Join-Path $captureRoot 'stdout.txt'
            $stderrPath = Join-Path $captureRoot 'stderr.txt'
            $process = Start-Process -FilePath $powershellExe `
                -ArgumentList $Arguments `
                -Wait `
                -PassThru `
                -NoNewWindow `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath

            $combined = @()
            if (Test-Path -LiteralPath $stdoutPath) {
                $combined += Get-Content -LiteralPath $stdoutPath
            }
            if (Test-Path -LiteralPath $stderrPath) {
                $combined += Get-Content -LiteralPath $stderrPath
            }

            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output   = ($combined -join [Environment]::NewLine)
            }
        }

        $script:__limitshiftScriptPath = $scriptPath
        $script:__limitshiftConfigFixtures = $configFixtures
        $script:__limitshiftOutputFixtures = $outputFixtures
        $script:__limitshiftPowerShellExe = $powershellExe
        $script:__limitshiftTempRoots = $tempRoots
    }

    AfterAll {
        foreach ($root in $script:__limitshiftTempRoots) {
            if (Test-Path -LiteralPath $root) {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }

    Context 'Read-QueueConfig' {
        It 'loads a minimal valid config' {
            $cfg = Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'valid-minimal.json')
            $cfg.Tasks.Count | Should -Be 1
            $cfg.Tasks[0].Cli | Should -Be 'claude'
        }

        It 'applies default settings when settings block is absent' {
            $cfg = Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'valid-minimal.json')
            $cfg.Settings.MaxRunsPerTask | Should -Be 20
            $cfg.Settings.LimitWaitMinutes | Should -Be 30
        }

        It 'loads fully-populated settings and optional task fields' {
            $cfg = Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'valid-full.json')
            $cfg.Settings.MaxRunsPerTask | Should -Be 7
            $cfg.Settings.MaxRetriesOnError | Should -Be 4
            $cfg.Tasks[1].Model | Should -Be 'gpt-5.4'
            $cfg.Tasks[1].Effort | Should -Be 'high'
            $cfg.Tasks[2].ExtraArgs | Should -Contain '--approval-mode'
            $cfg.Tasks[2].ExtraArgs | Should -Contain 'yolo'
        }

        It 'rejects malformed JSON with a friendly message' {
            {
                Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'broken-trailing-comma.json')
            } | Should -Throw '*not valid JSON*'
        }

        It 'rejects a task with a missing required field, naming the field and task number' {
            {
                Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'broken-missing-field.json')
            } | Should -Throw '*Task 1*prompt*'
        }

        It 'rejects an unknown cli value, listing the allowed values' {
            {
                Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'broken-bad-cli.json')
            } | Should -Throw '*claude, codex, gemini*'
        }

        It 'rejects a non-existent projectPath, printing the path' {
            {
                Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'broken-missing-path.json')
            } | Should -Throw '*does not exist*'
        }

        It 'normalizes extraArgs given as a string into an array of strings' {
            $cfg = Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'valid-full.json')
            @($cfg.Tasks[2].ExtraArgs) | Should -HaveCount 2
            $cfg.Tasks[2].ExtraArgs | Should -Contain '--approval-mode'
            $cfg.Tasks[2].ExtraArgs | Should -Contain 'yolo'
        }
    }

    Context 'completionCheck flag (Read-QueueConfig)' {
        It 'defaults completionCheck to true when absent globally and per-task' {
            $cfg = Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'valid-minimal.json')
            $cfg.Settings.CompletionCheck | Should -Be $true
            $cfg.Tasks[0].CompletionCheck | Should -Be $true
        }

        It 'defaults maxStalls to 2 when absent' {
            $cfg = Read-QueueConfig -Path (Join-Path $script:__limitshiftConfigFixtures 'valid-minimal.json')
            $cfg.Settings.MaxStalls | Should -Be 2
        }

        It 'honors a global completionCheck:false setting' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
            $queuePath = Join-Path $root 'queue.json'
            Write-TestQueue -Path $queuePath -Config @{
                settings = @{ completionCheck = $false }
                tasks = @(
                    @{ name = 'a'; cli = 'claude'; projectPath = $projectPath; prompt = 'p' }
                )
            }
            $cfg = Read-QueueConfig -Path $queuePath
            $cfg.Settings.CompletionCheck | Should -Be $false
            $cfg.Tasks[0].CompletionCheck | Should -Be $false
        }

        It 'lets a per-task completionCheck override beat the global setting' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
            $queuePath = Join-Path $root 'queue.json'
            Write-TestQueue -Path $queuePath -Config @{
                settings = @{ completionCheck = $true }
                tasks = @(
                    @{ name = 'a'; cli = 'claude'; projectPath = $projectPath; prompt = 'p'; completionCheck = $false }
                    @{ name = 'b'; cli = 'claude'; projectPath = $projectPath; prompt = 'q' }
                )
            }
            $cfg = Read-QueueConfig -Path $queuePath
            $cfg.Tasks[0].CompletionCheck | Should -Be $false
            $cfg.Tasks[1].CompletionCheck | Should -Be $true
        }

        It 'lets a per-task completionCheck:true override a global false' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
            $queuePath = Join-Path $root 'queue.json'
            Write-TestQueue -Path $queuePath -Config @{
                settings = @{ completionCheck = $false }
                tasks = @(
                    @{ name = 'a'; cli = 'claude'; projectPath = $projectPath; prompt = 'p'; completionCheck = $true }
                )
            }
            $cfg = Read-QueueConfig -Path $queuePath
            $cfg.Tasks[0].CompletionCheck | Should -Be $true
        }
    }

    Context 'Get-TaskPromptWithCompletionMarker / Get-ResumePrompt completionCheck bypass' {
        It 'appends the marker block when completionCheck is true' {
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'claude'; ProjectPath = 'C:\proj'
                Model = $null; Effort = $null; Prompt = 'do the thing'; ExtraArgs = @()
                CompletionCheck = $true
            }
            $prompt = Get-TaskPromptWithCompletionMarker -Task $task
            $prompt | Should -Match 'IMPORTANT AUTOMATION INSTRUCTIONS'
            $prompt | Should -Match '\[\[TASK_COMPLETE\]\]'
        }

        It 'sends the prompt byte-identical (verbatim) when completionCheck is false' {
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'claude'; ProjectPath = 'C:\proj'
                Model = $null; Effort = $null; Prompt = "do the thing`nsecond line"; ExtraArgs = @()
                CompletionCheck = $false
            }
            $prompt = Get-TaskPromptWithCompletionMarker -Task $task
            $prompt | Should -BeExactly "do the thing`nsecond line"
            $prompt | Should -Not -Match 'IMPORTANT AUTOMATION INSTRUCTIONS'
        }

        It 'omits the marker block from the resume prompt when completionCheck is false' {
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'claude'; ProjectPath = 'C:\proj'
                Model = $null; Effort = $null; Prompt = 'do the thing'; ExtraArgs = @()
                CompletionCheck = $false
            }
            $prompt = Get-ResumePrompt -Task $task
            $prompt | Should -Not -Match 'IMPORTANT AUTOMATION INSTRUCTIONS'
            $prompt | Should -Not -Match '\[\[TASK_COMPLETE\]\]'
        }

        It 'keeps the marker block in the resume prompt when completionCheck is true' {
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'claude'; ProjectPath = 'C:\proj'
                Model = $null; Effort = $null; Prompt = 'do the thing'; ExtraArgs = @()
                CompletionCheck = $true
            }
            $prompt = Get-ResumePrompt -Task $task
            $prompt | Should -Match 'IMPORTANT AUTOMATION INSTRUCTIONS'
        }

        # Task 3 (Bug C): the resume prompt must repeat the original task verbatim so a thin
        # session and slash commands (e.g. /goal) survive the resume.
        It 'repeats the original prompt (incl. a /goal line) and the continue sentence on resume for cli=<Cli> (completionCheck true)' -ForEach @(
            @{ Cli = 'claude' }
            @{ Cli = 'codex' }
            @{ Cli = 'gemini' }
        ) {
            $originalPrompt = "/goal ship the widget`nImplement the feature end to end."
            $task = [pscustomobject]@{
                Name = 't'; Cli = $Cli; ProjectPath = 'C:\proj'
                Model = $null; Effort = $null; Prompt = $originalPrompt; ExtraArgs = @()
                CompletionCheck = $true
            }
            $prompt = Get-ResumePrompt -Task $task
            # (a) original prompt verbatim, including the /goal line
            $prompt | Should -Match '/goal ship the widget'
            $prompt | Should -BeLike "*$originalPrompt*"
            # (b) the continue sentence
            $prompt | Should -Match 'Continue the previous task in this same session from where you stopped\. Do not restart from scratch\.'
            # (c) the marker instructions block (completionCheck true)
            $prompt | Should -Match 'IMPORTANT AUTOMATION INSTRUCTIONS'
        }

        It 'simple-mode resume repeats the original prompt but omits the marker block (completionCheck false)' {
            $originalPrompt = "/goal ship the widget`nImplement the feature end to end."
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'claude'; ProjectPath = 'C:\proj'
                Model = $null; Effort = $null; Prompt = $originalPrompt; ExtraArgs = @()
                CompletionCheck = $false
            }
            $prompt = Get-ResumePrompt -Task $task
            # The original prompt IS present...
            $prompt | Should -BeLike "*$originalPrompt*"
            $prompt | Should -Match 'Continue the previous task in this same session from where you stopped\. Do not restart from scratch\.'
            # ...but no marker text leaks in simple mode.
            $prompt | Should -Not -Match 'IMPORTANT AUTOMATION INSTRUCTIONS'
            $prompt | Should -Not -Match '\[\[TASK_COMPLETE\]\]'
        }
    }

    Context 'Get-MarkerStatus (loosened detection)' {
        It 'returns Done for an exact last line marker' {
            (Get-MarkerStatus -Text "work`n[[TASK_COMPLETE]]").Status | Should -Be 'Done'
        }

        It 'returns Done when the last line is OK[[TASK_COMPLETE]]' {
            (Get-MarkerStatus -Text "OK[[TASK_COMPLETE]]").Status | Should -Be 'Done'
        }

        It 'returns Done when the marker has trailing whitespace' {
            (Get-MarkerStatus -Text "all done`n[[TASK_COMPLETE]]   ").Status | Should -Be 'Done'
        }

        It 'returns Done when the marker is on the last non-empty line with text before it' {
            (Get-MarkerStatus -Text "Finished the task. [[TASK_COMPLETE]]`n`n").Status | Should -Be 'Done'
        }

        It 'returns Blocked with reason for a leading blocked marker' {
            $m = Get-MarkerStatus -Text "[[TASK_BLOCKED]] reason here"
            $m.Status | Should -Be 'Blocked'
            $m.Reason | Should -Be 'reason here'
        }

        It 'returns Blocked with reason when text precedes the blocked marker' {
            $m = Get-MarkerStatus -Text "Sorry --- [[TASK_BLOCKED]] no API key"
            $m.Status | Should -Be 'Blocked'
            $m.Reason | Should -Be 'no API key'
        }

        It 'returns None when the marker only appears mid-response, not on the last non-empty line' {
            $text = "Here is the plan: [[TASK_COMPLETE]] is what I will print.`nStill working on step 2."
            (Get-MarkerStatus -Text $text).Status | Should -Be 'None'
        }
    }

    Context 'Get-ConsoleOutputText (clean console output)' {
        It 'prints the parsed response text for a successful run' {
            $result = New-CliResult -Ok $true -IsLimit $false -Text 'pong [[TASK_COMPLETE]]' -SessionId 's' -ErrorText $null
            $text = Get-ConsoleOutputText -Result $result -RawOutput '{"result":"pong [[TASK_COMPLETE]]","session_id":"s"}'
            $text | Should -Be 'pong [[TASK_COMPLETE]]'
            $text | Should -Not -Match '"result"'
        }

        It 'prints the error text when the run failed' {
            $result = New-CliResult -Ok $false -IsLimit $false -Text '' -SessionId $null -ErrorText 'boom 500'
            $text = Get-ConsoleOutputText -Result $result -RawOutput '{"is_error":true,"result":"boom 500"}'
            $text | Should -Be 'boom 500'
        }

        It 'falls back to the raw output when there is no parsed text' {
            $result = New-CliResult -Ok $false -IsLimit $false -Text '' -SessionId $null -ErrorText ''
            $text = Get-ConsoleOutputText -Result $result -RawOutput 'node: command not found'
            $text | Should -Be 'node: command not found'
        }

        It 'returns the raw output when -ShowRawOutput is requested' {
            $result = New-CliResult -Ok $true -IsLimit $false -Text 'pong' -SessionId 's' -ErrorText $null
            $raw = '{"result":"pong","session_id":"s"}'
            $text = Get-ConsoleOutputText -Result $result -RawOutput $raw -ShowRawOutput
            $text | Should -Be $raw
        }
    }

    Context 'Get-TaskSlug (Task 4 output naming)' {
        It 'lowercases nothing but replaces non [A-Za-z0-9._-] runs with single dashes and trims' {
            Get-TaskSlug -Name 'Clean Output Task' | Should -Be 'Clean-Output-Task'
        }

        It 'collapses punctuation and whitespace to single dashes' {
            Get-TaskSlug -Name 'fix: the, thing!!' | Should -Be 'fix-the-thing'
        }

        It 'keeps dots, underscores and hyphens' {
            Get-TaskSlug -Name 'a.b_c-d' | Should -Be 'a.b_c-d'
        }

        It 'caps the slug length at 40 characters' {
            $name = ('x' * 80)
            (Get-TaskSlug -Name $name).Length | Should -BeLessOrEqual 40
        }

        It 'falls back to "task" when the name has no usable characters' {
            Get-TaskSlug -Name '   ***   ' | Should -Be 'task'
        }
    }

    Context 'Get-TaskFingerprint (Task 4 canonical fingerprint)' {
        It 'is stable for identical task content' {
            $task = [pscustomobject]@{
                Name = 'a'; Cli = 'claude'; ProjectPath = 'C:\proj'
                Model = 'm'; Effort = 'high'; Prompt = 'do it'; ExtraArgs = @('--x', '--y')
            }
            $fp1 = Get-TaskFingerprint -Task $task
            $fp2 = Get-TaskFingerprint -Task $task
            $fp1 | Should -Be $fp2
            $fp1 | Should -Match '^[0-9a-f]{64}$'
        }

        It 'changes when the prompt changes' {
            $a = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p'; Model=$null; Effort=$null; Prompt='X'; ExtraArgs=@() }
            $b = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p'; Model=$null; Effort=$null; Prompt='Y'; ExtraArgs=@() }
            (Get-TaskFingerprint -Task $a) | Should -Not -Be (Get-TaskFingerprint -Task $b)
        }

        It 'changes when the cli changes' {
            $a = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p'; Model=$null; Effort=$null; Prompt='X'; ExtraArgs=@() }
            $b = [pscustomobject]@{ Name='a'; Cli='codex';  ProjectPath='C:\p'; Model=$null; Effort=$null; Prompt='X'; ExtraArgs=@() }
            (Get-TaskFingerprint -Task $a) | Should -Not -Be (Get-TaskFingerprint -Task $b)
        }

        It 'changes when the projectPath changes' {
            $a = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p1'; Model=$null; Effort=$null; Prompt='X'; ExtraArgs=@() }
            $b = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p2'; Model=$null; Effort=$null; Prompt='X'; ExtraArgs=@() }
            (Get-TaskFingerprint -Task $a) | Should -Not -Be (Get-TaskFingerprint -Task $b)
        }

        It 'changes when extraArgs change but ignores how the fields are ordered internally' {
            $a = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p'; Model=$null; Effort=$null; Prompt='X'; ExtraArgs=@('--a') }
            $b = [pscustomobject]@{ Name='a'; Cli='claude'; ProjectPath='C:\p'; Model=$null; Effort=$null; Prompt='X'; ExtraArgs=@('--a','--b') }
            (Get-TaskFingerprint -Task $a) | Should -Not -Be (Get-TaskFingerprint -Task $b)
        }
    }

    Context 'CSV escaping (Task 4 runs.csv)' {
        It 'quotes a field containing a comma' {
            ConvertTo-CsvField -Value 'a,b' | Should -Be '"a,b"'
        }

        It 'doubles embedded double-quotes and wraps in quotes' {
            ConvertTo-CsvField -Value 'say "hi"' | Should -Be '"say ""hi"""'
        }

        It 'leaves a plain field unquoted' {
            ConvertTo-CsvField -Value 'plain' | Should -Be 'plain'
        }
    }

    Context 'Get-CliArguments' {
        It 'builds a claude new-session command without the prompt in the args' {
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'claude'; ProjectPath = 'C:\proj'
                Model = 'claude-sonnet-4-6'; Effort = 'high'
                Prompt = 'do the thing'; ExtraArgs = @('--verbose')
            }

            $args = Get-CliArguments -Task $task -Mode New -SessionId 'abc-123'
            ($args -join ' ') | Should -Be '-p --session-id abc-123 --output-format json --model claude-sonnet-4-6 --effort high --verbose'
            $args | Should -Not -Contain 'do the thing'
        }

        It 'builds a claude resume command without the prompt in the args' {
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'claude'; ProjectPath = 'C:\proj'
                Model = 'claude-sonnet-4-6'; Effort = 'high'
                Prompt = 'do the thing'; ExtraArgs = @('--verbose')
            }

            $args = Get-CliArguments -Task $task -Mode Resume -SessionId 'abc-123'
            ($args -join ' ') | Should -Be '-p --resume abc-123 --output-format json --model claude-sonnet-4-6 --effort high --verbose'
        }

        It 'builds a codex new-session command without forcing -C and without the prompt' {
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'codex'; ProjectPath = 'C:\proj'
                Model = 'gpt-5-codex'; Effort = 'high'
                Prompt = 'do the thing'; ExtraArgs = @('--sandbox', 'workspace-write', '--skip-git-repo-check')
            }

            $args = Get-CliArguments -Task $task -Mode New -SessionId $null
            ($args -join ' ') | Should -Be 'exec --json -m gpt-5-codex -c model_reasoning_effort=high --sandbox workspace-write --skip-git-repo-check'
            (@($args | Where-Object { $_ -ceq '-C' })).Count | Should -Be 0
            $args | Should -Not -Contain 'do the thing'
        }

        It 'drops resume-unsupported codex flags while keeping supported ones' {
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'codex'; ProjectPath = 'C:\proj'
                Model = 'gpt-5-codex'; Effort = 'high'
                Prompt = 'do the thing'
                ExtraArgs = @(
                    '--sandbox', 'workspace-write',
                    '--skip-git-repo-check',
                    '--dangerously-bypass-approvals-and-sandbox'
                )
            }

            $args = Get-CliArguments -Task $task -Mode Resume -SessionId 'thr_9'
            ($args -join ' ') | Should -Be 'exec resume thr_9 --json -m gpt-5-codex -c model_reasoning_effort=high --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox'
            (@($args | Where-Object { $_ -ceq '-C' })).Count | Should -Be 0
            $args | Should -Not -Contain '--sandbox'
        }

        It 'builds a gemini command, omitting effort and the -p prompt pair' {
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'gemini'; ProjectPath = 'C:\proj'
                Model = 'gemini-2.5-pro'; Effort = 'high'
                Prompt = 'do the thing'; ExtraArgs = @('--verbose')
            }

            $args = Get-CliArguments -Task $task -Mode New -SessionId $null
            ($args -join ' ') | Should -Be '--output-format json -m gemini-2.5-pro --verbose'
            $args | Should -Not -Contain '-p'
            $args | Should -Not -Contain 'do the thing'
        }

        It 'builds a gemini resume command when a session id exists' {
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'gemini'; ProjectPath = 'C:\proj'
                Model = 'gemini-2.5-pro'; Effort = 'high'
                Prompt = 'do the thing'; ExtraArgs = @('--verbose')
            }

            $args = Get-CliArguments -Task $task -Mode Resume -SessionId 'g-1'
            ($args -join ' ') | Should -Be '--resume g-1 --output-format json -m gemini-2.5-pro --verbose'
        }

        It 'omits model and effort args when the task does not set them' {
            $task = [pscustomobject]@{
                Name = 't'; Cli = 'claude'; ProjectPath = 'C:\proj'
                Model = $null; Effort = $null; Prompt = 'do the thing'; ExtraArgs = @()
            }

            $args = Get-CliArguments -Task $task -Mode New -SessionId 's'
            ($args -join ' ') | Should -Be '-p --session-id s --output-format json'
        }
    }

    Context 'Invoke-NativeProcess stdin delivery' {
        It 'round-trips a multi-line prompt with quotes through stdin to a .cmd shim' {
            $root = New-TestRoot
            $binPath = Join-Path $root 'bin'
            New-Item -ItemType Directory -Path $binPath -Force | Out-Null

            $stubPath = Join-Path $binPath 'echo-stdin.cmd'
            '@powershell -NoProfile -Command "[Console]::In.ReadToEnd() | Write-Output"' |
                Set-Content -LiteralPath $stubPath -Encoding Ascii

            $prompt = "line one with `"double quotes`"`r`nline two`r`n`r`n[[TASK_COMPLETE]]"
            $result = Invoke-NativeProcess -Command $stubPath -Arguments @() -WorkingDirectory $root -StdinText $prompt

            $result.ExitCode | Should -Be 0
            $received = ($result.StdOut -replace "`r`n", "`n").TrimEnd("`n")
            $expected = ($prompt -replace "`r`n", "`n").TrimEnd("`n")
            $received | Should -Be $expected
        }
    }

    Context 'Format-CommandForDisplay' {
        It 'renders multiline gemini prompts without gluing trailing flags onto the last prompt line' {
            $display = Format-CommandForDisplay -Command 'gemini' -Arguments @(
                '-p',
                "line one`n[[TASK_BLOCKED]] <one-line reason>",
                '--output-format',
                'json',
                '-m',
                'gemini-2.5-flash'
            )

            $display | Should -Match 'gemini -p'
            $display | Should -Match '--output-format json -m gemini-2.5-flash'
            $display | Should -Not -Match '\[\[TASK_BLOCKED\]\] <one-line reason> --output-format'
        }
    }

    Context 'ConvertFrom-CliOutput' {
        It 'parses a claude success result' {
            $result = ConvertFrom-CliOutput -Cli claude -OutputText (Get-Content -LiteralPath (Join-Path $script:__limitshiftOutputFixtures 'claude-success.json') -Raw) -ExitCode 0
            $result.Ok | Should -Be $true
            $result.IsLimit | Should -Be $false
            $result.Text | Should -Match '\[\[TASK_COMPLETE\]\]'
            $result.SessionId | Should -Not -BeNullOrEmpty
        }

        It 'detects a claude usage limit' {
            $result = ConvertFrom-CliOutput -Cli claude -OutputText (Get-Content -LiteralPath (Join-Path $script:__limitshiftOutputFixtures 'claude-limit.json') -Raw) -ExitCode 1
            $result.Ok | Should -Be $false
            $result.IsLimit | Should -Be $true
        }

        It 'reports a claude non-limit error as an error, not a limit' {
            $result = ConvertFrom-CliOutput -Cli claude -OutputText (Get-Content -LiteralPath (Join-Path $script:__limitshiftOutputFixtures 'claude-error.json') -Raw) -ExitCode 1
            $result.Ok | Should -Be $false
            $result.IsLimit | Should -Be $false
            $result.ErrorText | Should -Match '500'
        }

        It 'parses codex JSONL, extracting thread id and final message' {
            $result = ConvertFrom-CliOutput -Cli codex -OutputText (Get-Content -LiteralPath (Join-Path $script:__limitshiftOutputFixtures 'codex-success.jsonl') -Raw) -ExitCode 0
            $result.Ok | Should -Be $true
            $result.SessionId | Should -Be '0199a213-81c0-7800-8aa1-1d4111ae8b9f'
            $result.Text | Should -Match '\[\[TASK_COMPLETE\]\]'
        }

        It 'detects a codex usage limit from an error event' {
            $result = ConvertFrom-CliOutput -Cli codex -OutputText (Get-Content -LiteralPath (Join-Path $script:__limitshiftOutputFixtures 'codex-limit.jsonl') -Raw) -ExitCode 1
            $result.Ok | Should -Be $false
            $result.IsLimit | Should -Be $true
            $result.SessionId | Should -Be '0199a213-81c0-7800-8aa1-1d4111ae8b9f'
        }

        It 'parses a gemini success response despite leading warning noise, capturing session_id' {
            $result = ConvertFrom-CliOutput -Cli gemini -OutputText (Get-Content -LiteralPath (Join-Path $script:__limitshiftOutputFixtures 'gemini-success.json') -Raw) -ExitCode 0
            $result.Ok | Should -Be $true
            $result.Text | Should -Match '\[\[TASK_COMPLETE\]\]'
            $result.SessionId | Should -Not -BeNullOrEmpty
        }

        It 'detects a gemini quota error as a limit' {
            $result = ConvertFrom-CliOutput -Cli gemini -OutputText (Get-Content -LiteralPath (Join-Path $script:__limitshiftOutputFixtures 'gemini-error.json') -Raw) -ExitCode 1
            $result.Ok | Should -Be $false
            $result.IsLimit | Should -Be $true
        }

        It 'survives non-JSON garbage output without throwing' {
            $result = ConvertFrom-CliOutput -Cli claude -OutputText 'node: command not found' -ExitCode 127
            $result.Ok | Should -Be $false
            $result.ErrorText | Should -Match 'command not found'
        }

        It 'does not throw on unexpected codex event shapes under StrictMode' {
            {
                ConvertFrom-CliOutput -Cli codex -OutputText '{"type":"item.completed"}' -ExitCode 0
            } | Should -Not -Throw
        }

        It 'parses gemini JSON followed by warning noise without adding parser errors' {
            $before = $Error.Count
            $result = ConvertFrom-CliOutput -Cli gemini -OutputText @'
{"session_id":"g-1","response":"OK\n[[TASK_COMPLETE]]"}
Warning: 256-color support not detected. Using a terminal with at least 256-color support is recommended for a better visual experience.
Ripgrep is not available. Falling back to GrepTool.
'@ -ExitCode 0

            $result.Ok | Should -Be $true
            $result.SessionId | Should -Be 'g-1'
            $result.Text | Should -Match '\[\[TASK_COMPLETE\]\]'
            $Error.Count | Should -Be $before
        }

        It 'cleans up native executable runs without null LiteralPath failures' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null

            $result = Invoke-NativeProcess -Command 'cmd.exe' -Arguments @('/c', 'echo', 'OK') -WorkingDirectory $projectPath

            $result.ExitCode | Should -Be 0
            $result.OutputText | Should -Match 'OK'
            $Error[0].Exception.Message | Should -Not -Match 'LiteralPath'
        }
    }

    Context 'entry points' {
        It 'returns exit code 2 for validation failures' {
            $queuePath = Join-Path $script:__limitshiftConfigFixtures 'broken-trailing-comma.json'
            $run = Invoke-RunnerProcess -Arguments @(
                '-NoProfile',
                '-File', $script:__limitshiftScriptPath,
                '-ValidateOnly',
                '-QueuePath', $queuePath
            )

            $run.ExitCode | Should -Be 2
            $run.Output | Should -Match 'not valid JSON'
        }

        It 'dry run prints commands without creating done markers' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null

            $queuePath = Join-Path $root 'queue.json'
            Write-TestQueue -Path $queuePath -Config @{
                settings = @{
                    stopOnError        = $true
                    maxRunsPerTask     = 2
                    maxRetriesOnError  = 0
                    limitWaitMinutes   = 1
                    resetBufferMinutes = 0
                }
                tasks = @(
                    @{
                        name        = 'dry run task'
                        cli         = 'claude'
                        projectPath = $projectPath
                        prompt      = 'say hi'
                    }
                )
            }

            $run = Invoke-RunnerProcess -Arguments @(
                '-NoProfile',
                '-File', $script:__limitshiftScriptPath,
                '-DryRun',
                '-QueuePath', $queuePath
            )

            $run.ExitCode | Should -Be 0
            $run.Output | Should -Match 'Command: claude'

            $statusPath = Join-Path $root '.ai-runner-queue\status'
            $doneFiles = Get-ChildItem -LiteralPath $statusPath -Filter '*.done' -ErrorAction SilentlyContinue
            $doneFiles | Should -BeNullOrEmpty
        }

        It 'checks CLI binaries before a real run' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null

            $queuePath = Join-Path $root 'queue.json'
            Write-TestQueue -Path $queuePath -Config @{
                settings = @{
                    stopOnError        = $true
                    maxRunsPerTask     = 1
                    maxRetriesOnError  = 0
                    limitWaitMinutes   = 1
                    resetBufferMinutes = 0
                }
                tasks = @(
                    @{
                        name        = 'needs claude'
                        cli         = 'claude'
                        projectPath = $projectPath
                        prompt      = 'say hi'
                    }
                )
            }

            $oldPath = $env:PATH
            try {
                $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
                $run = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile',
                    '-File', $script:__limitshiftScriptPath,
                    '-QueuePath', $queuePath
                )
                $run.ExitCode | Should -Be 2
                $run.Output | Should -Match 'not found on PATH'
            }
            finally {
                $env:PATH = $oldPath
            }
        }

        It 'runs gemini through a PowerShell shim without failing on stderr warnings' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            $binPath = Join-Path $root 'bin'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
            New-Item -ItemType Directory -Path $binPath -Force | Out-Null

            $geminiPath = Join-Path $binPath 'gemini.ps1'
            @"
[Console]::Error.WriteLine('Warning: 256-color support not detected. Using a terminal with at least 256-color support is recommended for a better visual experience.')
`$stdinText = [Console]::In.ReadToEnd()
if (`$stdinText -notmatch 'say hi') {
    Write-Output '{"error":{"message":"prompt was not delivered on stdin","code":"400"}}'
    exit 1
}
Write-Output '{"session_id":"g-1","response":"done\n\n[[TASK_COMPLETE]]"}'
exit 0
"@ | Set-Content -LiteralPath $geminiPath -Encoding UTF8

            $queuePath = Join-Path $root 'queue.json'
            Write-TestQueue -Path $queuePath -Config @{
                settings = @{
                    stopOnError        = $true
                    maxRunsPerTask     = 1
                    maxRetriesOnError  = 0
                    limitWaitMinutes   = 1
                    resetBufferMinutes = 0
                }
                tasks = @(
                    @{
                        name        = 'gemini warning'
                        cli         = 'gemini'
                        projectPath = $projectPath
                        model       = 'gemini-2.5-flash'
                        prompt      = 'say hi'
                    }
                )
            }

            $oldPath = $env:PATH
            try {
                $env:PATH = "$binPath;$oldPath"
                $run = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile',
                    '-File', $script:__limitshiftScriptPath,
                    '-QueuePath', $queuePath
                )

                $run.ExitCode | Should -Be 0
                $run.Output | Should -Match 'Task 1 completed'
                $run.Output | Should -Match 'prompt sent via stdin'

                $statusPath = Join-Path $root '.ai-runner-queue\status\task-01.done'
                Test-Path -LiteralPath $statusPath | Should -BeTrue

                $outputFilePath = Join-Path $root '.ai-runner-queue\outputs\task-01-gemini-warning-output.txt'
                Test-Path -LiteralPath $outputFilePath | Should -BeTrue
                $outputFileText = [System.IO.File]::ReadAllText($outputFilePath)
                $outputFileText | Should -Match 'say hi'
                $outputFileText | Should -Match 'IMPORTANT AUTOMATION INSTRUCTIONS'
            }
            finally {
                $env:PATH = $oldPath
            }
        }

        It 'simple mode (completionCheck:false) sends the prompt verbatim and completes in one run' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            $binPath = Join-Path $root 'bin'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
            New-Item -ItemType Directory -Path $binPath -Force | Out-Null

            $receivedFile = Join-Path $root 'received.txt'
            $claudePath = Join-Path $binPath 'claude.ps1'
            @"
if (`$args.Count -ge 2 -and `$args[0] -eq '-p' -and `$args[1] -eq '/usage') {
    Write-Output 'Current session: 0% used'
    Write-Output 'Current week (all models): 0% used'
    exit 0
}
`$stdinText = [Console]::In.ReadToEnd()
[System.IO.File]::WriteAllText('$($receivedFile -replace '\\','\\')', `$stdinText)
Write-Output '{"result":"I did the thing, no marker here","session_id":"s-1","is_error":false}'
exit 0
"@ | Set-Content -LiteralPath $claudePath -Encoding UTF8

            $queuePath = Join-Path $root 'queue.json'
            Write-TestQueue -Path $queuePath -Config @{
                settings = @{
                    stopOnError        = $true
                    maxRunsPerTask     = 5
                    maxRetriesOnError  = 0
                    limitWaitMinutes   = 1
                    resetBufferMinutes = 0
                    completionCheck    = $false
                }
                tasks = @(
                    @{
                        name        = 'simple mode task'
                        cli         = 'claude'
                        projectPath = $projectPath
                        prompt      = 'just do this verbatim'
                    }
                )
            }

            $oldPath = $env:PATH
            try {
                $env:PATH = "$binPath;$oldPath"
                $run = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile',
                    '-File', $script:__limitshiftScriptPath,
                    '-QueuePath', $queuePath
                )

                $run.ExitCode | Should -Be 0
                $run.Output | Should -Match 'Task 1 completed'

                $donePath = Join-Path $root '.ai-runner-queue\status\task-01.done'
                Test-Path -LiteralPath $donePath | Should -BeTrue

                $received = [System.IO.File]::ReadAllText($receivedFile)
                $received | Should -BeExactly 'just do this verbatim'
                $received | Should -Not -Match 'IMPORTANT AUTOMATION INSTRUCTIONS'
            }
            finally {
                $env:PATH = $oldPath
            }
        }

        It 'simple mode resumes after a usage limit and marks done on the resumed OK run' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            $binPath = Join-Path $root 'bin'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
            New-Item -ItemType Directory -Path $binPath -Force | Out-Null

            $counterFile = Join-Path $root 'counter.txt'
            $geminiPath = Join-Path $binPath 'gemini.ps1'
            @"
`$stdinText = [Console]::In.ReadToEnd()
`$counterPath = '$($counterFile -replace '\\','\\')'
`$n = 0
if (Test-Path -LiteralPath `$counterPath) { `$n = [int](Get-Content -LiteralPath `$counterPath -Raw) }
`$n++
Set-Content -LiteralPath `$counterPath -Value `$n
if (`$n -eq 1) {
    Write-Output '{"session_id":"g-lim","error":{"message":"Quota exceeded. Try again in 0s.","code":"429"}}'
    exit 1
}
Write-Output '{"session_id":"g-lim","response":"finished after resume, no marker"}'
exit 0
"@ | Set-Content -LiteralPath $geminiPath -Encoding UTF8

            $queuePath = Join-Path $root 'queue.json'
            Write-TestQueue -Path $queuePath -Config @{
                settings = @{
                    stopOnError        = $true
                    maxRunsPerTask     = 5
                    maxRetriesOnError  = 0
                    limitWaitMinutes   = 1
                    resetBufferMinutes = 0
                    completionCheck    = $false
                }
                tasks = @(
                    @{
                        name        = 'simple gemini limit'
                        cli         = 'gemini'
                        projectPath = $projectPath
                        model       = 'gemini-2.5-flash'
                        prompt      = 'do it verbatim'
                    }
                )
            }

            $oldPath = $env:PATH
            try {
                $env:PATH = "$binPath;$oldPath"
                $run = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile',
                    '-File', $script:__limitshiftScriptPath,
                    '-QueuePath', $queuePath
                )

                $run.ExitCode | Should -Be 0
                $run.Output | Should -Match 'paused by a usage limit'
                $run.Output | Should -Match 'Task 1 completed'

                $donePath = Join-Path $root '.ai-runner-queue\status\task-01.done'
                Test-Path -LiteralPath $donePath | Should -BeTrue
            }
            finally {
                $env:PATH = $oldPath
            }
        }

        It 'stall guard fails the task after maxStalls identical no-marker responses' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            $binPath = Join-Path $root 'bin'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
            New-Item -ItemType Directory -Path $binPath -Force | Out-Null

            $claudePath = Join-Path $binPath 'claude.ps1'
            @"
if (`$args.Count -ge 2 -and `$args[0] -eq '-p' -and `$args[1] -eq '/usage') {
    Write-Output 'Current session: 0% used'
    Write-Output 'Current week (all models): 0% used'
    exit 0
}
`$null = [Console]::In.ReadToEnd()
Write-Output '{"result":"I am ready to help. What would you like me to work on?","session_id":"s-1","is_error":false}'
exit 0
"@ | Set-Content -LiteralPath $claudePath -Encoding UTF8

            $queuePath = Join-Path $root 'queue.json'
            Write-TestQueue -Path $queuePath -Config @{
                settings = @{
                    stopOnError        = $true
                    maxRunsPerTask     = 20
                    maxRetriesOnError  = 0
                    limitWaitMinutes   = 1
                    resetBufferMinutes = 0
                    maxStalls          = 2
                }
                tasks = @(
                    @{
                        name        = 'stalling task'
                        cli         = 'claude'
                        projectPath = $projectPath
                        prompt      = 'respond OK only'
                    }
                )
            }

            $oldPath = $env:PATH
            try {
                $env:PATH = "$binPath;$oldPath"
                $run = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile',
                    '-File', $script:__limitshiftScriptPath,
                    '-QueuePath', $queuePath
                )

                $run.ExitCode | Should -Be 1
                $run.Output | Should -Match 'no progress'

                $failedPath = Join-Path $root '.ai-runner-queue\status\task-01.failed'
                Test-Path -LiteralPath $failedPath | Should -BeTrue
                $failedText = [System.IO.File]::ReadAllText($failedPath)
                $failedText | Should -Match 'no progress: agent repeated the same response without a completion marker'
            }
            finally {
                $env:PATH = $oldPath
            }
        }

        It 'prints the clean agent response text to the console, not raw JSON' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            $binPath = Join-Path $root 'bin'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
            New-Item -ItemType Directory -Path $binPath -Force | Out-Null

            $claudePath = Join-Path $binPath 'claude.ps1'
            @"
if (`$args.Count -ge 2 -and `$args[0] -eq '-p' -and `$args[1] -eq '/usage') {
    Write-Output 'Current session: 0% used'
    Write-Output 'Current week (all models): 0% used'
    exit 0
}
`$null = [Console]::In.ReadToEnd()
Write-Output '{"result":"Here is the clean answer\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'
exit 0
"@ | Set-Content -LiteralPath $claudePath -Encoding UTF8

            $queuePath = Join-Path $root 'queue.json'
            Write-TestQueue -Path $queuePath -Config @{
                settings = @{
                    stopOnError        = $true
                    maxRunsPerTask     = 2
                    maxRetriesOnError  = 0
                    limitWaitMinutes   = 1
                    resetBufferMinutes = 0
                }
                tasks = @(
                    @{
                        name        = 'clean output task'
                        cli         = 'claude'
                        projectPath = $projectPath
                        prompt      = 'answer cleanly'
                    }
                )
            }

            $oldPath = $env:PATH
            try {
                $env:PATH = "$binPath;$oldPath"
                $run = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile',
                    '-File', $script:__limitshiftScriptPath,
                    '-QueuePath', $queuePath
                )

                $run.ExitCode | Should -Be 0
                $run.Output | Should -Match '--- agent response ---'
                $run.Output | Should -Match 'Here is the clean answer'
                $run.Output | Should -Not -Match '"session_id"'
                $run.Output | Should -Not -Match '"result"'

                # The raw JSON still lands in the per-task output file.
                $outputFilePath = Join-Path $root '.ai-runner-queue\outputs\task-01-clean-output-task-output.txt'
                $outputFileText = [System.IO.File]::ReadAllText($outputFilePath)
                $outputFileText | Should -Match '"session_id"'
            }
            finally {
                $env:PATH = $oldPath
            }
        }

        It 'honors -ShowRawOutput by printing the raw JSON to the console' {
            $root = New-TestRoot
            $projectPath = Join-Path $root 'project'
            $binPath = Join-Path $root 'bin'
            New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
            New-Item -ItemType Directory -Path $binPath -Force | Out-Null

            $claudePath = Join-Path $binPath 'claude.ps1'
            @"
if (`$args.Count -ge 2 -and `$args[0] -eq '-p' -and `$args[1] -eq '/usage') {
    Write-Output 'Current session: 0% used'
    Write-Output 'Current week (all models): 0% used'
    exit 0
}
`$null = [Console]::In.ReadToEnd()
Write-Output '{"result":"answer\n[[TASK_COMPLETE]]","session_id":"s-raw","is_error":false}'
exit 0
"@ | Set-Content -LiteralPath $claudePath -Encoding UTF8

            $queuePath = Join-Path $root 'queue.json'
            Write-TestQueue -Path $queuePath -Config @{
                settings = @{
                    stopOnError        = $true
                    maxRunsPerTask     = 2
                    maxRetriesOnError  = 0
                    limitWaitMinutes   = 1
                    resetBufferMinutes = 0
                }
                tasks = @(
                    @{
                        name        = 'raw output task'
                        cli         = 'claude'
                        projectPath = $projectPath
                        prompt      = 'answer'
                    }
                )
            }

            $oldPath = $env:PATH
            try {
                $env:PATH = "$binPath;$oldPath"
                $run = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile',
                    '-File', $script:__limitshiftScriptPath,
                    '-ShowRawOutput',
                    '-QueuePath', $queuePath
                )

                $run.ExitCode | Should -Be 0
                $run.Output | Should -Match '"session_id"'
            }
            finally {
                $env:PATH = $oldPath
            }
        }
    }

    Context 'State lifecycle (Task 4)' {
        BeforeAll {
            function New-FingerprintFixture {
                param([string]$Prompt = 'just do this verbatim')

                $root = New-TestRoot
                $projectPath = Join-Path $root 'project'
                $binPath = Join-Path $root 'bin'
                New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
                New-Item -ItemType Directory -Path $binPath -Force | Out-Null

                $claudePath = Join-Path $binPath 'claude.ps1'
                @"
if (`$args.Count -ge 2 -and `$args[0] -eq '-p' -and `$args[1] -eq '/usage') {
    Write-Output 'Current session: 0% used'
    Write-Output 'Current week (all models): 0% used'
    exit 0
}
`$null = [Console]::In.ReadToEnd()
Write-Output '{"result":"did it\n[[TASK_COMPLETE]]","session_id":"s-1","is_error":false}'
exit 0
"@ | Set-Content -LiteralPath $claudePath -Encoding UTF8

                $queuePath = Join-Path $root 'queue.json'
                Write-TestQueue -Path $queuePath -Config @{
                    settings = @{
                        stopOnError        = $true
                        maxRunsPerTask     = 3
                        maxRetriesOnError  = 0
                        limitWaitMinutes   = 1
                        resetBufferMinutes = 0
                    }
                    tasks = @(
                        @{ name = 'fp task'; cli = 'claude'; projectPath = $projectPath; prompt = $Prompt }
                    )
                }

                return [pscustomobject]@{ Root = $root; BinPath = $binPath; QueuePath = $queuePath }
            }
        }

        It 'writes a fingerprint into the .done file and a runs.csv row and a state _README.txt' {
            $fx = New-FingerprintFixture
            $oldPath = $env:PATH
            try {
                $env:PATH = "$($fx.BinPath);$oldPath"
                $run = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile', '-File', $script:__limitshiftScriptPath, '-QueuePath', $fx.QueuePath
                )
                $run.ExitCode | Should -Be 0

                $donePath = Join-Path $fx.Root '.ai-runner-queue\status\task-01.done'
                Test-Path -LiteralPath $donePath | Should -BeTrue
                $doneLines = @(Get-Content -LiteralPath $donePath)
                # Two lines: timestamp then a 64-hex fingerprint.
                $doneLines.Count | Should -Be 2
                $doneLines[1] | Should -Match '^[0-9a-f]{64}$'

                $readmePath = Join-Path $fx.Root '.ai-runner-queue\_README.txt'
                Test-Path -LiteralPath $readmePath | Should -BeTrue
                (Get-Content -LiteralPath $readmePath -Raw) | Should -Match 'delete this whole folder'

                $csvPath = Join-Path $fx.Root '.ai-runner-queue\runs.csv'
                Test-Path -LiteralPath $csvPath | Should -BeTrue
                $csvLines = @(Get-Content -LiteralPath $csvPath)
                $csvLines[0] | Should -Be 'timestamp,task,run,mode,exit,status'
                @($csvLines | Where-Object { $_ -match 'Done' }).Count | Should -BeGreaterThan 0
            }
            finally {
                $env:PATH = $oldPath
            }
        }

        It 're-runs a done task when the prompt changed (stale fingerprint), invalidating the done marker and the session id' {
            $fx = New-FingerprintFixture -Prompt 'original prompt'
            $oldPath = $env:PATH
            try {
                $env:PATH = "$($fx.BinPath);$oldPath"
                $first = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile', '-File', $script:__limitshiftScriptPath, '-QueuePath', $fx.QueuePath
                )
                $first.ExitCode | Should -Be 0
                $donePath = Join-Path $fx.Root '.ai-runner-queue\status\task-01.done'
                Test-Path -LiteralPath $donePath | Should -BeTrue
                $sessionPath = Join-Path $fx.Root '.ai-runner-queue\sessions\task-01-session-id.txt'
                Test-Path -LiteralPath $sessionPath | Should -BeTrue

                # Change the prompt in the queue, then re-run.
                $cfg = Get-Content -LiteralPath $fx.QueuePath -Raw | ConvertFrom-Json
                $cfg.tasks[0].prompt = 'a completely different prompt'
                $cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fx.QueuePath -Encoding UTF8

                $second = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile', '-File', $script:__limitshiftScriptPath, '-QueuePath', $fx.QueuePath
                )
                $second.ExitCode | Should -Be 0
                $second.Output | Should -Match 'changed since last run'
                $second.Output | Should -Not -Match 'already marked as done'
            }
            finally {
                $env:PATH = $oldPath
            }
        }

        It 're-runs a task whose .done marker is a legacy single timestamp line (no fingerprint), then writes a 2-line marker' {
            # Legacy markers (written before fingerprinting existed) hold only a timestamp. They have
            # no fingerprint line, so they mismatch the current fingerprint and the task re-runs ONCE,
            # after which a 2-line marker (timestamp + fingerprint) is written and it stabilizes.
            $fx = New-FingerprintFixture -Prompt 'unchanged prompt'
            $oldPath = $env:PATH
            try {
                $env:PATH = "$($fx.BinPath);$oldPath"

                # Seed a legacy single-line .done marker for an otherwise-unchanged queue task.
                $statusPath = Join-Path $fx.Root '.ai-runner-queue\status'
                New-Item -ItemType Directory -Path $statusPath -Force | Out-Null
                $donePath = Join-Path $statusPath 'task-01.done'
                (Get-Date).ToString("s") | Set-Content -LiteralPath $donePath -Encoding UTF8
                @(Get-Content -LiteralPath $donePath).Count | Should -Be 1

                $run = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile', '-File', $script:__limitshiftScriptPath, '-QueuePath', $fx.QueuePath
                )
                $run.ExitCode | Should -Be 0
                $run.Output | Should -Match 'changed since last run'
                $run.Output | Should -Not -Match 'already marked as done'

                # The legacy marker has been upgraded to the 2-line timestamp + fingerprint form.
                $doneLines = @(Get-Content -LiteralPath $donePath)
                $doneLines.Count | Should -Be 2
                $doneLines[1] | Should -Match '^[0-9a-f]{64}$'
            }
            finally {
                $env:PATH = $oldPath
            }
        }

        It 'skips a done task when nothing changed (fingerprint matches)' {
            $fx = New-FingerprintFixture -Prompt 'unchanged prompt'
            $oldPath = $env:PATH
            try {
                $env:PATH = "$($fx.BinPath);$oldPath"
                $first = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile', '-File', $script:__limitshiftScriptPath, '-QueuePath', $fx.QueuePath
                )
                $first.ExitCode | Should -Be 0

                $second = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile', '-File', $script:__limitshiftScriptPath, '-QueuePath', $fx.QueuePath
                )
                $second.ExitCode | Should -Be 0
                $second.Output | Should -Match 'already marked as done'
                $second.Output | Should -Not -Match 'changed since last run'
            }
            finally {
                $env:PATH = $oldPath
            }
        }

        It 're-runs a done task when the cli changed' {
            # Stub both claude and codex so either cli completes the run.
            $fx = New-FingerprintFixture -Prompt 'same prompt'
            $codexPath = Join-Path $fx.BinPath 'codex.ps1'
            @"
`$null = [Console]::In.ReadToEnd()
Write-Output '{"type":"thread.started","thread_id":"thr-1"}'
Write-Output '{"type":"item.completed","item":{"type":"agent_message","text":"did it\n[[TASK_COMPLETE]]"}}'
exit 0
"@ | Set-Content -LiteralPath $codexPath -Encoding UTF8

            $oldPath = $env:PATH
            try {
                $env:PATH = "$($fx.BinPath);$oldPath"
                $first = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile', '-File', $script:__limitshiftScriptPath, '-QueuePath', $fx.QueuePath
                )
                $first.ExitCode | Should -Be 0

                $cfg = Get-Content -LiteralPath $fx.QueuePath -Raw | ConvertFrom-Json
                $cfg.tasks[0].cli = 'codex'
                $cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fx.QueuePath -Encoding UTF8

                $second = Invoke-RunnerProcess -Arguments @(
                    '-NoProfile', '-File', $script:__limitshiftScriptPath, '-QueuePath', $fx.QueuePath
                )
                $second.ExitCode | Should -Be 0
                $second.Output | Should -Match 'changed since last run'
            }
            finally {
                $env:PATH = $oldPath
            }
        }
    }
}
