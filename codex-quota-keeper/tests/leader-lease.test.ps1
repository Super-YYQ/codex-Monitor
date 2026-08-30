# Tests for leader-lease.ps1 against local bare origin repos:
# acquisition, passive yield, TTL expiry takeover, takeover disabled, CAS race,
# renewal preserving acquiredAt, fail-closed on unreachable remote, local-only mode.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')
. (Join-Path $scriptDir 'leader-lease.ps1')

$now = Get-Date

function New-TestMachine {
    param([string]$Id, [string]$Label)
    return @{ machineId = $Id; label = $Label }
}

function New-TestKeeper {
    param([string]$Workspace, [string]$ClonePath)
    $keeperRoot = Join-Path $Workspace 'keeper'
    New-Item -ItemType Directory -Path $keeperRoot -Force | Out-Null
    $cfg = New-TestConfig @{ github = @{ coordination = @{ enabled = $true; repoPath = $ClonePath; branch = 'cqk/coordination' }; historySync = @{ enabled = $true; push = $true; branch = 'cqk/history' } } }
    return @{ root = $keeperRoot; config = $cfg }
}

Start-TestGroup 'lease: lease active check with grace window'

$lease = New-LeaseRecord -OwnerId 'A' -OwnerLabel 'PC-A' -Mode 'MonitorOnly' -TtlMinutes 45
Assert-True (Test-LeaseActive -Lease $lease -Now $now -GraceMinutes 5) 'fresh lease active'
$expiredLease = @{ schema = 1; ownerId = 'A'; expiresAt = $now.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz') }
Assert-False (Test-LeaseActive -Lease $expiredLease -Now $now -GraceMinutes 5) 'lease expired beyond grace'
$graceLease = @{ schema = 1; ownerId = 'A'; expiresAt = $now.AddMinutes(-2).ToString('yyyy-MM-ddTHH:mm:sszzz') }
Assert-True (Test-LeaseActive -Lease $graceLease -Now $now -GraceMinutes 5) 'expired within grace still active'
Assert-False (Test-LeaseActive -Lease $null -Now $now -GraceMinutes 5) 'null lease inactive'
Assert-False (Test-LeaseActive -Lease @{ expiresAt = 'garbage' } -Now $now -GraceMinutes 5) 'unparseable expiry inactive'

Start-TestGroup 'lease: acquisition, passive yield, renewal, takeover'

$ws = New-TestWorkspace
try {
    $repos = New-TestOriginAndClone -Workspace $ws
    $keeper = New-TestKeeper -Workspace $ws -ClonePath $repos.clone
    $machineA = New-TestMachine 'AAAAAAAA-0000-0000-0000-000000000001' 'PC-A'
    $machineB = New-TestMachine 'BBBBBBBB-0000-0000-0000-000000000002' 'PC-B'

    $eA = Invoke-LeaderElection -Config $keeper.config -KeeperRoot $keeper.root -Machine $machineA -Now $now
    Assert-Equal 'LEADER' $eA.role 'first machine becomes leader'
    Assert-Equal 'lease acquired' $eA.reason 'acquired reason'
    Assert-NotNull $eA.lease 'lease record returned'

    $eB = Invoke-LeaderElection -Config $keeper.config -KeeperRoot $keeper.root -Machine $machineB -Now $now
    Assert-Equal 'PASSIVE' $eB.role 'second machine yields'
    Assert-Equal $machineA.machineId $eB.otherOwner 'passive sees leader owner'

    $eA2 = Invoke-LeaderElection -Config $keeper.config -KeeperRoot $keeper.root -Machine $machineA -Now $now.AddMinutes(1)
    Assert-Equal 'LEADER' $eA2.role 'owner renewal stays leader'
    Assert-Equal 'lease renewed' $eA2.reason 'renewal reason'
    Assert-Equal $eA.lease.acquiredAt $eA2.lease.acquiredAt 'acquiredAt preserved on renewal'

    Start-TestGroup 'lease: TTL expiry takeover by other machine'

    $later = $now.AddMinutes(60)   # beyond TTL 45 + grace 5
    $eA3 = Invoke-LeaderElection -Config $keeper.config -KeeperRoot $keeper.root -Machine $machineA -Now $later
    Assert-Equal 'LEADER' $eA3.role 'old owner reacquires after own expiry'

    # Craft an expired lease owned by A, then B must take over (takeoverOnExpiry=true)
    $staleLease = @{
        schema = 1; ownerId = $machineA.machineId; ownerLabel = 'PC-A'
        acquiredAt = $now.AddMinutes(-100).ToString('yyyy-MM-ddTHH:mm:sszzz')
        renewedAt = $now.AddMinutes(-100).ToString('yyyy-MM-ddTHH:mm:sszzz')
        expiresAt = $now.AddMinutes(-30).ToString('yyyy-MM-ddTHH:mm:sszzz')
        mode = 'MonitorOnly'; version = '0.1.0'
    }
    $cfgNoTakeover = New-TestConfig @{
        leader = @{ takeoverOnExpiry = $false }
        github = @{ coordination = @{ enabled = $true; repoPath = $repos.clone; branch = 'cqk/coordination' }; historySync = @{ enabled = $true; push = $true; branch = 'cqk/history' } }
    }
    $remote = Get-RemoteLease -Config $keeper.config -KeeperRoot $keeper.root
    $push = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/lease.json' = (ConvertTo-Json -InputObject $staleLease -Depth 6) } `
        -ParentCommit $remote.commit -CommitMessage 'lease: seed stale' -MachineId 'seed'
    Assert-True $push.ok "stale lease seeded ($($push.reason))"

    $eB2 = Invoke-LeaderElection -Config $keeper.config -KeeperRoot $keeper.root -Machine $machineB -Now $now
    Assert-Equal 'LEADER' $eB2.role 'takeover after expiry allowed by default'

    # Now disable takeover: seed stale A lease again, B must stay passive
    $remote2 = Get-RemoteLease -Config $keeper.config -KeeperRoot $keeper.root
    $push2 = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/lease.json' = (ConvertTo-Json -InputObject $staleLease -Depth 6) } `
        -ParentCommit $remote2.commit -CommitMessage 'lease: seed stale 2' -MachineId 'seed'
    Assert-True $push2.ok 'stale lease re-seeded'
    $eB3 = Invoke-LeaderElection -Config $cfgNoTakeover -KeeperRoot $keeper.root -Machine $machineB -Now $now
    Assert-Equal 'PASSIVE' $eB3.role 'takeover disabled keeps passive'

    Start-TestGroup 'lease: CAS race -> exactly one winner'

    $remote3 = Get-RemoteLease -Config $keeper.config -KeeperRoot $keeper.root
    $parent = $remote3.commit
    $leaseX = New-LeaseRecord -OwnerId 'XXXX-1' -OwnerLabel 'X' -Mode 'MonitorOnly' -TtlMinutes 45
    $leaseY = New-LeaseRecord -OwnerId 'YYYY-2' -OwnerLabel 'Y' -Mode 'MonitorOnly' -TtlMinutes 45
    $pushX = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/lease.json' = (ConvertTo-Json -InputObject $leaseX -Depth 6) } `
        -ParentCommit $parent -CommitMessage 'lease: renew X' -MachineId 'X'
    $pushY = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/lease.json' = (ConvertTo-Json -InputObject $leaseY -Depth 6) } `
        -ParentCommit $parent -CommitMessage 'lease: renew Y' -MachineId 'Y'
    Assert-True ($pushX.ok -xor $pushY.ok) 'exactly one racer wins'
    $final = Get-RemoteLease -Config $keeper.config -KeeperRoot $keeper.root
    $winner = if ($pushX.ok) { 'XXXX-1' } else { 'YYYY-2' }
    Assert-Equal $winner $final.lease.ownerId 'remote lease owned by the winner'

    Start-TestGroup 'lease: unreachable remote fails closed (never claims leader)'

    $cfgBad = New-TestConfig @{ github = @{ coordination = @{ enabled = $true; repoPath = Join-Path $ws 'missing-repo' } } }
    $eBad = Invoke-LeaderElection -Config $cfgBad -KeeperRoot $keeper.root -Machine $machineA -Now $now
    Assert-Equal 'DEGRADED' $eBad.role 'unreachable remote -> DEGRADED, not LEADER'

    $cfgMissing = New-TestConfig @{ github = @{ coordination = @{ enabled = $true; repoPath = Join-Path $ws 'plain-dir' } } }
    New-Item -ItemType Directory -Path (Join-Path $ws 'plain-dir') -Force | Out-Null
    $eMissing = Invoke-LeaderElection -Config $cfgMissing -KeeperRoot $keeper.root -Machine $machineA -Now $now
    Assert-Equal 'DEGRADED' $eMissing.role 'non-git repo -> DEGRADED'

    Start-TestGroup 'lease: local-only mode when github disabled'

    $cfgLocal = New-TestConfig @{ github = @{ coordination = @{ enabled = $false } } }
    $eLocal = Invoke-LeaderElection -Config $cfgLocal -KeeperRoot $keeper.root -Machine $machineA -Now $now
    Assert-Equal 'LEADER' $eLocal.role 'local-only leader'
    Assert-True ("$($eLocal.reason)" -match 'local-only') 'local-only reason surfaced'
} finally {
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "leader-lease.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
