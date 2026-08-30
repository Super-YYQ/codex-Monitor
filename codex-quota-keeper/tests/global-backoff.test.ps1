# Tests for global-backoff.ps1 (CQK-008): cluster-level backoff marker on the
# coordination branch, leader skip during backoff, no bypass via lease takeover.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')
. (Join-Path $scriptDir 'global-backoff.ps1')

$pwsh = (Get-Process -Id $PID).Path
$runnerPath = Join-Path $scriptDir 'runner.ps1'
$mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'
$now = Get-Date

function Invoke-RunnerSub {
    param([string]$KeeperRoot, [string]$ConfigFile)
    $out = & $pwsh -NoProfile -ExecutionPolicy Bypass -File $runnerPath -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile 2>&1
    return @{ exitCode = $LASTEXITCODE; output = ($out | Out-String) }
}

function Get-LogEventNames {
    param([string]$KeeperRoot)
    $names = @()
    Get-ChildItem -LiteralPath (Join-Path $KeeperRoot 'runtime\logs') -Filter 'keeper-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $names += @(([System.IO.File]::ReadAllLines($_.FullName)) | ForEach-Object { (ConvertFrom-JsonSafe $_).event })
    }
    return $names
}

Start-TestGroup 'global backoff: marker push and read'

$ws = New-TestWorkspace
try {
    $repos = New-TestOriginAndClone -Workspace $ws
    $keeperRoot = Join-Path $ws 'keeper'
    New-Item -ItemType Directory -Path $keeperRoot -Force | Out-Null
    $cfgFile = Join-Path $keeperRoot 'config.json'
    $cfg = New-TestConfig @{
        github = @{ coordination = @{ enabled = $true; repoPath = $repos.clone; branch = 'cqk/coordination' }; historySync = @{ enabled = $true; push = $true; branch = 'cqk/history'; eventsOnly = $true } }
        codex  = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = $false }
    }
    $null = Write-TestConfigFile $cfgFile $cfg
    $null = Initialize-LogRepo -RepoPath $repos.clone -KeeperRoot $keeperRoot
    $machine = @{ machineId = 'GB-MACHINE-01'; label = 'GB-1' }

    $gb0 = Get-GlobalBackoff -Config $cfg -KeeperRoot $keeperRoot
    Assert-True $gb0.reachable 'coordination reachable'
    Assert-False $gb0.active 'no backoff initially'

    $set = Set-GlobalBackoff -Config $cfg -KeeperRoot $keeperRoot -Minutes 60 -Reason '429' -Machine $machine
    Assert-True $set.ok "global backoff pushed ($($set.reason))"
    $gb1 = Get-GlobalBackoff -Config $cfg -KeeperRoot $keeperRoot
    Assert-True $gb1.active 'global backoff active'
    Assert-Equal '429' $gb1.reason 'reason surfaced'
    Assert-Equal 'GB-MACHINE-01' $gb1.sourceOwnerId 'source owner surfaced'

    # expired record -> inactive
    $coord = Get-CoordinationConfig $cfg
    $blob = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo 'coordination/backoff.json'
    $past = @{ schema = 1; until = $now.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:sszzz'); reason = 'old'; sourceOwnerId = 'X'; setAt = 'x' }
    $null = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/backoff.json' = (ConvertTo-Json -InputObject $past -Depth 6) } `
        -ParentCommit $blob.commit -CommitMessage 'keeper: backoff expire test' -MachineId 't'
    $gb2 = Get-GlobalBackoff -Config $cfg -KeeperRoot $keeperRoot
    Assert-False $gb2.active 'expired global backoff inactive'

    Start-TestGroup 'global backoff: leader skips quota read during cluster backoff'

    $env:CQK_MOCK_MODE = 'normal'
    $r1 = Invoke-RunnerSub -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r1.exitCode 'baseline run ok'
    Clear-Backoff $keeperRoot
    $state1 = Read-JsonFile (Join-Path $keeperRoot 'runtime\state.json')
    Assert-NotNull $state1.lastReadAt 'baseline read happened'

    # 429 from a leader pushes a global backoff
    $env:CQK_MOCK_MODE = 'rate-limit'
    $r2 = Invoke-RunnerSub -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r2.exitCode '429 run exits 0'
    Clear-Backoff $keeperRoot   # clear LOCAL backoff only; global must still block
    $gb3 = Get-GlobalBackoff -Config $cfg -KeeperRoot $keeperRoot
    Assert-True $gb3.active 'global backoff active after 429'

    Start-TestGroup 'global backoff: no bypass via lease takeover'

    # A second machine takes over the expired lease; the cluster backoff must stop it.
    $keeperRoot2 = Join-Path $ws 'keeper2'
    New-Item -ItemType Directory -Path $keeperRoot2 -Force | Out-Null
    $cfgFile2 = Join-Path $keeperRoot2 'config.json'
    $null = Write-TestConfigFile $cfgFile2 $cfg
    $null = Initialize-LogRepo -RepoPath $repos.clone -KeeperRoot $keeperRoot2
    Write-JsonFileAtomic (Join-Path $keeperRoot2 'runtime\machine.json') @{
        machineId = 'GB-MACHINE-02'; label = 'GB-2'; createdAt = '2026-08-30T00:00:00+08:00'
    }
    # expire the lease so machine 2 can take over
    $blob2 = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    $stale = @{ schema = 1; ownerId = 'GB-MACHINE-01'; ownerLabel = 'GB-1'
                acquiredAt = $now.AddMinutes(-120).ToString('yyyy-MM-ddTHH:mm:sszzz')
                renewedAt = $now.AddMinutes(-120).ToString('yyyy-MM-ddTHH:mm:sszzz')
                expiresAt = $now.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz')
                mode = 'MonitorOnly'; version = '0.9.0' }
    $null = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/lease.json' = (ConvertTo-Json -InputObject $stale -Depth 6) } `
        -ParentCommit $blob2.commit -CommitMessage 'lease: expire' -MachineId 't'

    $env:CQK_MOCK_MODE = 'normal'
    $r3 = Invoke-RunnerSub -KeeperRoot $keeperRoot2 -ConfigFile $cfgFile2
    Assert-Equal 0 $r3.exitCode 'takeover run exits 0'
    $evts = Get-LogEventNames $keeperRoot2
    Assert-Contains $evts 'GLOBAL_BACKOFF_SKIP' 'takeover machine honored the cluster backoff'
    $state2 = Read-JsonFile (Join-Path $keeperRoot2 'runtime\state.json')
    Assert-Null $state2.lastReadAt 'takeover machine did NOT read quota during global backoff'

    Start-TestGroup 'global backoff: leader renews lease while skipping'

    $lease = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    Assert-True ("$($lease.content)" -match 'GB-MACHINE-02') 'takeover machine holds the lease (renewed during skip)'

    Start-TestGroup 'global backoff: cleared -> normal operation resumes'

    $blob3 = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo 'coordination/backoff.json'
    $cleared = @{ schema = 1; until = $now.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:sszzz'); reason = 'cleared'; sourceOwnerId = 'X'; setAt = 'x' }
    $null = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/backoff.json' = (ConvertTo-Json -InputObject $cleared -Depth 6) } `
        -ParentCommit $blob3.commit -CommitMessage 'keeper: backoff cleared' -MachineId 't'
    $r4 = Invoke-RunnerSub -KeeperRoot $keeperRoot2 -ConfigFile $cfgFile2
    Assert-Equal 0 $r4.exitCode 'post-backoff run ok'
    $state4 = Read-JsonFile (Join-Path $keeperRoot2 'runtime\state.json')
    Assert-NotNull $state4.lastReadAt 'quota read resumed after global backoff expired'

    Start-TestGroup 'global backoff: coordination disabled -> inert'

    $cfgLocal = New-TestConfig @{ github = @{ coordination = @{ enabled = $false } } }
    $gbLocal = Get-GlobalBackoff -Config $cfgLocal -KeeperRoot $keeperRoot
    Assert-True $gbLocal.reachable 'reported reachable (nothing to check)'
    Assert-False $gbLocal.active 'inactive without coordination'
    $setLocal = Set-GlobalBackoff -Config $cfgLocal -KeeperRoot $keeperRoot -Minutes 60 -Reason '429' -Machine $machine
    Assert-Equal 'disabled' $setLocal.reason 'no push without coordination'
} finally {
    Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "global-backoff.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
