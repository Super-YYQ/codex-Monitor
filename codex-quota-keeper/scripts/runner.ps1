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
    [switch]$NoSync
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
foreach ($mod in @('common', 'logger', 'quota-client', 'state-machine', 'github-sync', 'leader-lease', 'preflight')) {
    . (Join-Path $scriptDir "$mod.ps1")
}
if (Test-Path (Join-Path $scriptDir 'auto-anchor.ps1')) {
    . (Join-Path $scriptDir 'auto-anchor.ps1')
}

if (-not $KeeperRoot) { $KeeperRoot = Get-KeeperRoot }
if (-not $ConfigFile) { $ConfigFile = Get-ConfigPath $KeeperRoot }

$script:CqkExitCode = 0

function Write-RunnerLog {
    param([string]$Event, [string]$Level = 'INFO', $Error = $null, $Windows = $null, $Anchor = $null)
    $machine = $script:CqkMachine
    $label = if ($machine -and $machine.label) { [string]$machine.label } else { '' }
    Write-KeeperLog -Root $KeeperRoot -Event $Event -Level $Level `
        -MachineId ($(if ($machine) { [string]$machine.machineId } else { '' })) -MachineLabel $label `
        -Role ($(if ($script:CqkRole) { $script:CqkRole } else { '' })) `
        -Mode ($(if ($script:CqkMode) { $script:CqkMode } else { '' })) `
        -Windows $Windows -Anchor $Anchor -Error $Error
}

try {
    # ---- config ------------------------------------------------------------
    $loaded = Load-Config $ConfigFile
    if ($null -eq $loaded.config -or @($loaded.issues).Count -gt 0) {
        Write-KeeperLog -Root $KeeperRoot -Event 'CONFIG_INVALID' -Level 'ERROR' -MachineId '' `
            -Error ($loaded.issues -join '; ')
        exit 1
    }
    $cfg = $loaded.config
    $script:CqkMode = [string]$cfg.mode

    # ---- local mutual exclusion (two layers, doc 03 §9) --------------------
    $lock = Enter-RunnerLock $KeeperRoot
    if (-not $lock.acquired) {
        Write-KeeperLog -Root $KeeperRoot -Event 'RUNNER_SKIPPED' -MachineId '' `
            -Error 'another runner instance holds the local lock'
        exit 0
    }

    # ---- identity + preflight ---------------------------------------------
    $script:CqkMachine = Get-MachineIdentity -Root $KeeperRoot -Label ([string]$cfg.leader.label)
    $pf = Invoke-Preflight -Config $cfg -KeeperRoot $KeeperRoot
    if (-not $pf.ok) {
        Write-RunnerLog -Event 'PREFLIGHT_FAILED' -Level 'ERROR' -Error ($pf.issues -join '; ')
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
        Write-RunnerLog -Event 'BACKOFF_SKIP' -Error "until $($backoff.until.ToString('yyyy-MM-ddTHH:mm:sszzz')) ($($backoff.reason))"
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
        Write-RunnerLog -Event 'PASSIVE' -Error $election.reason
        exit 0
    }

    # LEADER or DEGRADED: perform the read-only quota poll.
    $read = Invoke-CodexRateLimitsRead -Config $cfg -CodexPath $pf.codexPath
    $events = @()

    if ($read.ok) {
        $events = Get-StateEvents -Previous $state -Current $read -Now (Get-Date)
        $state.stale = $false
        $state.lastGoodReadAt = Get-IsoTimestamp
        $state.buckets = $read.buckets
        $state.rateLimitReachedType = $read.rateLimitReachedType
        $state.schemaUnknown = $read.schemaUnknown
        $state.lastError = $null
    } else {
        # Keep previous windows but mark them stale; never treat stale data as a reset.
        $events = Get-StateEvents -Previous $state -Current $read -Now (Get-Date)
        $state.stale = $true
        $state.lastError = [string]$read.message
        if ($read.errorKind -eq 'AUTH_ERROR') {
            Set-Backoff -Root $KeeperRoot -Minutes 120 -Reason 'auth error'
        } elseif ("$($read.message)" -match '(?i)429|usage.?limit|rate.?limit') {
            Set-Backoff -Root $KeeperRoot -Minutes 60 -Reason '429'
        }
        Write-RunnerLog -Event 'READ_FAILED' -Level 'ERROR' -Error $read.message
    }
    $state.lastReadAt = Get-IsoTimestamp

    # ---- leader changed ------------------------------------------------------
    $newOwnerId = $null
    if ($election.lease) { $newOwnerId = [string]$election.lease.ownerId }
    $lcEvent = Get-LeaderChangedEvent -PreviousOwnerId $previousOwnerId -CurrentOwnerId $newOwnerId
    if ($lcEvent) { $events += $lcEvent }

    # ---- AutoAnchor hook (experimental; module optional, default disabled) ---
    $anchorHistory = @()
    $isLeader = ($election.role -eq 'LEADER' -and $null -ne $election.lease)
    if ($cfg.mode -eq 'AutoAnchor' -and $cfg.codex.autoAnchor -eq $true) {
        if (Get-Command Invoke-AutoAnchorIfNeeded -ErrorAction SilentlyContinue) {
            $anchorOutcome = Invoke-AutoAnchorIfNeeded -Config $cfg -KeeperRoot $KeeperRoot `
                -State $state -Events $events -IsLeader $isLeader -Machine $machine -Election $election
            if ($anchorOutcome -and $anchorOutcome.events) { $events += @($anchorOutcome.events) }
            if ($anchorOutcome -and $anchorOutcome.historyFiles) { $anchorHistory = @($anchorOutcome.historyFiles) }
        } else {
            Write-RunnerLog -Event 'ANCHOR_UNAVAILABLE' -Level 'ERROR' -Error 'autoAnchor enabled but auto-anchor module missing'
        }
    }

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
        Write-RunnerLog -Event ([string]$ev.event) -Level $Level -Error $ev.message
    }

    # ---- sanitized history records (significant events only, doc 03 §12) ----
    $significant = @($events | Where-Object {
            $_ -and $_.event -in @('WINDOW_RESET_OBSERVED', 'LIMIT_REACHED', 'AUTH_ERROR', 'SCHEMA_UNKNOWN', 'LEADER_CHANGED', 'ANCHOR_EXECUTED', 'ANCHOR_ABORTED')
        })
    $historyFiles = @($anchorHistory)
    foreach ($ev in $significant) {
        $record = @{
            event        = [string]$ev.event
            machineId    = [string]$machine.machineId
            machineLabel = [string]$machine.label
            role         = $election.role
            mode         = [string]$cfg.mode
            windows      = $read.windows
            anchor       = $ev.anchor
            error        = $(if ($ev.message) { $ev.message } else { $ev.reason })
        }
        $historyFiles += (Write-HistoryEvent -Root $KeeperRoot -Record $record -When $now)
    }

    $counts = @{}
    foreach ($ev in @($events)) {
        if (-not $ev) { continue }
        $k = [string]$ev.event
        if (-not $counts.ContainsKey($k)) { $counts[$k] = 0 }
        $counts[$k] = $counts[$k] + 1
    }
    if ($counts.Count -gt 0) {
        $historyFiles += (Update-DailySummary -Root $KeeperRoot -Date $now.ToString('yyyy-MM-dd') `
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
        $sync = Sync-HistoryToGitHub -Config $cfg -KeeperRoot $KeeperRoot -FilePaths $historyFiles `
            -CommitMessage $commitMessage -MachineId ([string]$machine.machineId)
        if (-not $sync.ok -and $sync.reason -notin @('disabled', 'nothing-to-sync', 'git-unavailable')) {
            Write-RunnerLog -Event 'SYNC_FAILED' -Error "$($sync.reason): $($sync.detail)"
        }
    }

    Write-RunnerLog -Event 'RUNNER_OK' -Windows $read.windows
    exit 0
} catch {
    try {
        Write-KeeperLog -Root $KeeperRoot -Event 'RUNNER_ERROR' -Level 'ERROR' -MachineId '' `
            -Error ("$($_.Exception.Message) @ $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)")
    } catch { }
    exit 2
} finally {
    try { Exit-RunnerLock $KeeperRoot } catch { }
}
