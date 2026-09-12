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
if (-not (Get-Command Resolve-ExecutionProfile -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkAutoAnchorDir 'codex-profile.ps1')
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

function New-AnchorProfileGateEvent {
    # The audit record for a pre-Claim refusal (doc v3.0 §8). Deliberately its own
    # event name rather than ANCHOR_SKIPPED: a guard denial says "not now", this
    # says "armed, and the call cannot be proven safe" - the operator has to be able
    # to tell the two apart in the log, and only the second one is a release blocker.
    #
    # No anchorInvocationId and no `windows`: §4.1 keys an invocation audit on a
    # PHYSICAL exec, and there was none. The trigger event ids ride along as
    # triggerEventIds to show what is still pending - unclaimed, so the next poll
    # can still anchor (that is the whole point of validating before the Claim).
    #
    # The profile identity is copied field by field, never as a Profile dump:
    # validationReason and errorKind carry CLI text, so they go out through the
    # event's `reason`/`errorKind` (which both log paths run through
    # Hide-SensitiveText) instead of nesting under `anchor`.
    param(
        [string]$Validation,
        [string]$Reason,
        [string]$ErrorKind,
        $Profile,
        $Guard,
        [bool]$LocalOnly
    )
    $name = 'ANCHOR_PROFILE_UNAVAILABLE'
    if ($Validation -eq 'INVALID') { $name = 'ANCHOR_PROFILE_INVALID' }
    $anchor = @{
        phase             = 'PROFILE_VALIDATION'
        trigger           = $(if ($Guard) { [string]$Guard.triggerKind } else { '' })
        localOnly         = $LocalOnly
        profileValidation = $Validation
        triggerEventIds   = $(if ($Guard) { @($Guard.eventIds) } else { @() })
        execExitCode      = $null
        verified          = $false
    }
    if ($Profile -is [hashtable]) {
        foreach ($k in @('configuredModel', 'configuredReasoningEffort', 'effectiveModel',
                         'effectiveReasoningEffort', 'modelProvider', 'modelSource',
                         'reasoningEffortSource', 'validatedAt')) {
            $anchor[$k] = [string]$Profile[$k]
        }
        $supported = @($Profile.supportedReasoningEfforts)
        if ($supported.Count -gt 0) { $anchor.supportedReasoningEfforts = $supported }
    }
    return @{ event = $name; reason = $Reason; errorKind = $ErrorKind; anchor = $anchor }
}

function Get-AnchorProfileGate {
    # doc v3.0 §8: what was legal at Install time is not proven legal now. A CLI
    # upgrade can retire the model, an account or provider switch can make it
    # unservable, the reasoning tiers can change, the catalog can be temporarily
    # unreadable. So every armed anchor attempt revalidates the Execution Profile
    # LIVE - one app-server session, config/read + the paginated model/list, in the
    # same Codex environment `codex exec` is about to run in (§6.2) - and it does so
    # BEFORE the Claim, which is the ordering §8 calls out by name:
    #
    #   Test-ShouldAnchor -> Resolve Execution Profile (LIVE) -> VALID ?
    #       no  -> ANCHOR_PROFILE_INVALID / UNAVAILABLE, no Claim, no exec, retried
    #       yes -> Claim event(s) -> Lease Revalidate -> codex exec
    #
    # Claiming first would consume a deterministic reset/schedule event for a model
    # call that never happened, and that event could lose its one chance to be
    # handled. Refusing before the Claim leaves every claim untouched, so the next
    # poll re-resolves and can still anchor.
    #
    # This is the runtime twin of install.ps1's Get-ExecutionProfileGate, and the
    # reason it is not that function: Install turns a verdict into issues/warnings
    # for a human standing at a console, here the verdict is an audit event plus a
    # go/no-go for an unattended tick. What they share is the resolution itself.
    #
    # Returns @{ allowed; codexPath; profile; validation; reason; event }.
    # No counter is ever touched here (§21 / §19 T10: a validation failure is not
    # an attempt, so it must not move the daily cap).
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$CodexPath,
        $Guard,
        [bool]$LocalOnly = $false
    )
    $out = @{
        allowed    = $false
        codexPath  = $CodexPath
        profile    = $null
        validation = ''
        reason     = $null
        event      = $null
    }

    if (-not $CodexPath) { $CodexPath = Resolve-CodexCommand $Config }
    if (-not $CodexPath) {
        # No binary means no environment to resolve against and no exec to run.
        # UNAVAILABLE rather than a fourth verdict: it is exactly as unverifiable as
        # a catalog that will not answer, and the operator fixes it the same way.
        # The historical reason text is kept word for word.
        $out.validation = 'UNAVAILABLE'
        $out.reason = 'codex executable not found'
        $out.event = New-AnchorProfileGateEvent -Validation 'UNAVAILABLE' -Reason $out.reason `
            -ErrorKind 'SETUP_ERR' -Guard $Guard -LocalOnly $LocalOnly
        return $out
    }

    $prof = Resolve-ExecutionProfile -Config $Config -CodexPath $CodexPath
    $out.codexPath = $CodexPath
    $out.profile = $prof
    $out.validation = [string]$prof.validation

    if ($prof.validation -eq 'VALID') {
        # Mirror Install: the cache is the offline status panel's only source
        # (§14.1), and this is now the freshest verified profile anyone has taken.
        $null = Write-ExecutionProfileCache -KeeperRoot $KeeperRoot -Profile $prof
        $out.allowed = $true
        return $out
    }
    $out.reason = [string]$prof.validationReason
    if ($prof.validation -eq 'INVALID') {
        # Record the rejection: the panel should show the model that was proven bad,
        # not yesterday's proof that it was good.
        $null = Write-ExecutionProfileCache -KeeperRoot $KeeperRoot -Profile $prof
    }
    # Anything else is UNAVAILABLE, which deliberately does NOT touch the cache: a
    # read failure says nothing about the profile, and overwriting the last real
    # verdict would make the offline panel lie about a profile that was fine.
    if (-not $out.reason) {
        $out.reason = "execution profile could not be verified ($($prof.errorKind))"
    }
    $out.event = New-AnchorProfileGateEvent -Validation $out.validation -Reason $out.reason `
        -ErrorKind ([string]$prof.errorKind) -Profile $prof -Guard $Guard -LocalOnly $LocalOnly
    return $out
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

    $execWindowMinutes = [Math]::Max(2, [int][Math]::Ceiling([int]$Config.codex.queryTimeoutSeconds * 3 / 60.0) + 1)
    $localOnly = ($null -ne $Election -and [bool]$Election.localOnly)

    # ---- CQK-040 (§8): prove the Execution Profile BEFORE the Claim ----------
    # What was legal at Install time is not proven legal now, and the order is the
    # point: resolving after the Claim would burn a deterministic reset/schedule
    # event on a model call that never happens. A refusal here claims nothing, so
    # the next poll re-resolves and can still anchor.
    $gate = Get-AnchorProfileGate -Config $Config -KeeperRoot $KeeperRoot -CodexPath $CodexPath `
        -Guard $guard -LocalOnly $localOnly
    $CodexPath = $gate.codexPath
    if (-not $gate.allowed) {
        $out.events += ,@($gate.event)
        return $out
    }
    $profile = $gate.profile

    # Durable claim (CQK-013 distributed / CQK-023 local): CLAIMED is written
    # before the model call, by both backings, and any existing claim - whatever
    # its state - blocks execution. The runner lock and state.processedEventIds
    # are fast paths only: both are written AFTER the call returns, so a crash
    # between exec and persist would otherwise pay for the same model call twice.
    # Lease revalidation stays distributed-only: localOnly election has no lease.
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

    # The Codex binary was already proven present by Get-AnchorProfileGate - a
    # missing executable cannot reach this line, which is the point: the gate is
    # what §8 puts between "should anchor" and "claimed an event".

    # ---- ANCHORING: one minimal exec in an empty work dir --------------------
    if ($localOnly) {
        $out.events += ,@{ event = 'ANCHOR_LOCAL'; reason = 'coordination disabled; durable local claim file only' }
    }
    $workDir = Join-Path (Get-RuntimeDir $KeeperRoot) 'anchor-work'
    Ensure-Directory $workDir | Out-Null
    $anchorCfgExec = Get-AutoAnchorConfig $Config
    # The exec pair comes from the VALIDATED Profile, not from a fresh config read:
    # Get-ExecutionProfileExecArgs passes only what config.json configured (the
    # Profile proves the call, it never rewrites it), but taking it from $profile is
    # what makes §9.1's three-surface identity hold by construction - the value
    # audited, the value validated and the value typed into the process are read off
    # one object, so nothing can drift between the gate and the call.
    $execPair = Get-ExecutionProfileExecArgs -Profile $profile
    $execInfo = Get-AnchorExecCommand -CodexPath $CodexPath -Prompt ([string]$anchorCfgExec.prompt) `
        -Model $execPair.model -ReasoningEffort $execPair.reasoningEffort
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
