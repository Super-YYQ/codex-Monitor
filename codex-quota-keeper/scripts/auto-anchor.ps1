# Codex Quota Keeper - AutoAnchor (EXPERIMENTAL, default disabled).
# After a quota window reset is observed - or, on the keeper's own idle judgment
# (never anchored + second observation still shows zero usage), via the
# keepalive backstop (no anchor within keepaliveIntervalMinutes since the last
# one), or via a due daily schedule slot (codex.autoAnchor.schedule: pure timer,
# no reset/idle judgment) - send one minimal prompt via `codex exec` to anchor
# the next window. Every guard is fail-closed (doc 01 §6, doc 03 §8). Enabling
# requires mode=AutoAnchor AND codex.autoAnchor=true. Without a coordination repo
# (single machine) the Git CAS claim is replaced by a durable local claim file
# (anchor-claim.ps1, CQK-023) - the runner lock and state.processedEventIds are
# only fast paths, never the at-most-once guarantee, because both are written
# after the model call returned.

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
if (-not (Get-Command Claim-AnchorClaim -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkAutoAnchorDir 'anchor-claim.ps1')
}

function Test-AnchorPromptAllowed {
    # Prompt whitelist (doc 03 §15): short, printable, no control characters,
    # no shell metacharacters. Unicode prompts (e.g. Chinese) are allowed; the
    # prompt is passed as a single argument (never through a shell), but .cmd
    # installs dispatch through cmd.exe, so metacharacters stay banned.
    param([string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return $false }
    if ($Prompt.Length -gt 200) { return $false }
    if ($Prompt -match '[\x00-\x1F\x7F]') { return $false }
    if ($Prompt -match '[&|<>^%$"`@;]') { return $false }
    return $true
}

function Get-AnchorExecCommand {
    # Any codex shape (exe / npm codex.cmd / mock .ps1) through the unified
    # launcher (CQK-004). Argument arrays only. Optional model / reasoning
    # effort overrides go in as -m <model> / -c model_reasoning_effort=<effort>
    # (codex exec flags); when unset nothing is passed and the local
    # ~/.codex/config.toml defaults apply.
    param([string]$CodexPath, [string]$Prompt, [string]$Model = '', [string]$ReasoningEffort = '')
    $execArgs = @('exec', '--skip-git-repo-check')
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $execArgs += @('-m', $Model) }
    if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) { $execArgs += @('-c', "model_reasoning_effort=$ReasoningEffort") }
    $execArgs += $Prompt
    return (Resolve-ExecutableLaunchSpec -Executable $CodexPath -ArgumentList $execArgs)
}

# ---------------------------------------------------------------------------
# CQK-023 moved the claim store itself into anchor-claim.ps1 (unified
# Claim/Complete/Fail/Exists over both backings). These wrappers keep the
# distributed verbs' historical names for callers and tests/concurrency.test.ps1.

function Get-AnchorEventState {
    param([hashtable]$Config, [string]$KeeperRoot, [string]$EventId)
    return Get-DistributedAnchorEventState -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId
}

function Push-AnchorEventState {
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Record,
        [hashtable]$Machine
    )
    return Push-DistributedAnchorEventState -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId -Record $Record -Machine $Machine
}

function Claim-AnchorEvent {
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Machine,
        [int]$ClaimMinutes
    )
    return Claim-DistributedAnchorEvent -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine -ClaimMinutes $ClaimMinutes
}

function New-AnchorInvocationId {
    # doc v3.0 §4.1: one PHYSICAL codex exec gets its own audit id, because a
    # single call may be triggered by several merged reset/schedule events. A
    # trigger eventId can therefore never be reused as the model-call id - and
    # the id must not be derived from just one of them (that is how
    # $claimed[0] silently dropped the rest of the merged triggers).
    # Shape: anchor-<yyyyMMddTHHmmss>-<6 hex>, like the doc's example. The digest
    # covers the trigger set, the start second, the machine and the run id - all
    # four are present in the audit record, so the soak runbook can re-derive the
    # id from the record it is checking. Two physical execs can never share a
    # trigger set anyway: every claimed event ends terminal (COMPLETED/FAILED/
    # EXPIRED), and any existing claim blocks execution.
    param([string[]]$TriggerEventIds, [string]$StartedAt, [string]$MachineId)
    $stamp = 'unknown'
    if ($StartedAt -match '^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})') {
        $stamp = ($Matches[1] + $Matches[2] + $Matches[3] + 'T' + $Matches[4] + $Matches[5] + $Matches[6])
    }
    $runId = $(if ($script:CqkRunId) { [string]$script:CqkRunId } else { '' })
    $ids = @($TriggerEventIds | ForEach-Object { [string]$_ } | Sort-Object)
    $digest = Get-Sha256Hex (($ids -join ',') + '|' + $StartedAt + '|' + $MachineId + '|' + $runId)
    return 'anchor-' + $stamp + '-' + $digest.Substring(0, 6)
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
    # Returns @{ anchored; events }.
    #
    # SINGLE WRITER (doc v3.0 §4, CQK-036): this module executes the business
    # logic and RETURNS events - it never calls Write-OutboxEvent /
    # Write-HistoryEvent itself. The runner is the only Event Persistence
    # Owner, so one physical codex exec produces exactly one audit record.
    # The ANCHOR_EXECUTED / ANCHOR_ABORTED event emitted for a physical exec
    # carries eventId = anchorInvocationId (§4.1: a trigger eventId can never be
    # reused as the model-call id) plus the post-anchor windows, so the runner
    # needs no second pass to key the audit on the invocation.
    # -ForceAnchor (codex.autoAnchor.anchorOnApply -> install/apply-config) fires
    # one anchor right away, bypassing keepalive and the minimum gap; the guard
    # still enforces the daily cap and all fail-closed checks.
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [hashtable]$State,
        $Events,
        [bool]$IsLeader,
        [hashtable]$Machine,
        [hashtable]$Election,
        [string]$CodexPath = '',
        [bool]$ForceAnchor = $false
    )
    $out = @{ anchored = $false; events = @() }
    $now = Get-Date

    $guard = Test-ShouldAnchor -Config $Config -State $State -Events $Events -IsLeader $IsLeader -Now $now -Force $ForceAnchor
    if (-not $guard.should) {
        # Guard denial before anything was executed: a skip, not an abort.
        $out.events += ,@{ event = 'ANCHOR_SKIPPED'; reason = $guard.reason }
        return $out
    }

    # Durable claim (CQK-013 distributed / CQK-023 local): CLAIMED is written
    # before the model call, by both backings, and any existing claim - whatever
    # its state - blocks execution. The runner lock and state.processedEventIds
    # are fast paths only: both are written AFTER the call returns, so a crash
    # between exec and persist would otherwise pay for the same model call twice.
    # Lease revalidation stays distributed-only: localOnly election has no lease.
    $execWindowMinutes = [Math]::Max(2, [int][Math]::Ceiling([int]$Config.codex.queryTimeoutSeconds * 3 / 60.0) + 1)
    $localOnly = ($null -ne $Election -and [bool]$Election.localOnly)
    $claimed = @()
    foreach ($id in @($guard.eventIds)) {
        $claim = Claim-AnchorClaim -Config $Config -KeeperRoot $KeeperRoot -EventId $id -Machine $Machine `
            -ClaimMinutes ($execWindowMinutes * 2) -LocalOnly $localOnly
        if ($claim.ok) { $claimed += $id }
        else {
            $out.events += ,@{ event = 'ANCHOR_ABORTED'; reason = "event $id not claimed: $($claim.reason)"
                              anchor = @{ phase = 'CLAIM'; eventId = $id; reason = $claim.reason } }
        }
    }
    if ($claimed.Count -eq 0) { return $out }

    if (-not $localOnly) {
        # CQK-014: revalidate the leader lease BEFORE any model call. If it cannot be
        # proven, the claimed events are marked EXPIRED: uncertain outcome never retries.
        $revalid = Test-LeaseRevalidation -Config $Config -KeeperRoot $KeeperRoot -Machine $Machine -RequiredMinutes $execWindowMinutes
        if (-not $revalid.ok) {
            foreach ($id in $claimed) {
                $null = Mark-AnchorClaimExpired -Config $Config -KeeperRoot $KeeperRoot -EventId $id -Machine $Machine `
                    -Result "lease revalidation failed: $($revalid.reason)" -LocalOnly $localOnly
                Add-ProcessedEvent -State $State -EventId $id
            }
            $out.events += ,@{ event = 'ANCHOR_ABORTED'; reason = "lease revalidation failed: $($revalid.reason); no model call"
                              anchor = @{ phase = 'REVALIDATE'; reason = $revalid.reason } }
            return $out
        }
    }

    # Pre-exec skips: nothing was billed, so the claims are released as FAILED and
    # the events marked processed. Leaving them CLAIMED would block the event id
    # forever - the idle trigger is one-per-day, so anchoring would stay dead until
    # the operator cleaned runtime/anchor-claims by hand.
    if (-not (Test-AnchorPromptAllowed -Prompt ([string](Get-AutoAnchorConfig $Config).prompt))) {
        foreach ($id in $claimed) {
            $null = Fail-AnchorClaim -Config $Config -KeeperRoot $KeeperRoot -EventId $id -Machine $Machine `
                -Result 'skipped before exec: anchorPrompt not on the safe whitelist' -LocalOnly $localOnly
            Add-ProcessedEvent -State $State -EventId $id
        }
        $out.events += ,@{ event = 'ANCHOR_SKIPPED'; reason = 'anchorPrompt not on the safe whitelist' }
        return $out
    }

    if (-not $CodexPath) { $CodexPath = Resolve-CodexCommand $Config }
    if (-not $CodexPath) {
        foreach ($id in $claimed) {
            $null = Fail-AnchorClaim -Config $Config -KeeperRoot $KeeperRoot -EventId $id -Machine $Machine `
                -Result 'skipped before exec: codex executable not found' -LocalOnly $localOnly
            Add-ProcessedEvent -State $State -EventId $id
        }
        $out.events += ,@{ event = 'ANCHOR_SKIPPED'; reason = 'codex executable not found' }
        return $out
    }

    # ---- ANCHORING: one minimal exec in an empty work dir --------------------
    if ($localOnly) {
        $out.events += ,@{ event = 'ANCHOR_LOCAL'; reason = 'coordination disabled; durable local claim file only' }
    }
    $workDir = Join-Path (Get-RuntimeDir $KeeperRoot) 'anchor-work'
    Ensure-Directory $workDir | Out-Null
    $anchorCfgExec = Get-AutoAnchorConfig $Config
    $execInfo = Get-AnchorExecCommand -CodexPath $CodexPath -Prompt ([string]$anchorCfgExec.prompt) `
        -Model ([string]$anchorCfgExec.model) -ReasoningEffort ([string]$anchorCfgExec.reasoningEffort)
    $startedAt = Get-IsoTimestamp
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $exec = Invoke-External -FilePath $execInfo.exe -ArgumentList $execInfo.args -RawArguments "$($execInfo.rawArgs)" `
        -TimeoutSeconds ([Math]::Max(60, [int]$Config.codex.queryTimeoutSeconds * 3)) -WorkingDirectory $workDir `
        -Environment (Get-CodexProxyEnvironment $Config)
    $sw.Stop()

    # ---- VERIFY: second read; never retry the model call --------------------
    $verify = Invoke-CodexRateLimitsRead -Config $Config -CodexPath $CodexPath
    $verified = [bool]$verify.ok
    $endedAt = Get-IsoTimestamp

    # doc v3.0 §4.1: this physical exec gets exactly one audit id, shared by the
    # runtime log, the local history and the remote history (via the outbox).
    $invocationId = New-AnchorInvocationId -TriggerEventIds $claimed -StartedAt $startedAt `
        -MachineId ([string]$Machine.machineId)

    $anchorInfo = @{
        phase             = $(if ($verified -and $exec.ok) { 'ANCHORED' } else { 'ABORTED' })
        trigger           = [string]$guard.triggerKind
        localOnly         = $localOnly
        anchorInvocationId = $invocationId
        triggerEventIds   = $claimed
        startedAt         = $startedAt
        endedAt           = $endedAt
        durationSecs      = [int]$sw.Elapsed.TotalSeconds
        execExitCode      = $exec.exitCode
        verified          = $verified
        model             = $(if ([string]::IsNullOrWhiteSpace([string]$anchorCfgExec.model)) { $null } else { [string]$anchorCfgExec.model })
        reasoningEffort   = $(if ([string]::IsNullOrWhiteSpace([string]$anchorCfgExec.reasoningEffort)) { $null } else { [string]$anchorCfgExec.reasoningEffort })
        reason            = $(if (-not $exec.ok) { "exec failed ($($exec.exitCode))" } elseif (-not $verified) { 'post-anchor verification failed; no retry' } else { $null })
    }

    # Execution consumed quota regardless of verification: count it.
    $today = $now.ToString('yyyy-MM-dd')
    $count = [int]$State.anchors.count
    if ([string]$State.anchors.day -ne $today) { $count = 0 }
    $State.anchors = @{ day = $today; count = $count + 1; lastAnchorAt = $endedAt }

    foreach ($id in $claimed) { Add-ProcessedEvent -State $State -EventId $id }

    # ---- ONE invocation audit, written by the Runner (single writer) ---------
    # doc v3.0 §4: AutoAnchor = business execution + returns events; Runner = the
    # only Event Persistence Owner. The event below IS that invocation audit as
    # far as this module is concerned: keyed on anchorInvocationId (with the id
    # and the full trigger set also nested under `anchor`, because that is the
    # only path Sanitize-Record keeps), and carrying the post-anchor verification
    # read so the record shows the effect. Never keyed on $claimed[0], which
    # silently dropped every merged trigger after the first.
    if ($verified -and $exec.ok) {
        $out.events += ,@{ event = 'ANCHOR_EXECUTED'; eventId = $invocationId
                           anchorInvocationId = $invocationId; triggerEventIds = $claimed
                           windows = $verify.windows; anchor = $anchorInfo }
        $out.anchored = $true
    } else {
        $out.events += ,@{ event = 'ANCHOR_ABORTED'; eventId = $invocationId
                           anchorInvocationId = $invocationId; triggerEventIds = $claimed
                           reason = $anchorInfo.reason; anchor = $anchorInfo }
    }

    # Finalize every claimed event: COMPLETED on verified success, FAILED otherwise.
    # Distributed: a failed completion push leaves the event CLAIMED, which blocks
    # every other machine (uncertain outcome is never retried). Local: the same
    # state machine over runtime/anchor-claims, so a crash after exec but before
    # this write also leaves CLAIMED.
    $finalState = $(if ($verified -and $exec.ok) { 'COMPLETED' } else { 'FAILED' })
    foreach ($id in $claimed) {
        $fn = $(if ($finalState -eq 'COMPLETED') { 'Complete-AnchorClaim' } else { 'Fail-AnchorClaim' })
        $null = & $fn -Config $Config -KeeperRoot $KeeperRoot -EventId $id -Machine $Machine `
            -Result $anchorInfo.reason -ClaimedAt $startedAt -CompletedAt $endedAt -LocalOnly $localOnly
    }

    return $out
}
