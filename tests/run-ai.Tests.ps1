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
