$ScriptPath = Join-Path $PSScriptRoot '..\run-ai.ps1'
$Fixtures   = Join-Path $PSScriptRoot 'fixtures\configs'
. $ScriptPath -LoadFunctionsOnly

Describe 'Read-QueueConfig' {
    It 'loads a minimal valid config' {
        $cfg = Read-QueueConfig -Path (Join-Path $Fixtures 'valid-minimal.json')
        $cfg.Tasks.Count | Should Be 1
        $cfg.Tasks[0].Cli | Should Be 'claude'
    }
    It 'applies default settings when settings block is absent' {
        $cfg = Read-QueueConfig -Path (Join-Path $Fixtures 'valid-minimal.json')
        $cfg.Settings.MaxRunsPerTask | Should Be 20
        $cfg.Settings.LimitWaitMinutes | Should Be 30
    }
    It 'rejects malformed JSON (trailing comma) with a friendly message' {
        { Read-QueueConfig -Path (Join-Path $Fixtures 'broken-trailing-comma.json') } |
            Should Throw 'not valid JSON'
    }
    It 'rejects a task with a missing required field, naming the field and task number' {
        { Read-QueueConfig -Path (Join-Path $Fixtures 'broken-missing-field.json') } |
            Should Throw 'missing required JSON property'
    }
    It 'rejects an unknown cli value, listing the allowed values' {
        { Read-QueueConfig -Path (Join-Path $Fixtures 'broken-bad-cli.json') } |
            Should Throw 'Allowed values: claude, codex, gemini'
    }
    It 'rejects a non-existent projectPath, printing the path' {
        { Read-QueueConfig -Path (Join-Path $Fixtures 'broken-missing-path.json') } |
            Should Throw 'does not exist'
    }
    It 'normalizes extraArgs given as a string into an array' {
        $cfg = Read-QueueConfig -Path (Join-Path $Fixtures 'valid-full.json')
        $extraArgs = $cfg.Tasks | Where-Object { $_.ExtraArgs }
        $extraArgs | Should Not BeNullOrEmpty
        foreach ($arg in $cfg.Tasks.ExtraArgs) {
            if ($null -ne $arg) {
                $arg | Should BeOfType [string]
            }
        }
    }
}

Describe 'Get-CliArguments' {
    $BaseTask = @{
        Name = 't'; Cli = 'claude'; ProjectPath = 'C:\proj'
        Model = 'claude-sonnet-4-6'; Effort = 'high'
        Prompt = 'do the thing'; ExtraArgs = @('--verbose')
    }

    It 'builds a claude new-session command' {
        $t = [pscustomobject]$BaseTask
        $a = Get-CliArguments -Task $t -Mode New -SessionId 'abc-123' -Prompt 'P'
        ($a -join ' ') | Should Be '-p --session-id abc-123 --output-format json --model claude-sonnet-4-6 --effort high --verbose P'
    }
    It 'builds a claude resume command' {
        $t = [pscustomobject]$BaseTask
        $a = Get-CliArguments -Task $t -Mode Resume -SessionId 'abc-123' -Prompt 'P'
        ($a -join ' ') | Should Be '-p --resume abc-123 --output-format json --model claude-sonnet-4-6 --effort high --verbose P'
    }
    It 'builds a codex new-session command mapping effort to a -c override' {
        $t = [pscustomobject](@{
            Name = 't'; Cli = 'codex'; ProjectPath = 'C:\proj'
            Model = 'gpt-5-codex'; Effort = 'high'
            Prompt = 'do the thing'; ExtraArgs = @('--verbose')
        })
        $a = Get-CliArguments -Task $t -Mode New -SessionId $null -Prompt 'P'
        ($a -join ' ') | Should Be 'exec --json -C C:\proj -m gpt-5-codex -c model_reasoning_effort=high --verbose P'
    }
    It 'builds a codex resume command from a thread id' {
        $t = [pscustomobject](@{
            Name = 't'; Cli = 'codex'; ProjectPath = 'C:\proj'
            Model = 'gpt-5-codex'; Effort = 'high'
            Prompt = 'do the thing'; ExtraArgs = @('--verbose')
        })
        $a = Get-CliArguments -Task $t -Mode Resume -SessionId 'thr_9' -Prompt 'P'
        ($a -join ' ') | Should Be 'exec resume thr_9 --json -C C:\proj -m gpt-5-codex -c model_reasoning_effort=high --verbose P'
    }
    It 'builds a gemini command and omits effort' {
        $t = [pscustomobject](@{
            Name = 't'; Cli = 'gemini'; ProjectPath = 'C:\proj'
            Model = 'gemini-2.5-pro'; Effort = 'high'
            Prompt = 'do the thing'; ExtraArgs = @('--verbose')
        })
        $a = Get-CliArguments -Task $t -Mode New -SessionId $null -Prompt 'P'
        ($a -join ' ') | Should Be '-p P --output-format json -m gemini-2.5-pro --verbose'
    }
    It 'builds a gemini resume command when a session id exists' {
        $t = [pscustomobject](@{
            Name = 't'; Cli = 'gemini'; ProjectPath = 'C:\proj'
            Model = 'gemini-2.5-pro'; Effort = 'high'
            Prompt = 'do the thing'; ExtraArgs = @('--verbose')
        })
        $a = Get-CliArguments -Task $t -Mode Resume -SessionId 'g-1' -Prompt 'P'
        ($a -join ' ') | Should Be '--resume g-1 -p P --output-format json -m gemini-2.5-pro --verbose'
    }
    It 'omits model/effort args entirely when the task does not set them' {
        $t = [pscustomobject](@{
            Name = 't'; Cli = 'claude'; ProjectPath = 'C:\proj'
            Model = $null; Effort = $null; Prompt = 'do the thing'; ExtraArgs = @()
        })
        $a = Get-CliArguments -Task $t -Mode New -SessionId 's' -Prompt 'P'
        ($a -join ' ') | Should Be '-p --session-id s --output-format json P'
    }
}

