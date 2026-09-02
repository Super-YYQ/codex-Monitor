# Codex Quota Keeper - scheduled runner (doc 03 §5 main flow).
# Windows Task Scheduler starts this; it runs once and exits. Never resident.
#
#   LoadConfig -> local mutex -> preflight -> backoff check -> leader election
#     PASSIVE  : heartbeat + exit (no Codex access)
#     LEADER   : read quota -> events -> anchor hook -> persist -> log
#                -> renew lease -> sync sanitized history -> exit
#     DEGRADED : local read still runs (doc 02 state DEGRADED), never claims lease,
#                AutoAnchor blocked by its guard

param(
    [string]$ConfigFile = '',
    [string]$KeeperRoot = '',
    [switch]$NoSync,
    [switch]$ForceAnchor
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
foreach ($mod in @('common', 'logger', 'quota-client', 'state-machine', 'github-sync', 'leader-lease', 'global-backoff', 'preflight')) {
    . (Join-Path $scriptDir "$mod.ps1")
}
if (Test-Path (Join-Path $scriptDir 'auto-anchor.ps1')) {
    . (Join-Path $scriptDir 'auto-anchor.ps1')
}

if (-not $KeeperRoot) { $KeeperRoot = Get-KeeperRoot }
if (-not $ConfigFile) { $ConfigFile = Get-ConfigPath $KeeperRoot }

$script:CqkExitCode = 0
$script:CqkRunId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$script:CqkLogging = @{ retentionDays = 90; includeMachineLabel = $false }

function Write-RunnerLog {
    param([string]$Event, [string]$Level = 'INFO', $ErrorText = $null, [string]$ErrorKind = $null, $Windows = $null, $Anchor = $null)
    $machine = $script:CqkMachine
    $label = if ($machine -and $machine.label) { [string]$machine.label } else { '' }
    Write-KeeperLog -Root $KeeperRoot -Event $Event -Level $Level -RunId $script:CqkRunId `
        -MachineId ($(if ($machine) { [string]$machine.machineId } else { '' })) -MachineLabel $label `
        -Role ($(if ($script:CqkRole) { $script:CqkRole } else { '' })) `
        -Mode ($(if ($script:CqkMode) { $script:CqkMode } else { '' })) `
        -Windows $Windows -Anchor $Anchor -ErrorText $ErrorText -ErrorKind $ErrorKind `
        -LoggingConfig $script:CqkLogging
}

try {
    # ---- config ------------------------------------------------------------
    $loaded = Load-Config $ConfigFile
    if ($null -eq $loaded.config -or @($loaded.issues).Count -gt 0) {
        Write-KeeperLog -Root $KeeperRoot -Event 'CONFIG_INVALID' -Level 'ERROR' -MachineId '' `
            -ErrorText ($loaded.issues -join '; ')
        exit 1
    }
    $cfg = $loaded.config
    $script:CqkMode = [string]$cfg.mode
    $script:CqkLogging = Get-LoggingConfig $cfg

    # ---- local mutual exclusion (two layers, doc 03 §9) --------------------
    $lock = Enter-RunnerLock $KeeperRoot
    if (-not $lock.acquired) {
        $skipText = 'another runner instance holds the local lock'
        if ($lock.detail) { $skipText = "another runner instance holds the local lock ($($lock.detail))" }
        Write-KeeperLog -Root $KeeperRoot -Event 'RUNNER_SKIPPED' -MachineId '' -ErrorText $skipText
        exit 0
    }

    # ---- identity + preflight ---------------------------------------------
    $script:CqkMachine = Get-MachineIdentity -Root $KeeperRoot -Label ([string]$cfg.leader.label)
    $pf = Invoke-Preflight -Config $cfg -KeeperRoot $KeeperRoot
    if (-not $pf.ok) {
        Write-RunnerLog -Event 'PREFLIGHT_FAILED' -Level 'ERROR' -ErrorText ($pf.issues -join '; ')
        $script:CqkExitCode = 1
        exit 1
    }
    $machine = $pf.machine

    # ---- backoff window (429 -> 60m, auth -> 120m) --------------------------
    $backoff = Get-BackoffState $KeeperRoot
    if ($backoff) {
        $script:CqkRole = 'BACKOFF'
        $state = Load-KeeperState $KeeperRoot
        $state.heartbeat = @{ ts = (Get-IsoTimestamp); role = 'BACKOFF' }
        Save-KeeperState -Root $KeeperRoot -State $state
        Write-RunnerLog -Event 'BACKOFF_SKIP' -ErrorText "until $($backoff.until.ToString('yyyy-MM-ddTHH:mm:sszzz')) ($($backoff.reason))"
        exit 0
    }

    # ---- leader election ----------------------------------------------------
    $election = Invoke-LeaderElection -Config $cfg -KeeperRoot $KeeperRoot -Machine $machine
    $script:CqkRole = $election.role

    $state = Load-KeeperState $KeeperRoot
    $previousOwnerId = [string]$state.leader.ownerId

    if ($election.role -eq 'PASSIVE') {
        # Passive machines never touch Codex, never anchor.
        $state.role = 'PASSIVE'
        $state.heartbeat = @{ ts = (Get-IsoTimestamp); role = 'PASSIVE' }
        if ($election.lease) { Save-LocalLeaseView -Root $KeeperRoot -State $state -Election $election }
        Save-KeeperState -Root $KeeperRoot -State $state
        Write-RunnerLog -Event 'PASSIVE' -ErrorText $election.reason
        exit 0
    }

    # ---- global backoff (audit plan §7): lease handover must not bypass it ---
    if ($election.role -eq 'LEADER') {
        $gb = Get-GlobalBackoff -Config $cfg -KeeperRoot $KeeperRoot
        if ($gb.active) {
            # Leader only renews the lease; no Codex access during cluster backoff.
            if ($election.remoteReachable) {
                $renewed = Renew-LeaderLease -Config $cfg -KeeperRoot $KeeperRoot -Machine $machine
                if ($renewed.role -eq 'LEADER' -and $renewed.lease) {
                    Save-LocalLeaseView -Root $KeeperRoot -State $state -Election $renewed
                }
            }
            $state.role = 'BACKOFF'
            $state.heartbeat = @{ ts = (Get-IsoTimestamp); role = 'BACKOFF' }
            Save-KeeperState -Root $KeeperRoot -State $state
            Write-RunnerLog -Event 'GLOBAL_BACKOFF_SKIP' -ErrorText "until $($gb.until.ToString('yyyy-MM-ddTHH:mm:sszzz')) ($($gb.reason), set by $($gb.sourceOwnerId))"
            exit 0
        }
    }

    # LEADER or DEGRADED: perform the read-only quota poll.
    $read = Invoke-CodexRateLimitsRead -Config $cfg -CodexPath $pf.codexPath
    $events = @()

    if ($read.ok) {
        $events = Get-StateEvents -Previous $state -Current $read -Now (Get-Date)
        $state.stale = $false
        $state.lastGoodReadAt = Get-IsoTimestamp
        $state.consecutiveReadFailures = 0
        $state.buckets = $read.buckets
        $state.rateLimitReachedType = $read.rateLimitReachedType
        $state.schemaUnknown = $read.schemaUnknown
        $state.lastError = $null
    } else {
        # Keep previous windows but mark them stale; never treat stale data as a reset.
        $events = Get-StateEvents -Previous $state -Current $read -Now (Get-Date)
        $state.stale = $true
        $state.consecutiveReadFailures = [int]$state.consecutiveReadFailures + 1
        $state.lastError = [string]$read.message
        if ($read.errorKind -eq 'AUTH_ERROR') {
            Set-Backoff -Root $KeeperRoot -Minutes 120 -Reason 'auth error'
            $null = Set-GlobalBackoff -Config $cfg -KeeperRoot $KeeperRoot -Minutes 120 -Reason 'auth_error' -Machine $machine
        } elseif ("$($read.message)" -match '(?i)429|usage.?limit|rate.?limit') {
            Set-Backoff -Root $KeeperRoot -Minutes 60 -Reason '429'
            $null = Set-GlobalBackoff -Config $cfg -KeeperRoot $KeeperRoot -Minutes 60 -Reason '429' -Machine $machine
        }
        # No -f here: the read message may contain '{' (e.g. the JSON-RPC line in
        # a TIMEOUT diagnostic), which would break a String.Format template.
        Write-RunnerLog -Event 'READ_FAILED' -Level 'ERROR' `
            -ErrorText ("$($read.message) (consecutive failures: $($state.consecutiveReadFailures))") `
            -ErrorKind ([string]$read.errorKind)
    }

    # ---- leader changed ------------------------------------------------------
    $newOwnerId = $null
    if ($election.lease) { $newOwnerId = [string]$election.lease.ownerId }
    $lcEvent = Get-LeaderChangedEvent -PreviousOwnerId $previousOwnerId -CurrentOwnerId $newOwnerId
    if ($lcEvent) { $events += $lcEvent }

    # ---- AutoAnchor hook (experimental; module optional, default disabled) ---
    # Local-only election (no coordination repo) returns role=LEADER with a null
    # lease; that is still the single machine, so it may anchor.
    # -ForceAnchor = the explicit "anchor right now" request from install/apply
    # config (codex.autoAnchor.anchorOnApply).
    $isLeader = ($election.role -eq 'LEADER' -and ($null -ne $election.lease -or [bool]$election.localOnly))
    if ($cfg.mode -eq 'AutoAnchor' -and (Test-AutoAnchorEnabled $cfg)) {
        if (Get-Command Invoke-AutoAnchorIfNeeded -ErrorAction SilentlyContinue) {
            $anchorOutcome = Invoke-AutoAnchorIfNeeded -Config $cfg -KeeperRoot $KeeperRoot `
                -State $state -Events $events -IsLeader $isLeader -Machine $machine -Election $election `
                -ForceAnchor:$ForceAnchor
            if ($anchorOutcome -and $anchorOutcome.events) { $events += @($anchorOutcome.events) }
        } else {
            Write-RunnerLog -Event 'ANCHOR_UNAVAILABLE' -Level 'ERROR' -ErrorText 'autoAnchor enabled but auto-anchor module missing'
        }
    }
    # Record the observation AFTER the anchor hook: idle detection must see the
    # PREVIOUS poll record (lastReadAt) to tell a first observation from a second
    # one. State on disk is updated with this run's timestamp either way.
    $state.lastReadAt = Get-IsoTimestamp

    # ---- mark observed reset events processed (idempotency, doc 03 §8) ------
    foreach ($ev in @($events)) {
        if ($ev -and $ev.event -eq 'WINDOW_RESET_OBSERVED' -and $ev.eventId) {
            if (@($state.processedEventIds) -notcontains [string]$ev.eventId) {
                Add-ProcessedEvent -State $state -EventId ([string]$ev.eventId)
            }
        }
    }

    # ---- persist local state + logs ------------------------------------------
    $state.role = $election.role
    $state.heartbeat = @{ ts = (Get-IsoTimestamp); role = $election.role }
    if ($election.lease) { Save-LocalLeaseView -Root $KeeperRoot -State $state -Election $election }
    Save-KeeperState -Root $KeeperRoot -State $state

    $now = Get-Date
    foreach ($ev in @($events)) {
        if (-not $ev) { continue }
        $level = 'INFO'
        if ($ev.event -in @('AUTH_ERROR', 'SCHEMA_UNKNOWN', 'LIMIT_REACHED', 'READ_FAILED')) { $level = 'ERROR' }
        Write-RunnerLog -Event ([string]$ev.event) -Level $Level -ErrorText $ev.message
    }

    # ---- sanitized history records (significant events only, doc 03 §12) ----
    $significant = @($events | Where-Object {
            $_ -and $_.event -in @('WINDOW_RESET_OBSERVED', 'LIMIT_REACHED', 'AUTH_ERROR', 'SCHEMA_UNKNOWN', 'LEADER_CHANGED', 'ANCHOR_EXECUTED', 'ANCHOR_ABORTED')
        })
    foreach ($ev in $significant) {
        $record = @{
            eventId      = $ev.eventId
            event        = [string]$ev.event
            machineId    = [string]$machine.machineId
            machineLabel = [string]$machine.label
            runId        = $script:CqkRunId
            role         = $election.role
            mode         = [string]$cfg.mode
            windows      = $read.windows
            anchor       = $ev.anchor
            errorKind    = $(if ($ev.kind) { $ev.kind } else { $ev.errorKind })
            error        = $(if ($ev.message) { $ev.message } else { $ev.reason })
        }
        # Durable outbox first: the event survives any later sync failure.
        $null = Write-OutboxEvent -Root $KeeperRoot -Record $record -MachineId ([string]$machine.machineId) `
            -RunId $script:CqkRunId -IncludeMachineLabel:([bool]$script:CqkLogging.includeMachineLabel) -When $now
        # Local human-readable JSONL audit copy.
        $null = Write-HistoryEvent -Root $KeeperRoot -Record $record `
            -IncludeMachineLabel:([bool]$script:CqkLogging.includeMachineLabel) -When $now
    }

    $counts = @{}
    foreach ($ev in @($events)) {
        if (-not $ev) { continue }
        $k = [string]$ev.event
        if (-not $counts.ContainsKey($k)) { $counts[$k] = 0 }
        $counts[$k] = $counts[$k] + 1
    }
    $summaryFiles = @()
    if ($counts.Count -gt 0) {
        $summaryFiles += (Update-DailySummary -Root $KeeperRoot -Date $now.ToString('yyyy-MM-dd') `
                -EventCounts $counts -Windows $read.windows -MachineId ([string]$machine.machineId))
    }

    # ---- renew lease (skip when remote is down) ------------------------------
    if ($election.role -eq 'LEADER' -and $election.remoteReachable) {
        $renewed = Renew-LeaderLease -Config $cfg -KeeperRoot $KeeperRoot -Machine $machine
        if ($renewed.role -eq 'LEADER' -and $renewed.lease) {
            Save-LocalLeaseView -Root $KeeperRoot -State $state -Election $renewed
            Save-KeeperState -Root $KeeperRoot -State $state
        }
    }

    # ---- sync sanitized history (failure-isolated, doc 03 §12) ---------------
    if (-not $NoSync) {
        $commitMessage = 'quota: daily summary'
        if (@($significant | Where-Object { $_.event -eq 'ANCHOR_EXECUTED' }).Count -gt 0) {
            $commitMessage = 'quota: anchor executed'
        } elseif (@($significant | Where-Object { $_.event -eq 'WINDOW_RESET_OBSERVED' }).Count -gt 0) {
            $commitMessage = 'quota: reset observed'
        } elseif (@($significant | Where-Object { $_.event -eq 'LEADER_CHANGED' }).Count -gt 0) {
            $commitMessage = 'keeper: leader changed'
        }
        $sync = Sync-OutboxToGitHub -Config $cfg -KeeperRoot $KeeperRoot -Machine $machine -RunId $script:CqkRunId `
            -CommitMessage $commitMessage -SummaryFiles $summaryFiles
        if (-not $sync.ok -and $sync.reason -notin @('disabled', 'push-disabled', 'nothing-to-sync', 'git-unavailable')) {
            Write-RunnerLog -Event 'SYNC_FAILED' -ErrorText "$($sync.reason): $($sync.detail)"
        }
    }

    # Retention cleanup at completion; failure must not affect the core run.
    try {
        $null = Invoke-LogRetention -Root $KeeperRoot -RetentionDays $script:CqkLogging.retentionDays
    } catch {
        Write-RunnerLog -Event 'RETENTION_FAILED' -Level 'ERROR' -ErrorText $_.Exception.Message
    }

    Write-RunnerLog -Event 'RUNNER_OK' -Windows $read.windows
    exit 0
} catch {
    try {
        Write-KeeperLog -Root $KeeperRoot -Event 'RUNNER_ERROR' -Level 'ERROR' -MachineId '' `
            -ErrorText ("$($_.Exception.Message) @ $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)")
    } catch { }
    exit 2
} finally {
    try { Exit-RunnerLock $KeeperRoot } catch { }
}
