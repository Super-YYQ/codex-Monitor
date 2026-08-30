# Codex Quota Keeper - distributed leader lease on a Private GitHub repo.
# coordination branch holds coordination/lease.json; CAS = git push rejection.
# Doc 02 §8 algorithm / doc 03 §10 pseudo flow.

$script:CqkLeaderLeaseDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkLeaderLeaseDir 'common.ps1')
}
if (-not (Get-Command Invoke-Git -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkLeaderLeaseDir 'github-sync.ps1')
}

function New-LeaseRecord {
    param([string]$OwnerId, [string]$OwnerLabel, [string]$Mode, [int]$TtlMinutes, [string]$ExistingAcquiredAt = $null)
    $now = Get-IsoTimestamp
    return @{
        schema      = 1
        ownerId     = $OwnerId
        ownerLabel  = $OwnerLabel
        acquiredAt  = if ($ExistingAcquiredAt) { $ExistingAcquiredAt } else { $now }
        renewedAt   = $now
        expiresAt   = (Get-Date).AddMinutes($TtlMinutes).ToString('yyyy-MM-ddTHH:mm:sszzz')
        mode        = $Mode
        version     = $script:CQK_VERSION
    }
}

function Test-LeaseActive {
    # A lease stays valid through the grace window (clock skew / network delay),
    # i.e. expired only when expiresAt + graceMinutes < now.
    param([hashtable]$Lease, [DateTime]$Now, [int]$GraceMinutes)
    if ($null -eq $Lease -or -not $Lease.expiresAt) { return $false }
    $expires = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Lease.expiresAt, [ref]$expires)) { return $false }
    return ($expires.LocalDateTime -gt $Now.AddMinutes(-1 * $GraceMinutes))
}

function Get-RemoteLease {
    # Fetches and parses coordination/lease.json from the remote repo (read-only).
    param([hashtable]$Config, [string]$KeeperRoot)
    $out = @{ reachable = $false; lease = $null; commit = $null; reason = $null; detail = $null }
    if (-not (Test-CoordinationEnabled $Config)) {
        $out.reason = 'disabled'
        return $out
    }
    if (-not (Test-GitAvailable)) { $out.reason = 'git-unavailable'; return $out }
    $coord = Get-CoordinationConfig $Config
    $repoPath = [System.IO.Path]::GetFullPath($coord.repoPath)
    $issues = Test-LogRepoAllowed -RepoPath $repoPath -KeeperRoot $KeeperRoot
    if ($issues.Count -gt 0) { $out.reason = 'repo-not-allowed'; $out.detail = ($issues -join '; '); return $out }

    $branch = $coord.branch
    $blob = Get-RemoteBranchBlob -RepoPath $repoPath -Branch $branch -PathInRepo 'coordination/lease.json'
    if (-not $blob.ok) {
        $out.reason = 'unreachable'; $out.detail = $blob.detail
        return $out
    }
    $out.reachable = $true
    $out.commit = $blob.commit
    if ($blob.reason -eq 'ok') {
        $lease = ConvertFrom-JsonSafe $blob.content
        if ($lease -is [hashtable]) { $out.lease = $lease }
        else { $out.reason = 'lease-unparseable' }
    } else {
        $out.reason = $blob.reason   # branch-missing | file-missing -> first run
    }
    return $out
}

function Invoke-LeaderElection {
    # Ensures this machine is the single active leader or yields to PASSIVE.
    # Local-only mode (github disabled / leader disabled) is allowed but the
    # caller must surface it as MULTI-PC UNSAFE in status output.
    param([hashtable]$Config, [string]$KeeperRoot, [hashtable]$Machine, [DateTime]$Now = (Get-Date))

    $out = @{ role = 'LEADER'; lease = $null; otherOwner = $null; reason = $null; remoteReachable = $false }

    if ($Config.leader.enabled -ne $true) {
        $out.reason = 'local-only: leader coordination disabled'
        return $out
    }
    if (-not (Test-CoordinationEnabled $Config)) {
        $out.reason = 'local-only: github coordination disabled'
        return $out
    }

    $remote = Get-RemoteLease -Config $Config -KeeperRoot $KeeperRoot
    if (-not $remote.reachable) {
        # Cannot prove exclusivity -> never claim leadership (fail closed, doc 04 §6).
        $out.role = 'DEGRADED'
        $out.reason = "remote coordination unavailable: $($remote.reason)"
        return $out
    }
    $out.remoteReachable = $true

    $lease = $remote.lease
    $me = [string]$Machine.machineId
    $grace = [int]$Config.leader.graceMinutes
    $ttl = [int]$Config.leader.leaseTtlMinutes

    if ($null -ne $lease) {
        $out.lease = $lease
        $out.otherOwner = [string]$lease.ownerId
        $active = Test-LeaseActive -Lease $lease -Now $Now -GraceMinutes $grace
        if ($active -and [string]$lease.ownerId -ne $me) {
            $out.role = 'PASSIVE'
            $out.reason = "lease held by $($lease.ownerLabel) until $($lease.expiresAt)"
            return $out
        }
        if (-not $active -and [string]$lease.ownerId -ne $me -and $Config.leader.takeoverOnExpiry -ne $true) {
            $out.role = 'PASSIVE'
            $out.reason = "expired lease held by $($lease.ownerId); takeover disabled"
            return $out
        }
    }

    # Lease free (missing/expired/ours): claim or renew via push CAS.
    $existingAcquiredAt = $null
    if ($lease -and [string]$lease.ownerId -eq $me) { $existingAcquiredAt = ConvertTo-IsoString $lease.acquiredAt }
    $newLease = New-LeaseRecord -OwnerId $me -OwnerLabel ([string]$Machine.label) `
        -Mode ([string]$Config.mode) -TtlMinutes $ttl -ExistingAcquiredAt $existingAcquiredAt

    $coord = Get-CoordinationConfig $Config
    $repoPath = [System.IO.Path]::GetFullPath($coord.repoPath)
    $branch = $coord.branch
    $binding = Test-LogRepoBinding -RepoPath $repoPath -KeeperRoot $KeeperRoot -Branch $branch
    if ($binding) {
        $out.role = 'DEGRADED'
        $out.reason = "log repo binding failed: $binding"
        return $out
    }
    $json = ConvertTo-Json -InputObject $newLease -Depth 6
    $push = Push-RepoBlobs -RepoPath $repoPath -Branch $branch `
        -Blobs @{ 'coordination/lease.json' = $json } -ParentCommit $remote.commit `
        -CommitMessage "lease: renew $me" -MachineId $me

    if ($push.ok) {
        $out.role = 'LEADER'
        $out.lease = $newLease
        $out.reason = if ($lease) { 'lease renewed' } else { 'lease acquired' }
    } elseif ($push.reason -eq 'push-rejected') {
        # Another machine pushed first -> re-fetch and yield.
        $recheck = Get-RemoteLease -Config $Config -KeeperRoot $KeeperRoot
        $out.role = 'PASSIVE'
        $out.reason = 'lease push rejected; another machine won the race'
        if ($recheck.lease) { $out.lease = $recheck.lease; $out.otherOwner = [string]$recheck.lease.ownerId }
    } else {
        $out.role = 'DEGRADED'
        $out.reason = "lease push failed: $($push.reason)"
    }
    return $out
}

function Renew-LeaderLease {
    # Renewal after a successful poll: only touches the remote when we still own
    # the lease; losing it silently demotes us for the next round.
    param([hashtable]$Config, [string]$KeeperRoot, [hashtable]$Machine)
    $election = Invoke-LeaderElection -Config $Config -KeeperRoot $KeeperRoot -Machine $Machine
    return $election
}

function Save-LocalLeaseView {
    # Mirrors the last seen lease into runtime/state (status uses it read-only).
    param([string]$Root, [hashtable]$State, [hashtable]$Election)
    $State.leader.ownerId = if ($Election.lease) { [string]$Election.lease.ownerId } else { $null }
    $State.leader.ownerLabel = if ($Election.lease) { [string]$Election.lease.ownerLabel } else { $null }
    $State.leader.expiresAt = if ($Election.lease) { ConvertTo-IsoString $Election.lease.expiresAt } else { $null }
}
