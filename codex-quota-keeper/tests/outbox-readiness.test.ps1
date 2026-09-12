# Tests persistence around a mocked Git boundary. No git push is executed.
$testsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $testsDir 'test-helper.ps1')
. (Join-Path (Split-Path -Parent $testsDir) 'scripts/github-sync.ps1')
function Test-GitAvailable { return $true }
function Test-LogRepoBinding { return $null }
function Get-RemoteBranchBlob { return @{ ok = $true; commit = $null } }
function Push-RepoBlobs {
    param($RepoPath, $Branch, $Blobs, $ParentCommit, $CommitMessage, $MachineId)
    $script:capturedBlobs = $Blobs
    return @{ ok = $script:pushSucceeds; reason = 'simulated' }
}
$ws = New-TestWorkspace
try {
    $cfg = New-TestConfig @{ github = @{ coordination = @{ enabled = $false; repoPath = $ws }; historySync = @{ enabled = $true; push = $true } } }
    $poison = 'sk-' + 'synthetic-for-outbox-12345678'
    $pending = Get-OutboxDir $ws
    Ensure-Directory $pending | Out-Null
    $good = Join-Path $pending 'valid.json'
    $bad = Join-Path $pending 'corrupt.json'
    Write-JsonFileAtomic $good @{ event = 'ANCHOR_ABORTED'; token = $poison; machineLabel = 'private'; anchor = @{ reason = $poison; model = 'mock-model-alpha'; effectiveModel = 'mock-model-alpha' } }
    [IO.File]::WriteAllText($bad, '{broken')
    $script:pushSucceeds = $false
    $r = Sync-OutboxToGitHub -Config $cfg -KeeperRoot $ws -Machine @{ machineId = 'm' }
    Assert-False $r.ok 'failed write reported'
    Assert-True (Test-Path $good) 'failure keeps valid pending record'
    Assert-True (Test-Path $bad) 'failure keeps corrupt record'
    $firstPaths = @($script:capturedBlobs.Keys)
    $script:pushSucceeds = $true
    $r = Sync-OutboxToGitHub -Config $cfg -KeeperRoot $ws -Machine @{ machineId = 'm' }
    Assert-True $r.ok 'successful write reported'
    Assert-False (Test-Path $good) 'success drains included record'
    Assert-True (Test-Path $bad) 'success preserves corrupt record for diagnosis'
    Assert-Equal ($firstPaths -join ',') (@($script:capturedBlobs.Keys) -join ',') 'legacy retry uses stable path'
    $text = @($script:capturedBlobs.Values) -join ''
    Assert-False ($text.Contains($poison)) 'legacy record secrets are removed before sync'
    Assert-False ($text.Contains('private')) 'legacy machine label respects current opt-out'
    $record = ConvertFrom-JsonSafe $text
    Assert-Equal 'mock-model-alpha' $record.anchor.model 'legacy model alias survives projection'
    Assert-Equal 'mock-model-alpha' $record.anchor.effectiveModel 'effective model survives projection'
    $sync = Read-JsonFile (Get-SyncStatePath $ws)
    Assert-Equal 1 @($sync.sent).Count 'only included records are marked sent'
} finally { Remove-TestWorkspace $ws }
$r = Get-TestResult
Write-Host "outbox-readiness: $($r.checks) checks, $($r.failures) failures"
exit ([int]($r.failures -gt 0))
