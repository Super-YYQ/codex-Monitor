# Concurrency & fault-injection tests (audit plan v1.0 section 14.2, CQK-015/016).
# Two simulated machines against one local bare origin:
#   - simultaneous leader acquisition: exactly one winner
#   - simultaneous AutoAnchor claim of the same reset: exactly one CLAIMED
#   - claim succeeded but lease expired before execution: no model call
#   - exec succeeded but completion push failed: other machines never retry
#   - history push race: both machines' immutable event files survive

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')
. (Join-Path $scriptDir 'logger.ps1')
. (Join-Path $scriptDir 'leader-lease.ps1')
. (Join-Path $scriptDir 'state-machine.ps1')
. (Join-Path $scriptDir 'auto-anchor.ps1')

$mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'
$now = Get-Date

function New-Machine { param([string]$Id) @{ machineId = $Id; label = $Id } }
function New-MachineKeeper {
    param([string]$Workspace, [string]$ClonePath, [string]$MachineId)
    $keeperRoot = Join-Path $Workspace $MachineId
    New-Item -ItemType Directory -Path $keeperRoot -Force | Out-Null
    $cfg = New-TestConfig @{
        mode  = 'AutoAnchor'
        codex = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 1 } }
        github = @{ coordination = @{ enabled = $true; repoPath = $ClonePath; branch = 'cqk/coordination' }; historySync = @{ enabled = $true; push = $true; branch = 'cqk/history'; eventsOnly = $true } }
    }
    return @{ root = $keeperRoot; config = $cfg; machine = (New-Machine $MachineId) }
}

function Clear-AnchorEvents {
    # Removes all remote claim files so later scenarios start from a clean tree.
    param([string]$ClonePath)
    $listing = Invoke-TestGit -RepoPath $ClonePath -ArgumentList @('ls-tree', '-r', '--name-only', 'origin/cqk/coordination')
    if (-not $listing.ok) { return }
    $eventFiles = @(($listing.stdout -split "`n") | Where-Object { $_ -match '^coordination/events/' })
    if (@($eventFiles).Count -eq 0) { return }
    $blob = Get-RemoteBranchBlob -RepoPath $ClonePath -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    $parent = $null
    if ($blob.commit) { $parent = $blob.commit }
    $null = Push-RepoBlobs -RepoPath $ClonePath -Branch 'cqk/coordination' -Blobs @{} `
        -RemovePaths $eventFiles -ParentCommit $parent -CommitMessage 'anchor: clear claims (concurrency test)' -MachineId 't'
}

function Get-EventRecord {
    # Reads the remote claim record for an event id (or $null record).
    param([hashtable]$Config, [string]$KeeperRoot, [string]$EventId)
    $st = Get-AnchorEventState -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId
    if ($st.exists) { return $st.record }
    return $null
}

$ws = New-TestWorkspace
try {
    $repos = New-TestOriginAndClone -Workspace $ws
    $mA = New-MachineKeeper -Workspace $ws -ClonePath $repos.clone -MachineId 'CONC-A'
    $mB = New-MachineKeeper -Workspace $ws -ClonePath $repos.clone -MachineId 'CONC-B'
    $null = Initialize-LogRepo -RepoPath $repos.clone -KeeperRoot $mA.root
    $null = Initialize-LogRepo -RepoPath $repos.clone -KeeperRoot $mB.root

    Start-TestGroup 'concurrency: two machines race the leader lease, one winner'

    $remote0 = Get-RemoteLease -Config $mA.config -KeeperRoot $mA.root
    $raceParent = $remote0.commit
    $leaseA = New-LeaseRecord -OwnerId 'CONC-A' -OwnerLabel 'A' -Mode 'MonitorOnly' -TtlMinutes 45
    $leaseB = New-LeaseRecord -OwnerId 'CONC-B' -OwnerLabel 'B' -Mode 'MonitorOnly' -TtlMinutes 45
    $pushA = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/lease.json' = (ConvertTo-Json -InputObject $leaseA -Depth 6) } `
        -ParentCommit $raceParent -CommitMessage 'lease: A' -MachineId 'CONC-A'
    $pushB = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/lease.json' = (ConvertTo-Json -InputObject $leaseB -Depth 6) } `
        -ParentCommit $raceParent -CommitMessage 'lease: B' -MachineId 'CONC-B'
    Assert-True ($pushA.ok -xor $pushB.ok) 'exactly one lease push wins'
    $final = Get-RemoteLease -Config $mA.config -KeeperRoot $mA.root
    $winner = if ($pushA.ok) { 'CONC-A' } else { 'CONC-B' }
    Assert-Equal $winner $final.lease.ownerId 'remote lease held by race winner'
    # expire the lease so later scenarios can proceed
    $blob = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    $stale = @{ schema = 1; ownerId = 'GHOST'; ownerLabel = 'ghost'
                acquiredAt = $now.AddMinutes(-120).ToString('yyyy-MM-ddTHH:mm:sszzz')
                renewedAt = $now.AddMinutes(-120).ToString('yyyy-MM-ddTHH:mm:sszzz')
                expiresAt = $now.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz')
                mode = 'MonitorOnly'; version = '0.9.0' }
    $null = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/lease.json' = (ConvertTo-Json -InputObject $stale -Depth 6) } `
        -ParentCommit $blob.commit -CommitMessage 'lease: expire' -MachineId 't'

    Start-TestGroup 'concurrency: simultaneous anchor claim of one reset, one winner (CQK-015)'

    $eventId = Get-Sha256Hex 'codex-default|primary|300|1788062400|reset'
    $claimA = Claim-AnchorEvent -Config $mA.config -KeeperRoot $mA.root -EventId $eventId -Machine $mA.machine -ClaimMinutes 5
    $claimB = Claim-AnchorEvent -Config $mB.config -KeeperRoot $mB.root -EventId $eventId -Machine $mB.machine -ClaimMinutes 5
    Assert-True ($claimA.ok -xor $claimB.ok) 'exactly one machine claims the event'
    $claimWinner = if ($claimA.ok) { 'CONC-A' } else { 'CONC-B' }
    $record = Get-EventRecord -Config $mA.config -KeeperRoot $mA.root -EventId $eventId
    Assert-NotNull $record 'claim record exists'
    Assert-Equal 'CLAIMED' $record.state 'state CLAIMED'
    Assert-Equal $claimWinner $record.ownerId 'claim owner is the winner'
    Assert-Equal $winner $record.ownerId 'lease winner and claim winner are the same machine (leader-gated)'

    Start-TestGroup 'concurrency: lease expires after claim, before execution -> no model call (CQK-016)'

    # simulate: the lease changed hands to ANOTHER machine after the claim was made
    $blob2 = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    $other = if ($winner -eq 'CONC-A') { 'CONC-B' } else { 'CONC-A' }
    $otherLease = New-LeaseRecord -OwnerId $other -OwnerLabel $other -Mode 'AutoAnchor' -TtlMinutes 45
    $null = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/lease.json' = (ConvertTo-Json -InputObject $otherLease -Depth 6) } `
        -ParentCommit $blob2.commit -CommitMessage 'lease: taken over after claim' -MachineId $other
    # the claim owner revalidates before executing: it must fail and mark EXPIRED
    $revalid = Test-LeaseRevalidation -Config $mA.config -KeeperRoot $mA.root -Machine (New-Machine $winner) -RequiredMinutes 2
    Assert-False $revalid.ok 'lease revalidation fails after lease expiry'
    $mark = Push-AnchorEventState -Config $mA.config -KeeperRoot $mA.root -EventId $eventId `
        -Record @{ schema = 1; eventId = $eventId; state = 'EXPIRED'; ownerId = $winner
                   claimedAt = Get-IsoTimestamp; claimExpiresAt = Get-IsoTimestamp; completedAt = $null
                   result = "lease revalidation failed: $($revalid.reason)" } -Machine (New-Machine $winner)
    Assert-True $mark.ok 'event marked EXPIRED'
    $rec2 = Get-EventRecord -Config $mA.config -KeeperRoot $mA.root -EventId $eventId
    Assert-Equal 'EXPIRED' $rec2.state 'uncertain outcome recorded as EXPIRED'
    # per audit plan: an EXPIRED claim must block every machine (uncertain -> no retry)
    $claimC = Claim-AnchorEvent -Config $mB.config -KeeperRoot $mB.root -EventId $eventId -Machine $mB.machine -ClaimMinutes 5
    Assert-False $claimC.ok 'EXPIRED claim blocks retry (at-most-once)'

    Start-TestGroup 'concurrency: exec ok but completion push failed -> no retry by others (CQK-016)'

    # fresh deterministic reset on a clean coordination tree
    Clear-AnchorEvents -ClonePath $repos.clone
    $claimA2 = Claim-AnchorEvent -Config $mA.config -KeeperRoot $mA.root -EventId $eventId -Machine $mA.machine -ClaimMinutes 5
    Assert-True $claimA2.ok 'claim acquired on clean tree'
    # completion push fails (binding broken by tampering the marker)
    $markerPath = Join-Path $repos.clone '.codex-quota-keeper-repository.json'
    $origMarker = [System.IO.File]::ReadAllText($markerPath)
    [System.IO.File]::WriteAllText($markerPath, '{"schema":1,"repoId":"tampered","createdFor":"codex-quota-keeper"}', (New-Object System.Text.UTF8Encoding($false)))
    $complete = Push-AnchorEventState -Config $mA.config -KeeperRoot $mA.root -EventId $eventId `
        -Record @{ schema = 1; eventId = $eventId; state = 'COMPLETED'; ownerId = 'CONC-A'
                   claimedAt = Get-IsoTimestamp; claimExpiresAt = $null; completedAt = Get-IsoTimestamp
                   result = $null } -Machine $mA.machine
    Assert-False $complete.ok 'completion push fails under broken binding'
    [System.IO.File]::WriteAllText($markerPath, $origMarker, (New-Object System.Text.UTF8Encoding($false)))
    # the event is still CLAIMED on the remote: another machine must NOT retry
    $rec3 = Get-EventRecord -Config $mB.config -KeeperRoot $mB.root -EventId $eventId
    Assert-Equal 'CLAIMED' $rec3.state 'event remains CLAIMED after failed completion'
    $claimB2 = Claim-AnchorEvent -Config $mB.config -KeeperRoot $mB.root -EventId $eventId -Machine $mB.machine -ClaimMinutes 5
    Assert-False $claimB2.ok 'other machine denied while CLAIMED (uncertain outcome, no retry)'

    Start-TestGroup 'concurrency: history push race, both machines immutable files survive'

    # machine A and machine B each write an outbox event and push sequentially;
    # both files must exist on the history branch afterwards.
    $null = Write-OutboxEvent -Root $mA.root -Record @{ eventId = 'race-a'; event = 'WINDOW_RESET_OBSERVED'; recordedAt = '2026-08-30T10:00:00+08:00' } -MachineId 'CONC-A' -When $now
    $null = Write-OutboxEvent -Root $mB.root -Record @{ eventId = 'race-b'; event = 'WINDOW_RESET_OBSERVED'; recordedAt = '2026-08-30T10:01:00+08:00' } -MachineId 'CONC-B' -When $now
    $sA = Sync-OutboxToGitHub -Config $mA.config -KeeperRoot $mA.root -Machine $mA.machine -CommitMessage 'quota: reset observed'
    Assert-True $sA.ok "machine A history push ok ($($sA.reason))"
    $sB = Sync-OutboxToGitHub -Config $mB.config -KeeperRoot $mB.root -Machine $mB.machine -CommitMessage 'quota: reset observed'
    Assert-True $sB.ok "machine B history push ok ($($sB.reason))"
    $paths = Invoke-TestGit -RepoPath $repos.clone -ArgumentList @('ls-tree', '-r', '--name-only', 'origin/cqk/history')
    $lineList = @(($paths.stdout -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $hasA = @($lineList | Where-Object { $_ -match '^history/.+/CONC-A/.+_race-a\.json$' }).Count -ge 1
    $hasB = @($lineList | Where-Object { $_ -match '^history/.+/CONC-B/.+_race-b\.json$' }).Count -ge 1
    Assert-True $hasA "machine A's immutable event survives (race-a)"
    Assert-True $hasB "machine B's immutable event survives (race-b)"
    $outA = @(Get-ChildItem (Get-OutboxDir $mA.root) -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $outB = @(Get-ChildItem (Get-OutboxDir $mB.root) -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-Equal 0 @($outA).Count 'machine A outbox drained'
    Assert-Equal 0 @($outB).Count 'machine B outbox drained'
} finally {
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "concurrency.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
