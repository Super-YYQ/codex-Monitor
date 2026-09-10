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

    # =======================================================================
    # CQK-024: backoff must mean "never touch Codex", NOT "the runner does
    # nothing". Every scheduled tick inside a local backoff window still keeps
    # the lease alive, still retries a cluster marker whose push failed, and
    # still writes a heartbeat - and still reads zero quota.
    # =======================================================================

    function Clear-ClusterMarker {
        # Existing tests clear the cluster marker by pushing an already-expired
        # record directly; Set-GlobalBackoff itself now refuses to shorten a
        # live deadline (the marker is an absolute `until`, not a duration).
        param([string]$ClonePath)
        $b = Get-RemoteBranchBlob -RepoPath $ClonePath -Branch 'cqk/coordination' -PathInRepo 'coordination/backoff.json'
        if ($b.ok -and $b.reason -eq 'ok') {
            $past = @{ schema = 1; until = (Get-Date).AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:sszzz')
                       reason = 'cleared'; sourceOwnerId = 't'; setAt = 'x' }
            $null = Push-RepoBlobs -RepoPath $ClonePath -Branch 'cqk/coordination' `
                -Blobs @{ 'coordination/backoff.json' = (ConvertTo-Json -InputObject $past -Depth 6) } `
                -ParentCommit $b.commit -CommitMessage 'test: clear cluster marker' -MachineId 't'
        }
    }

    $machine2 = @{ machineId = 'GB-MACHINE-02'; label = 'GB-2' }
    $originPath = $repos.origin
    $originOff = Join-Path $ws 'origin.git.off'

    Start-TestGroup 'CQK-024: local backoff tick renews the lease, writes heartbeat, reads no quota'

    # keeper2 is the current lease holder and has done a real read (r4 above).
    $stateB0 = Read-JsonFile (Join-Path $keeperRoot2 'runtime\state.json')
    Assert-NotNull $stateB0.lastReadAt 'precondition: leader has a quota read on record'
    $leaseBefore = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    Set-Backoff -Root $keeperRoot2 -Minutes 60 -Reason '429'
    $env:CQK_MOCK_MODE = 'normal'
    $rA = Invoke-RunnerSub -KeeperRoot $keeperRoot2 -ConfigFile $cfgFile2
    Assert-Equal 0 $rA.exitCode "backoff tick exits 0 ($($rA.output))"
    $evtsA = Get-LogEventNames $keeperRoot2
    Assert-Contains $evtsA 'BACKOFF_SKIP' 'backoff tick logged BACKOFF_SKIP'
    $stateA = Read-JsonFile (Join-Path $keeperRoot2 'runtime\state.json')
    Assert-Equal "$($stateB0.lastReadAt)" "$($stateA.lastReadAt)" 'no quota read during local backoff'
    Assert-Equal 'BACKOFF' $stateA.role 'role recorded BACKOFF'
    Assert-Equal 'BACKOFF' $stateA.heartbeat.role 'heartbeat still written during backoff'
    $leaseAfter = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    Assert-True ("$($leaseAfter.content)" -match 'GB-MACHINE-02') 'lease still ours'
    Assert-True ("$($leaseAfter.content)" -ne "$($leaseBefore.content)") 'lease renewed during the backoff window (used to be left to expire)'
    Clear-Backoff -Root $keeperRoot2

    Start-TestGroup 'CQK-024: a marker whose push failed is persisted to runtime/pending-global-backoff.json'

    # Coordination unreachable: the bare origin moves away. The clone still
    # passes preflight and binding (its origin URL is unchanged), but every
    # fetch/push now fails - exactly the transient case that must not be lost.
    Rename-Item -LiteralPath $originPath -NewName 'origin.git.off'
    try {
        $setFail = Set-GlobalBackoff -Config $cfg -KeeperRoot $keeperRoot -Minutes 60 -Reason '429' -Machine $machine
        Assert-False $setFail.ok 'push failed while coordination is unreachable'
        Assert-Equal 'unreachable' $setFail.reason 'reason surfaced'
    } finally {
        Rename-Item -LiteralPath $originOff -NewName 'origin.git'
    }
    $pend = Get-PendingGlobalBackoff -Root $keeperRoot
    Assert-NotNull $pend 'marker queued for a later tick'
    if ($pend) {
        Assert-Equal 60 $pend.minutes 'queued minutes'
        Assert-Equal '429' $pend.reason 'queued reason'
        Assert-True ((Convert-BackoffUntilToTime ([string]$pend.until)) -gt (Get-Date)) 'queue keeps an absolute future deadline'
    }

    Start-TestGroup 'CQK-024: retrying the queue delivers the marker and keeps the original deadline'

    $untilBefore = [string]$pend.until
    $syncB = Sync-PendingGlobalBackoff -Config $cfg -KeeperRoot $keeperRoot -Machine $machine
    Assert-True $syncB.attempted 'remote write attempted'
    Assert-True $syncB.ok "pending marker delivered ($($syncB.reason))"
    Assert-Null (Get-PendingGlobalBackoff -Root $keeperRoot) 'queue cleared after delivery'
    $gbB = Get-GlobalBackoff -Config $cfg -KeeperRoot $keeperRoot
    Assert-True $gbB.active 'the fleet is protected by the late marker'
    Assert-Equal '429' $gbB.reason 'marker reason'
    Assert-Equal 'GB-MACHINE-01' $gbB.sourceOwnerId 'marker source'
    # The delivered deadline must be the one we queued, not a fresh now+N:
    # retrying a failed write may not lengthen the penalty the failure cost.
    Assert-True ($gbB.until -le (Convert-BackoffUntilToTime $untilBefore).AddMinutes(1)) 'retry preserved the original deadline'
    Clear-ClusterMarker -ClonePath $repos.clone

    Start-TestGroup 'CQK-024: a real backoff tick retries and publishes the pending marker'

    # End-to-end: local backoff active + queue present -> the tick must still
    # deliver the marker (this is precisely when the fleet needs it most).
    Set-Backoff -Root $keeperRoot2 -Minutes 60 -Reason '429'
    Rename-Item -LiteralPath $originPath -NewName 'origin.git.off'
    try {
        $null = Set-GlobalBackoff -Config $cfg -KeeperRoot $keeperRoot2 -Minutes 30 -Reason '429' -Machine $machine2
    } finally {
        Rename-Item -LiteralPath $originOff -NewName 'origin.git'
    }
    Assert-NotNull (Get-PendingGlobalBackoff -Root $keeperRoot2) 'queue present before the tick'
    $stateC0 = Read-JsonFile (Join-Path $keeperRoot2 'runtime\state.json')
    $env:CQK_MOCK_MODE = 'normal'
    $rC = Invoke-RunnerSub -KeeperRoot $keeperRoot2 -ConfigFile $cfgFile2
    Assert-Equal 0 $rC.exitCode "backoff tick with queue exits 0 ($($rC.output))"
    $evtsC = Get-LogEventNames $keeperRoot2
    Assert-Contains $evtsC 'GLOBAL_BACKOFF_PUBLISHED' 'tick published the queued marker'
    Assert-Contains $evtsC 'BACKOFF_SKIP' 'tick still skipped Codex'
    Assert-Null (Get-PendingGlobalBackoff -Root $keeperRoot2) 'queue drained'
    $stateC = Read-JsonFile (Join-Path $keeperRoot2 'runtime\state.json')
    Assert-Equal "$($stateC0.lastReadAt)" "$($stateC.lastReadAt)" 'no quota read on the publishing tick'
    $gbC = Get-GlobalBackoff -Config $cfg -KeeperRoot $keeperRoot2
    Assert-True $gbC.active 'cluster backoff now active for the whole fleet'
    Assert-Equal 'GB-MACHINE-02' $gbC.sourceOwnerId 'sourced from the backing-off machine'
    Clear-Backoff -Root $keeperRoot2
    Clear-ClusterMarker -ClonePath $repos.clone

    Start-TestGroup 'CQK-024: a normal (non-backoff) tick also drains the pending marker'

    # Maintenance is not a backoff-only favour: the retry sits before the
    # backoff branch so no tick path can leave the fleet uninformed.
    $keeperRootN = Join-Path $ws 'keeper-pending'
    New-Item -ItemType Directory -Path $keeperRootN -Force | Out-Null
    $cfgFileN = Join-Path $keeperRootN 'config.json'
    $null = Write-TestConfigFile $cfgFileN $cfg
    $null = Initialize-LogRepo -RepoPath $repos.clone -KeeperRoot $keeperRootN
    Write-JsonFileAtomic (Join-Path $keeperRootN 'runtime\machine.json') @{
        machineId = 'GB-MACHINE-09'; label = 'GB-9'; createdAt = '2026-09-08T00:00:00+08:00'
    }
    Set-PendingGlobalBackoff -Root $keeperRootN -Minutes 45 -Reason '429' `
        -UntilIso ((Get-Date).AddMinutes(45).ToString('yyyy-MM-ddTHH:mm:sszzz'))
    $env:CQK_MOCK_MODE = 'normal'
    $rN = Invoke-RunnerSub -KeeperRoot $keeperRootN -ConfigFile $cfgFileN
    Assert-Equal 0 $rN.exitCode "normal tick exits 0 ($($rN.output))"
    $evtsN = @(Get-LogEventNames $keeperRootN)
    Assert-Contains $evtsN 'GLOBAL_BACKOFF_PUBLISHED' 'normal tick published the queue'
    Assert-Null (Get-PendingGlobalBackoff -Root $keeperRootN) 'queue drained on a normal tick'
    $gbN = Get-GlobalBackoff -Config $cfg -KeeperRoot $keeperRootN
    Assert-True $gbN.active 'cluster marker live'
    Assert-Equal 'GB-MACHINE-09' $gbN.sourceOwnerId 'marker attributed to the queueing machine'
    Clear-ClusterMarker -ClonePath $repos.clone

    Start-TestGroup 'CQK-024: retry failure keeps the queue and is logged, never silent'

    Rename-Item -LiteralPath $originPath -NewName 'origin.git.off'
    try {
        $null = Set-GlobalBackoff -Config $cfg -KeeperRoot $keeperRoot -Minutes 60 -Reason '429' -Machine $machine
        $syncFail = Sync-PendingGlobalBackoff -Config $cfg -KeeperRoot $keeperRoot -Machine $machine
        Assert-True $syncFail.attempted 'retry attempted'
        Assert-False $syncFail.ok 'retry failed again'
        Assert-Equal 'unreachable' $syncFail.reason 'failure reason surfaced to the caller'
        Assert-NotNull (Get-PendingGlobalBackoff -Root $keeperRoot) 'queue survives a failed retry'
    } finally {
        Rename-Item -LiteralPath $originOff -NewName 'origin.git'
    }
    Clear-PendingGlobalBackoff -Root $keeperRoot

    Start-TestGroup 'CQK-024: a queued marker whose window has passed is dropped, not pushed late'

    Set-PendingGlobalBackoff -Root $keeperRoot -Minutes 60 -Reason '429' -UntilIso ((Get-Date).AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:sszzz'))
    $syncExp = Sync-PendingGlobalBackoff -Config $cfg -KeeperRoot $keeperRoot -Machine $machine
    Assert-False $syncExp.attempted 'no remote write for a stale window'
    Assert-Equal 'expired' $syncExp.reason 'stale window reported'
    Assert-Null (Get-PendingGlobalBackoff -Root $keeperRoot) 'stale queue dropped'
    Assert-False (Get-GlobalBackoff -Config $cfg -KeeperRoot $keeperRoot).active 'no backoff pushed for a window that already passed'

    Start-TestGroup 'CQK-024: the queue keeps the most demanding deadline'

    $t60 = (Get-Date).AddMinutes(60).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $t10 = (Get-Date).AddMinutes(10).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $t120 = (Get-Date).AddMinutes(120).ToString('yyyy-MM-ddTHH:mm:sszzz')
    Assert-True (Write-PendingGlobalBackoff -Root $keeperRoot -Minutes 60 -Reason '429' -UntilIso $t60) 'first queue write'
    Assert-False (Write-PendingGlobalBackoff -Root $keeperRoot -Minutes 10 -Reason 'network_error' -UntilIso $t10) 'shorter window does not downgrade the queue'
    $pendKeep = Get-PendingGlobalBackoff -Root $keeperRoot
    Assert-Equal $t60 "$($pendKeep.until)" 'original deadline kept'
    Assert-True (Write-PendingGlobalBackoff -Root $keeperRoot -Minutes 120 -Reason 'auth_error' -UntilIso $t120) 'longer window upgrades the queue'
    Assert-Equal $t120 "$((Get-PendingGlobalBackoff -Root $keeperRoot).until)" 'more demanding deadline stored'
    Clear-PendingGlobalBackoff -Root $keeperRoot
    Assert-Null (Get-PendingGlobalBackoff -Root $keeperRoot) 'queue cleared'

    Start-TestGroup 'CQK-024: coordination disabled drops the queue instead of retrying forever'

    Set-PendingGlobalBackoff -Root $keeperRoot -Minutes 60 -Reason '429' -UntilIso $t60
    $syncDis = Sync-PendingGlobalBackoff -Config $cfgLocal -KeeperRoot $keeperRoot -Machine $machine
    Assert-False $syncDis.attempted 'no attempt without coordination'
    Assert-Equal 'disabled' $syncDis.reason 'reported disabled'
    Assert-Null (Get-PendingGlobalBackoff -Root $keeperRoot) 'queue dropped'
    Set-PendingGlobalBackoff -Root $keeperRoot -Minutes 60 -Reason '429' -UntilIso $t60
    $null = Set-GlobalBackoff -Config $cfgLocal -KeeperRoot $keeperRoot -Minutes 60 -Reason '429' -Machine $machine
    Assert-Null (Get-PendingGlobalBackoff -Root $keeperRoot) 'Set-GlobalBackoff also drops the queue when disabled'

    Start-TestGroup 'CQK-024: unreachable coordination during backoff stays a safe local backoff (AutoAnchor fail closed)'

    # autoAnchor must be a complete hashtable: New-TestConfig merges one level
    # deep, so a partial override would drop prompt/maxPerDay and fail validation.
    $cfgAa = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $true; repoPath = $repos.clone; branch = 'cqk/coordination' }; historySync = @{ enabled = $true; push = $true; branch = 'cqk/history'; eventsOnly = $true } }
        codex  = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60 } }
    }
    $cfgFileAa = Join-Path $keeperRoot2 'config-aa.json'
    $null = Write-TestConfigFile $cfgFileAa $cfgAa
    Set-Backoff -Root $keeperRoot2 -Minutes 60 -Reason '429'
    $stateG0 = Read-JsonFile (Join-Path $keeperRoot2 'runtime\state.json')
    $evtsG0 = @(Get-LogEventNames $keeperRoot2).Count
    Rename-Item -LiteralPath $originPath -NewName 'origin.git.off'
    try {
        $env:CQK_MOCK_MODE = 'normal'
        $rG = Invoke-RunnerSub -KeeperRoot $keeperRoot2 -ConfigFile $cfgFileAa
        Assert-Equal 0 $rG.exitCode "coordination-unreachable backoff tick exits 0 ($($rG.output))"
    } finally {
        Rename-Item -LiteralPath $originOff -NewName 'origin.git'
    }
    $evtsNew = @( @(Get-LogEventNames $keeperRoot2) | Select-Object -Skip $evtsG0 )
    Assert-Contains $evtsNew 'BACKOFF_SKIP' 'tick still skipped Codex'
    $anchorEvts = @($evtsNew | Where-Object { "$_" -match '^ANCHOR' })
    Assert-Equal 0 $anchorEvts.Count 'AutoAnchor never reached during backoff, even with coordination down (fail closed)'
    $stateG = Read-JsonFile (Join-Path $keeperRoot2 'runtime\state.json')
    Assert-Equal "$($stateG0.lastReadAt)" "$($stateG.lastReadAt)" 'no quota read with coordination unreachable'
    Assert-Equal 'BACKOFF' $stateG.heartbeat.role 'heartbeat maintained'
    Assert-Null (Get-PendingGlobalBackoff -Root $keeperRoot2) 'no queue invented out of a tick with nothing pending'
    Clear-Backoff -Root $keeperRoot2
} finally {
    Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "global-backoff.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
