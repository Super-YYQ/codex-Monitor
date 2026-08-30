# Codex Quota Keeper - one-time setup of the dedicated log repository (CQK-011).
# Writes the repository marker (.codex-quota-keeper-repository.json), binds it to
# this keeper installation (repoId + origin fingerprint in runtime/log-repo.json).
# Every later push verifies this binding and refuses misconfigured repositories.

param(
    [string]$KeeperRoot = '',
    [string]$RepoPath = ''
)

$scriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')

if (-not $KeeperRoot) { $KeeperRoot = Get-KeeperRoot }
if (-not $RepoPath) {
    $loaded = Load-Config (Get-ConfigPath $KeeperRoot)
    if ($loaded.config) { $RepoPath = (Get-CoordinationConfig $loaded.config).repoPath }
}

$result = Initialize-LogRepo -RepoPath $RepoPath -KeeperRoot $KeeperRoot
Write-Host 'Codex Quota Keeper - Setup Log Repository'
Write-Host '========================================'
if ($result.ok) {
    Write-Host "  Bound log repo   : $([System.IO.Path]::GetFullPath($RepoPath))"
    Write-Host "  repoId           : $($result.repoId)"
    Write-Host "  Marker written   : $($result.markerPath)"
    Write-Host '  Allowed branches : cqk/coordination, cqk/history'
} else {
    foreach ($i in $result.issues) { Write-Host "  [ISSUE] $i" -ForegroundColor Yellow }
    Write-Host '  Log repo NOT bound.' -ForegroundColor Red
}
exit $(if ($result.ok) { 0 } else { 1 })
