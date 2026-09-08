# Codex Quota Keeper - cluster-level backoff (audit plan v1.0 §7 / CQK-008).
# coordination/backoff.json shares one machine's 429/auth-error backoff with the
# whole fleet: when a lease changes hands, the new leader must not bypass the
# previous leader's backoff by simply starting to poll.
#
# CQK-024 closes the write side of that loop. A marker whose push fails for a
# transient reason is persisted to runtime/pending-global-backoff.json, and
# Sync-PendingGlobalBackoff retries it on every scheduled tick - including ticks
# that fall inside a LOCAL backoff window, which is precisely when the fleet most
# needs to be told.

$script:CqkGlobalBackoffDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkGlobalBackoffDir 'common.ps1')
}
if (-not (Get-Command Get-RemoteBranchBlob -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkGlobalBackoffDir 'github-sync.ps1')
}

$script:CQK_BACKOFF_MARKER_PATH = 'coordination/backoff.json'
# Failures worth queueing for a later tick: anything that can heal by itself.
# 'push-rejected' is deliberately NOT here - after the in-call rebase retry it
# means a peer already wrote the marker, so the fleet is protected and there is
# nothing left to deliver. 'binding:*' needs a human (re-run setup-log-repo).
$script:CQK_BACKOFF_RETRYABLE = @(
    'unreachable', 'git-unavailable', 'nothing-to-commit',
    'index-failed', 'remove-failed', 'hash-failed', 'index-add-failed', 'tree-failed', 'commit-failed'
)

function Convert-BackoffUntilToTime {
    # Unparsable/absent timestamps collapse to [DateTime]::MinValue, i.e. 'no
    # deadline' - callers then write a fresh marker instead of trusting garbage.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return [DateTime]::MinValue }
    $o = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Value, [ref]$o)) { return $o.LocalDateTime }
    return [DateTime]::MinValue
}

function Get-GlobalBackoffRecord {
    # Parses a marker blob into a record hashtable (@{} when absent/unreadable).
    param($Blob)
    if ($null -eq $Blob -or -not $Blob.ok -or $Blob.reason -ne 'ok' -or -not $Blob.content) { return @{} }
    $rec = ConvertFrom-JsonSafe $Blob.content
    if ($rec -isnot [hashtable]) { return @{} }
    return $rec
}

function Push-GlobalBackoffRecord {
    # Binding gate + CAS push. A rejection caused by the fetched parent having
    # moved (a peer wrote meanwhile) is re-based on the current tip and tried
    # once more; the deadline is unchanged, so re-basing is safe.
    param(
        [string]$RepoPath,
        [string]$Branch,
        [string]$PathInRepo,
        [string]$Json,
        [string]$ParentCommit,
        [string]$Reason,
        [string]$MachineId,
        [string]$KeeperRoot
    )
    $binding = Test-LogRepoBinding -RepoPath $RepoPath -KeeperRoot $KeeperRoot -Branch $Branch
    if ($binding) { return @{ ok = $false; reason = "binding: $binding" } }

    $parent = $ParentCommit
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $push = Push-RepoBlobs -RepoPath $RepoPath -Branch $Branch `
            -Blobs @{ $PathInRepo = $Json } -ParentCommit $parent `
            -CommitMessage "keeper: global backoff $Reason" -MachineId $MachineId
        if ($push.ok) { return @{ ok = $true; reason = 'pushed' } }
        if ($push.reason -ne 'push-rejected') { return @{ ok = $false; reason = [string]$push.reason } }
        if ($attempt -eq 1) { break }
        $fresh = Get-RemoteBranchBlob -RepoPath $RepoPath -Branch $Branch -PathInRepo $PathInRepo
        if (-not $fresh.ok) { return @{ ok = $false; reason = 'unreachable' } }
        $parent = $fresh.commit
    }
    return @{ ok = $false; reason = 'push-rejected' }
}

function Resolve-GlobalBackoffWrite {
    # One fetch -> decide -> CAS push, shared by the immediate write
    # (Set-GlobalBackoff) and the per-tick retry (Sync-PendingGlobalBackoff) so
    # both obey the same binding gate and the same monotonic-deadline rule.
    # Returns @{ ok; reason; retryable }.
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$Reason,
        [string]$UntilIso,
        [hashtable]$Machine,
        [bool]$AllowPush
    )
    if (-not $AllowPush) { return @{ ok = $false; reason = 'git-unavailable'; retryable = $true } }

    $coord = Get-CoordinationConfig $Config
    $repoPath = [System.IO.Path]::GetFullPath($coord.repoPath)
    $branch = $coord.branch
    $machineId = $(if ($Machine) { [string]$Machine.machineId } else { '' })

    $blob = Get-RemoteBranchBlob -RepoPath $repoPath -Branch $branch -PathInRepo $script:CQK_BACKOFF_MARKER_PATH
    if (-not $blob.ok) { return @{ ok = $false; reason = 'unreachable'; retryable = $true } }

    # The marker is an absolute deadline, so a later one already on the branch
    # means the fleet is protected at least as far as this write would reach.
    $markerUntil = Convert-BackoffUntilToTime ([string](Get-GlobalBackoffRecord -Blob $blob).until)
    if ($markerUntil -gt (Convert-BackoffUntilToTime $UntilIso)) {
        return @{ ok = $true; reason = 'already-active'; retryable = $false }
    }

    $record = @{
        schema        = 1
        until         = $UntilIso
        reason        = $Reason
        sourceOwnerId = $machineId
        setAt         = Get-IsoTimestamp
    }
    $push = Push-GlobalBackoffRecord -RepoPath $repoPath -Branch $branch -PathInRepo $script:CQK_BACKOFF_MARKER_PATH `
        -Json (ConvertTo-Json -InputObject $record -Depth 6) -ParentCommit $blob.commit `
        -Reason $Reason -MachineId $machineId -KeeperRoot $KeeperRoot
    return @{ ok = [bool]$push.ok; reason = [string]$push.reason
              retryable = ($(if ($push.ok) { $false } else { [bool]($script:CQK_BACKOFF_RETRYABLE -contains [string]$push.reason) })) }
}

function Get-GlobalBackoff {
    # Returns @{ reachable; active; until; reason; sourceOwnerId }.
    # Without coordination there is no cluster state: report reachable with
    # active=$false (callers fall back to their local backoff).
    param([hashtable]$Config, [string]$KeeperRoot, [DateTime]$Now = (Get-Date))
    $out = @{ reachable = $false; active = $false; until = $null; reason = $null; sourceOwnerId = $null }
    if (-not (Test-CoordinationEnabled $Config)) {
        $out.reachable = $true
        $out.reason = 'coordination-disabled'
        return $out
    }
    if (-not (Test-GitAvailable)) { $out.reason = 'git-unavailable'; return $out }
    $coord = Get-CoordinationConfig $Config
    $blob = Get-RemoteBranchBlob -RepoPath ([System.IO.Path]::GetFullPath($coord.repoPath)) -Branch $coord.branch -PathInRepo $script:CQK_BACKOFF_MARKER_PATH
    if (-not $blob.ok) { $out.reason = 'unreachable'; return $out }
    $out.reachable = $true
    $record = Get-GlobalBackoffRecord -Blob $blob
    if ($record.Count -eq 0) { return $out }
    $out.until = Convert-BackoffUntilToTime ([string]$record.until)
    if ($out.until -eq [DateTime]::MinValue) { return $out }
    $out.reason = [string]$record.reason
    $out.sourceOwnerId = [string]$record.sourceOwnerId
    if ($out.until -gt $Now) { $out.active = $true }
    return $out
}

function Set-GlobalBackoff {
    # Publishes the cluster marker. A failed push never breaks the run - but it
    # is not silent either: transient failures are queued in
    # runtime/pending-global-backoff.json so later ticks retry them (CQK-024).
    # Config-level skips (coordination disabled, repo binding violation) cannot
    # heal by retrying and are therefore never queued.
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [int]$Minutes,
        [string]$Reason,
        [hashtable]$Machine,
        [string]$UntilIso = ''
    )
    if (-not (Test-CoordinationEnabled $Config)) {
        # No fleet to notify, and no point retrying forever.
        Clear-PendingGlobalBackoff -Root $KeeperRoot
        return @{ ok = $false; reason = 'disabled' }
    }
    if (-not $UntilIso) { $UntilIso = (Get-Date).AddMinutes($Minutes).ToString('yyyy-MM-ddTHH:mm:sszzz') }

    $res = Resolve-GlobalBackoffWrite -Config $Config -KeeperRoot $KeeperRoot -Reason $Reason `
        -UntilIso $UntilIso -Machine $Machine -AllowPush ((Test-GitAvailable) -eq $true)
    if ($res.ok) {
        Clear-PendingGlobalBackoff -Root $KeeperRoot
    } elseif ($res.retryable) {
        Write-PendingGlobalBackoff -Root $KeeperRoot -Minutes $Minutes -Reason $Reason -UntilIso $UntilIso
    }
    return @{ ok = [bool]$res.ok; reason = [string]$res.reason }
}

function Write-PendingGlobalBackoff {
    # Keep the most demanding deadline: downgrading a longer queued window to a
    # shorter one would under-protect the fleet.
    # Returns $true when the queue was (re)written.
    param([string]$Root, [int]$Minutes, [string]$Reason, [string]$UntilIso)
    $existing = Get-PendingGlobalBackoff -Root $Root
    if ($existing -and (Convert-BackoffUntilToTime ([string]$existing.until)) -gt (Convert-BackoffUntilToTime $UntilIso)) {
        return $false
    }
    Set-PendingGlobalBackoff -Root $Root -Minutes $Minutes -Reason $Reason -UntilIso $UntilIso
    return $true
}

function Sync-PendingGlobalBackoff {
    # CQK-024 maintenance entry point: called on EVERY scheduled tick, before the
    # local-backoff exit, so a marker that never reached the remote is retried
    # even while this machine itself refuses to touch Codex.
    #
    # The queued `until` is an absolute deadline and is preserved verbatim -
    # retrying a write must not lengthen the backoff the failure cost us.
    # Returns @{ attempted; ok; reason; pendingCleared }.
    param([hashtable]$Config, [string]$KeeperRoot, [hashtable]$Machine)
    $pending = Get-PendingGlobalBackoff -Root $KeeperRoot
    if (-not $pending) { return @{ attempted = $false; ok = $true; reason = 'none'; pendingCleared = $false } }
    if (-not (Test-CoordinationEnabled $Config)) {
        Clear-PendingGlobalBackoff -Root $KeeperRoot
        return @{ attempted = $false; ok = $true; reason = 'disabled'; pendingCleared = $true }
    }
    if ((Convert-BackoffUntilToTime ([string]$pending.until)) -le (Get-Date)) {
        # The window it described has passed; pushing it now would put the fleet
        # under a backoff that no longer applies.
        Clear-PendingGlobalBackoff -Root $KeeperRoot
        return @{ attempted = $false; ok = $true; reason = 'expired'; pendingCleared = $true }
    }

    $minutes = [int]$pending.minutes
    $reason = [string]$pending.reason
    $until = [string]$pending.until
    $res = Resolve-GlobalBackoffWrite -Config $Config -KeeperRoot $KeeperRoot -Reason $reason `
        -UntilIso $until -Machine $Machine -AllowPush ((Test-GitAvailable) -eq $true)
    if ($res.ok) {
        Clear-PendingGlobalBackoff -Root $KeeperRoot
        return @{ attempted = $true; ok = $true; reason = [string]$res.reason; pendingCleared = $true }
    }
    if (-not $res.retryable) {
        # Retrying cannot fix this (e.g. the binding was revoked) - drop the queue.
        Clear-PendingGlobalBackoff -Root $KeeperRoot
        return @{ attempted = $true; ok = $false; reason = [string]$res.reason; pendingCleared = $true }
    }
    # Failed again for a transient reason: rewrite the ORIGINAL record, since the
    # fetch inside Resolve may have seen a peer's marker.
    Set-PendingGlobalBackoff -Root $KeeperRoot -Minutes $minutes -Reason $reason -UntilIso $until
    return @{ attempted = $true; ok = $false; reason = [string]$res.reason; pendingCleared = $false }
}
