# Codex Quota Keeper - AutoAnchor (EXPERIMENTAL, default disabled).
# After a quota window reset is observed, optionally send one minimal prompt via
# `codex exec` to anchor the next window. Every guard is fail-closed (doc 01 §6,
# doc 03 §8). Enabling requires mode=AutoAnchor AND codex.autoAnchor=true.

$script:CqkAutoAnchorDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkAutoAnchorDir 'common.ps1')
}
if (-not (Get-Command Invoke-CodexRateLimitsRead -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkAutoAnchorDir 'quota-client.ps1')
}
if (-not (Get-Command Test-ShouldAnchor -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkAutoAnchorDir 'state-machine.ps1')
}
if (-not (Get-Command Push-RepoBlobs -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkAutoAnchorDir 'github-sync.ps1')
}

function Test-AnchorPromptAllowed {
    # Prompt whitelist (doc 03 §15): short, printable, no shell metacharacters.
    # The prompt is passed as a single argument (never through a shell) and is
    # never accepted from remote content.
    param([string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return $false }
    if ($Prompt.Length -gt 120) { return $false }
    return ($Prompt -match '^[A-Za-z0-9 .,!?''\-]+$')
}

function Get-AnchorExecCommand {
    # Any codex shape (exe / npm codex.cmd / mock .ps1) through the unified
    # launcher (CQK-004). Argument arrays only.
    param([string]$CodexPath, [string]$Prompt)
    return (Resolve-ExecutableLaunchSpec -Executable $CodexPath -ArgumentList @('exec', '--skip-git-repo-check', $Prompt))
}

function Get-AnchorEventCoordPath {
    param([string]$EventId)
    return 'coordination/events/' + $EventId + '.json'
}

function Get-AnchorEventState {
    # Reads coordination/events/<eventId>.json (read-only).
    param([hashtable]$Config, [string]$KeeperRoot, [string]$EventId)
    $out = @{ reachable = $false; exists = $false; record = $null; commit = $null; reason = $null }
    if (-not (Test-CoordinationEnabled $Config)) { $out.reason = 'disabled'; return $out }
    if (-not (Test-GitAvailable)) { $out.reason = 'git-unavailable'; return $out }
    $coord = Get-CoordinationConfig $Config
    $blob = Get-RemoteBranchBlob -RepoPath ([System.IO.Path]::GetFullPath($coord.repoPath)) -Branch $coord.branch `
        -PathInRepo (Get-AnchorEventCoordPath $EventId)
    if (-not $blob.ok) { $out.reason = 'unreachable'; return $out }
    $out.reachable = $true
    $out.commit = $blob.commit
    if ($blob.reason -eq 'ok' -and $blob.content) {
        $rec = ConvertFrom-JsonSafe $blob.content
        if ($rec -is [hashtable]) { $out.exists = $true; $out.record = $rec }
    }
    return $out
}

function Push-AnchorEventState {
    # CAS-writes the anchor event record (CLAIMED / COMPLETED / FAILED / EXPIRED).
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Record,
        [hashtable]$Machine
    )
    $coord = Get-CoordinationConfig $Config
    $repoPath = [System.IO.Path]::GetFullPath($coord.repoPath)
    $binding = Test-LogRepoBinding -RepoPath $repoPath -KeeperRoot $KeeperRoot -Branch $coord.branch
    if ($binding) { return @{ ok = $false; reason = "binding: $binding" } }
    $blob = Get-RemoteBranchBlob -RepoPath $repoPath -Branch $coord.branch -PathInRepo (Get-AnchorEventCoordPath $EventId)
    if (-not $blob.ok) { return @{ ok = $false; reason = 'unreachable' } }
    $parent = $null
    if ($blob.commit) { $parent = $blob.commit }
    $push = Push-RepoBlobs -RepoPath $repoPath -Branch $coord.branch `
        -Blobs @{ (Get-AnchorEventCoordPath $EventId) = (ConvertTo-Json -InputObject $Record -Depth 6) } `
        -ParentCommit $parent -CommitMessage "anchor: $($Record.state) $EventId" `
        -MachineId ([string]$Machine.machineId)
    return @{ ok = $push.ok; reason = $push.reason }
}

function Claim-AnchorEvent {
    # Distributed at-most-once side-effect claim (audit plan v1.0 section 5, CQK-013):
    # the event file is CREATED via CAS push while it does not exist. A rejected
    # push means another machine claimed first. Any existing event file
    # (CLAIMED / COMPLETED / FAILED / EXPIRED) blocks execution: an uncertain
    # outcome must never be retried.
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Machine,
        [int]$ClaimMinutes
    )
    $state = Get-AnchorEventState -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId
    if (-not $state.reachable) { return @{ ok = $false; reason = "remote unavailable ($($state.reason)); fail closed" } }
    if ($state.exists) {
        $st = [string]$state.record.state
        return @{ ok = $false; reason = "event already $st (by $($state.record.ownerId)); no retry" }
    }
    $record = @{
        schema         = 1
        eventId        = $EventId
        state          = 'CLAIMED'
        ownerId        = [string]$Machine.machineId
        claimedAt      = Get-IsoTimestamp
        claimExpiresAt = (Get-Date).AddMinutes($ClaimMinutes).ToString('yyyy-MM-ddTHH:mm:sszzz')
        completedAt    = $null
        result         = $null
    }
    $push = Push-AnchorEventState -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId -Record $record -Machine $Machine
    if (-not $push.ok) { return @{ ok = $false; reason = "claim push rejected ($($push.reason)); another machine claimed first" } }
    return @{ ok = $true; reason = $null }
}

function Test-LeaseRevalidation {
    # CQK-014: after claiming, re-confirm the leader lease is still ours AND has
    # enough remaining time for the safe execution window.
    param([hashtable]$Config, [string]$KeeperRoot, [hashtable]$Machine, [int]$RequiredMinutes)
    $election = Invoke-LeaderElection -Config $Config -KeeperRoot $KeeperRoot -Machine $Machine
    if ($election.role -ne 'LEADER' -or $null -eq $election.lease) {
        return @{ ok = $false; reason = "lease lost during claim (role=$($election.role))" }
    }
    if ([string]$election.lease.ownerId -ne [string]$Machine.machineId) {
        return @{ ok = $false; reason = 'lease owner changed during claim' }
    }
    $expires = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$election.lease.expiresAt, [ref]$expires)) {
        $remaining = ($expires.LocalDateTime - (Get-Date)).TotalMinutes
        if ($remaining -lt $RequiredMinutes) {
            $msg = 'lease remaining {0:n1} min < required {1} min' -f $remaining, $RequiredMinutes
            return @{ ok = $false; reason = $msg }
        }
    }
    return @{ ok = $true; reason = $null }
}

function Invoke-AutoAnchorIfNeeded {
    # Called by runner when mode=AutoAnchor and codex.autoAnchor=true.
    # Returns @{ anchored; events; historyFiles }.
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [hashtable]$State,
        $Events,
        [bool]$IsLeader,
        [hashtable]$Machine,
        [hashtable]$Election,
        [string]$CodexPath = ''
    )
    $out = @{ anchored = $false; events = @() }
    $now = Get-Date

    $guard = Test-ShouldAnchor -Config $Config -State $State -Events $Events -IsLeader $IsLeader -Now $now
    if (-not $guard.should) {
        # Guard denial before anything was executed: a skip, not an abort.
        $out.events += ,@{ event = 'ANCHOR_SKIPPED'; reason = $guard.reason }
        return $out
    }

    # Distributed claim (CQK-013): CAS-create the event file for every pending
    # eventId. Any existing/blocked event fails closed for that event.
    $execWindowMinutes = [Math]::Max(2, [int][Math]::Ceiling([int]$Config.codex.queryTimeoutSeconds * 3 / 60.0) + 1)
    $claimed = @()
    foreach ($id in @($guard.eventIds)) {
        $claim = Claim-AnchorEvent -Config $Config -KeeperRoot $KeeperRoot -EventId $id -Machine $Machine -ClaimMinutes ($execWindowMinutes * 2)
        if ($claim.ok) { $claimed += $id }
        else {
            $out.events += ,@{ event = 'ANCHOR_ABORTED'; reason = "event $id not claimed: $($claim.reason)"
                              anchor = @{ phase = 'CLAIM'; eventId = $id; reason = $claim.reason } }
        }
    }
    if ($claimed.Count -eq 0) { return $out }

    # CQK-014: revalidate the leader lease BEFORE any model call. If it cannot be
    # proven, the claimed events are marked EXPIRED: uncertain outcome never retries.
    $revalid = Test-LeaseRevalidation -Config $Config -KeeperRoot $KeeperRoot -Machine $Machine -RequiredMinutes $execWindowMinutes
    if (-not $revalid.ok) {
        foreach ($id in $claimed) {
            $null = Push-AnchorEventState -Config $Config -KeeperRoot $KeeperRoot -EventId $id `
                -Record @{ schema = 1; eventId = $id; state = 'EXPIRED'; ownerId = [string]$Machine.machineId;
                           claimedAt = Get-IsoTimestamp; claimExpiresAt = Get-IsoTimestamp; completedAt = $null;
                           result = "lease revalidation failed: $($revalid.reason)" } -Machine $Machine
            Add-ProcessedEvent -State $State -EventId $id
        }
        $out.events += ,@{ event = 'ANCHOR_ABORTED'; reason = "lease revalidation failed: $($revalid.reason); no model call"
                          anchor = @{ phase = 'REVALIDATE'; reason = $revalid.reason } }
        return $out
    }

    if (-not (Test-AnchorPromptAllowed -Prompt ([string](Get-AutoAnchorConfig $Config).prompt))) {
        $out.events += ,@{ event = 'ANCHOR_SKIPPED'; reason = 'anchorPrompt not on the safe whitelist' }
        return $out
    }

    if (-not $CodexPath) { $CodexPath = Resolve-CodexCommand $Config }
    if (-not $CodexPath) {
        $out.events += ,@{ event = 'ANCHOR_SKIPPED'; reason = 'codex executable not found' }
        return $out
    }

    # ---- ANCHORING: one minimal exec in an empty work dir --------------------
    $before = $State.buckets
    $workDir = Join-Path (Get-RuntimeDir $KeeperRoot) 'anchor-work'
    Ensure-Directory $workDir | Out-Null
    $execInfo = Get-AnchorExecCommand -CodexPath $CodexPath -Prompt ([string](Get-AutoAnchorConfig $Config).prompt)
    $startedAt = Get-IsoTimestamp
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $exec = Invoke-External -FilePath $execInfo.exe -ArgumentList $execInfo.args -RawArguments "$($execInfo.rawArgs)" `
        -TimeoutSeconds ([Math]::Max(60, [int]$Config.codex.queryTimeoutSeconds * 3)) -WorkingDirectory $workDir
    $sw.Stop()

    # ---- VERIFY: second read; never retry the model call --------------------
    $verify = Invoke-CodexRateLimitsRead -Config $Config -CodexPath $CodexPath
    $verified = [bool]$verify.ok
    $endedAt = Get-IsoTimestamp

    $anchorInfo = @{
        phase        = $(if ($verified -and $exec.ok) { 'ANCHORED' } else { 'ABORTED' })
        eventIds     = $claimed
        startedAt    = $startedAt
        endedAt      = $endedAt
        durationSecs = [int]$sw.Elapsed.TotalSeconds
        execExitCode = $exec.exitCode
        verified     = $verified
        before       = $before
        after        = $(if ($verify.ok) { $verify.buckets } else { $null })
        reason       = $(if (-not $exec.ok) { "exec failed ($($exec.exitCode))" } elseif (-not $verified) { 'post-anchor verification failed; no retry' } else { $null })
    }

    # Execution consumed quota regardless of verification: count it.
    $today = $now.ToString('yyyy-MM-dd')
    $count = [int]$State.anchors.count
    if ([string]$State.anchors.day -ne $today) { $count = 0 }
    $State.anchors = @{ day = $today; count = $count + 1; lastAnchorAt = $endedAt }

    foreach ($id in $claimed) { Add-ProcessedEvent -State $State -EventId $id }

    if ($verified -and $exec.ok) {
        $out.events += ,@{ event = 'ANCHOR_EXECUTED'; anchor = $anchorInfo }
        $out.anchored = $true
    } else {
        $out.events += ,@{ event = 'ANCHOR_ABORTED'; reason = $anchorInfo.reason; anchor = $anchorInfo }
    }

    # Complete the claimed events: COMPLETED on verified success, FAILED otherwise.
    # A failed completion push leaves CLAIMED, which blocks every other machine
    # (uncertain outcome is never retried).
    $finalState = $(if ($verified -and $exec.ok) { 'COMPLETED' } else { 'FAILED' })
    foreach ($id in $claimed) {
        $null = Push-AnchorEventState -Config $Config -KeeperRoot $KeeperRoot -EventId $id `
            -Record @{ schema = 1; eventId = $id; state = $finalState; ownerId = [string]$Machine.machineId;
                       claimedAt = $startedAt; claimExpiresAt = $null; completedAt = $endedAt;
                       result = $anchorInfo.reason } -Machine $Machine
    }

    # History record with before/after snapshots (doc 01 §6): durable outbox
    # entry + local JSONL audit copy.
    $logging = Get-LoggingConfig $Config
    $anchorRecord = @{
        eventId      = [string]$claimed[0]
        event        = $(if ($verified -and $exec.ok) { 'ANCHOR_EXECUTED' } else { 'ANCHOR_ABORTED' })
        machineId    = [string]$Machine.machineId
        machineLabel = [string]$Machine.label
        role         = 'LEADER'
        mode         = [string]$Config.mode
        windows      = $anchorInfo.after
        anchor       = $anchorInfo
        error        = $anchorInfo.reason
    }
    $null = Write-OutboxEvent -Root $KeeperRoot -Record $anchorRecord -MachineId ([string]$Machine.machineId) `
        -RunId $(if ($Election.runId) { [string]$Election.runId } else { '' }) `
        -IncludeMachineLabel:([bool]$logging.includeMachineLabel) -When $now
    $null = Write-HistoryEvent -Root $KeeperRoot -Record $anchorRecord `
        -IncludeMachineLabel:([bool]$logging.includeMachineLabel) -When $now
    return $out
}
