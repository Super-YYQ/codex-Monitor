# Codex Quota Keeper - cluster-level backoff (audit plan v1.0 §7 / CQK-008).
# coordination/backoff.json shares one machine's 429/auth-error backoff with the
# whole fleet: when a lease changes hands, the new leader must not bypass the
# previous leader's backoff by simply starting to poll.

$script:CqkGlobalBackoffDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkGlobalBackoffDir 'common.ps1')
}
if (-not (Get-Command Get-RemoteBranchBlob -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkGlobalBackoffDir 'github-sync.ps1')
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
    $blob = Get-RemoteBranchBlob -RepoPath ([System.IO.Path]::GetFullPath($coord.repoPath)) -Branch $coord.branch -PathInRepo 'coordination/backoff.json'
    if (-not $blob.ok) { $out.reason = 'unreachable'; return $out }
    $out.reachable = $true
    if ($blob.reason -ne 'ok' -or -not $blob.content) { return $out }

    $record = ConvertFrom-JsonSafe $blob.content
    if ($record -isnot [hashtable] -or -not $record.until) { return $out }
    $until = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$record.until, [ref]$until)) { return $out }
    $out.until = $until.LocalDateTime
    $out.reason = [string]$record.reason
    $out.sourceOwnerId = [string]$record.sourceOwnerId
    if ($until.LocalDateTime -gt $Now) { $out.active = $true }
    return $out
}

function Set-GlobalBackoff {
    # Best-effort CAS push of coordination/backoff.json. A failed push must not
    # break the run: the local backoff still protects this machine, and the next
    # poll retries the remote marker.
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [int]$Minutes,
        [string]$Reason,
        [hashtable]$Machine
    )
    if (-not (Test-CoordinationEnabled $Config)) { return @{ ok = $false; reason = 'disabled' } }
    if (-not (Test-GitAvailable)) { return @{ ok = $false; reason = 'git-unavailable' } }
    $coord = Get-CoordinationConfig $Config
    $repoPath = [System.IO.Path]::GetFullPath($coord.repoPath)
    $binding = Test-LogRepoBinding -RepoPath $repoPath -KeeperRoot $KeeperRoot -Branch $coord.branch
    if ($binding) { return @{ ok = $false; reason = "binding: $binding" } }
    $blob = Get-RemoteBranchBlob -RepoPath $repoPath -Branch $coord.branch -PathInRepo 'coordination/backoff.json'
    if (-not $blob.ok) { return @{ ok = $false; reason = 'unreachable' } }
    $parent = $null
    if ($blob.commit) { $parent = $blob.commit }

    $record = @{
        schema        = 1
        until         = (Get-Date).AddMinutes($Minutes).ToString('yyyy-MM-ddTHH:mm:sszzz')
        reason        = $Reason
        sourceOwnerId = $(if ($Machine) { [string]$Machine.machineId } else { '' })
        setAt         = Get-IsoTimestamp
    }
    $push = Push-RepoBlobs -RepoPath $repoPath -Branch $coord.branch `
        -Blobs @{ 'coordination/backoff.json' = (ConvertTo-Json -InputObject $record -Depth 6) } `
        -ParentCommit $parent -CommitMessage "keeper: global backoff $Reason" `
        -MachineId $(if ($Machine) { [string]$Machine.machineId } else { '' })
    return @{ ok = $push.ok; reason = $push.reason }
}
