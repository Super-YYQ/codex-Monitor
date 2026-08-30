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

function Get-RemoteProcessedEventIds {
    # Second-layer event lock on the coordination branch (doc 02 §8): one reset
    # event may fire at most once across ALL machines, not just this one.
    param([hashtable]$Config, [string]$KeeperRoot)
    $out = @{ reachable = $false; ids = @(); reason = $null }
    if (-not (Test-CoordinationEnabled $Config)) {
        # No shared coordination point: cannot prove another machine hasn't anchored.
        $out.reason = 'disabled'
        return $out
    }
    $coord = Get-CoordinationConfig $Config
    $repoPath = [System.IO.Path]::GetFullPath($coord.repoPath)
    $blob = Get-RemoteBranchBlob -RepoPath $repoPath -Branch $coord.branch -PathInRepo 'coordination/processed-events.jsonl'
    if (-not $blob.ok) { $out.reason = 'unreachable'; return $out }
    $out.reachable = $true
    if ($blob.reason -eq 'ok' -and $blob.content) {
        $out.ids = @($blob.content -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    return $out
}

function Add-RemoteProcessedEventIds {
    # Best-effort remote marker push after a local anchor decision.
    param([hashtable]$Config, [string]$KeeperRoot, [string[]]$EventIds, [hashtable]$Machine)
    if (-not (Test-CoordinationEnabled $Config)) { return @{ ok = $false; reason = 'disabled' } }
    $coord = Get-CoordinationConfig $Config
    $repoPath = [System.IO.Path]::GetFullPath($coord.repoPath)
    $branch = $coord.branch
    $blob = Get-RemoteBranchBlob -RepoPath $repoPath -Branch $branch -PathInRepo 'coordination/processed-events.jsonl'
    if (-not $blob.ok) { return @{ ok = $false; reason = 'unreachable' } }
    $existing = @()
    if ($blob.reason -eq 'ok' -and $blob.content) {
        $existing = @($blob.content -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $merged = @($existing)
    foreach ($id in $EventIds) { if ($merged -notcontains $id) { $merged += $id } }
    $content = ($merged -join "`n") + "`n"
    $push = Push-RepoBlobs -RepoPath $repoPath -Branch $branch `
        -Blobs @{ 'coordination/processed-events.jsonl' = $content } -ParentCommit $blob.commit `
        -CommitMessage "anchor: mark processed $($Machine.machineId)" -MachineId ([string]$Machine.machineId)
    return @{ ok = $push.ok; reason = $push.reason }
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

    # Second-layer lock: remote processed-event markers.
    $remoteIds = Get-RemoteProcessedEventIds -Config $Config -KeeperRoot $KeeperRoot
    if (-not $remoteIds.reachable) {
        $out.events += ,@{ event = 'ANCHOR_ABORTED'; reason = "remote event lock unavailable ($($remoteIds.reason)); fail closed"
                          anchor = @{ phase = 'GUARD'; reason = 'remote-lock-unavailable' } }
        return $out
    }
    $pending = @($guard.eventIds | Where-Object { $remoteIds.ids -notcontains $_ })
    if ($pending.Count -eq 0) {
        $out.events += ,@{ event = 'ANCHOR_ABORTED'; reason = 'reset event already anchored by another machine'
                          anchor = @{ phase = 'GUARD'; reason = 'remote-duplicate' } }
        foreach ($id in $guard.eventIds) { Add-ProcessedEvent -State $State -EventId $id }
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
        eventIds     = $pending
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

    foreach ($id in $pending) { Add-ProcessedEvent -State $State -EventId $id }

    if ($verified -and $exec.ok) {
        $out.events += ,@{ event = 'ANCHOR_EXECUTED'; anchor = $anchorInfo }
        $out.anchored = $true
    } else {
        $out.events += ,@{ event = 'ANCHOR_ABORTED'; reason = $anchorInfo.reason; anchor = $anchorInfo }
    }

    # Remote marker (best effort; a failure here cannot undo the exec).
    $null = Add-RemoteProcessedEventIds -Config $Config -KeeperRoot $KeeperRoot -EventIds $pending -Machine $Machine

    # History record with before/after snapshots (doc 01 §6): durable outbox
    # entry + local JSONL audit copy.
    $logging = Get-LoggingConfig $Config
    $anchorRecord = @{
        eventId      = [string]$pending[0]
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
