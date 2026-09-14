param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ReadyPath,
    [int]$HoldSeconds = 2
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\common.ps1')

$lock = Enter-RunnerLock -Root $Root
if (-not $lock.acquired) {
    [System.IO.File]::WriteAllText($ReadyPath, 'failed')
    exit 2
}
try {
    [System.IO.File]::WriteAllText($ReadyPath, 'ready')
    Start-Sleep -Seconds $HoldSeconds
} finally {
    Exit-RunnerLock -Root $Root
}
