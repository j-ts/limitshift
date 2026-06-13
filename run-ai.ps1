# DEPRECATED forwarder. run-ai.ps1 was renamed to limitshift.ps1.
# This stub forwards all arguments to limitshift.ps1 and preserves its exit code.
# It will be removed in the next release — use limitshift.ps1 directly.
[Console]::Error.WriteLine('run-ai.ps1 is deprecated; use limitshift.ps1')
& "$PSScriptRoot\limitshift.ps1" @args
exit $LASTEXITCODE
