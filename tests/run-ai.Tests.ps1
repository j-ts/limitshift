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

                $outputFilePath = Join-Path $root '.ai-runner-queue\outputs\task-01-output.txt'
                Test-Path -LiteralPath $outputFilePath | Should -BeTrue
                $outputFileText = [System.IO.File]::ReadAllText($outputFilePath)
                $outputFileText | Should -Match 'say hi'
                $outputFileText | Should -Match 'IMPORTANT AUTOMATION INSTRUCTIONS'
            }
            finally {
                $env:PATH = $oldPath
            }
        }
    }
}
