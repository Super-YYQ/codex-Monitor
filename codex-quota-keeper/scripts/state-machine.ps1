# Codex Quota Keeper - state machine.
# Compares the previous quota snapshot with the current one, emits the events
# defined in the design doc (03 §7), derives idempotent anchor event ids (03 §8)
# and owns runtime/state.json persistence.

$script:CqkStateMachineDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkStateMachineDir 'common.ps1')
}

# Events
$script:CQK_EV_SNAPSHOT_CHANGED  = 'QUOTA_SNAPSHOT_CHANGED'
$script:CQK_EV_WINDOW_RESET      = 'WINDOW_RESET_OBSERVED'
$script:CQK_EV_WINDOW_GONE       = 'WINDOW_DISAPPEARED'
$script:CQK_EV_LIMIT_REACHED     = 'LIMIT_REACHED'
$script:CQK_EV_AUTH_ERROR        = 'AUTH_ERROR'
$script:CQK_EV_SCHEMA_UNKNOWN    = 'SCHEMA_UNKNOWN'
$script:CQK_EV_LEADER_CHANGED    = 'LEADER_CHANGED'

function New-KeeperState {
    return @{
        schema               = 1
        role                 = ''
        lastReadAt           = $null
        lastGoodReadAt       = $null
        stale                = $false
        windows              = @()
        rateLimitReachedType = $null
        schemaUnknown        = $false
        lastError            = $null
        processedEventIds    = @()
        anchors              = @{ day = $null; count = 0; lastAnchorAt = $null }
        leader               = @{ ownerId = $null; ownerLabel = $null; expiresAt = $null }
        heartbeat            = @{ ts = $null; role = $null }
        updatedAt            = $null
    }
}

function Load-KeeperState {
    param([string]$Root)
    $loaded = Read-JsonFile (Get-StatePath $Root)
    if ($null -eq $loaded) { return New-KeeperState }
    if ($loaded -isnot [hashtable]) { return New-KeeperState }
    return Merge-ConfigDefaults (New-KeeperState) $loaded
}

function Save-KeeperState {
    param([string]$Root, [hashtable]$State)
    $State.updatedAt = Get-IsoTimestamp
    Write-JsonFileAtomic (Get-StatePath $Root) $State
}

function Add-ProcessedEvent {
    # Keeps the id list bounded so state.json cannot grow forever.
    param([hashtable]$State, [string]$EventId)
    if ([string]::IsNullOrEmpty($EventId)) { return }
    $ids = @($State.processedEventIds | Where-Object { $_ })
    $ids = @($ids + $EventId)
    if ($ids.Count -gt 200) { $ids = @($ids | Select-Object -Last 200) }
    $State.processedEventIds = $ids
}

function Get-WindowMap {
    # windows list -> hashtable keyed by name
    param($Windows)
    $map = @{}
    foreach ($w in @($Windows)) {
        if ($w -is [hashtable] -and $w.name) { $map[$w.name] = $w }
    }
    return $map
}

function Get-AnchorEventId {
    # Deterministic across machines: SHA-256("<minutes>|<previousResetsAt>|reset")
    param([long]$WindowMinutes, [long]$PreviousResetsAt)
    return Get-Sha256Hex "$WindowMinutes|$PreviousResetsAt|reset"
}

function Get-StateEvents {
    # Returns an ordered list of event hashtables describing the transition
    # from the previous snapshot to the current read result.
    param(
        [hashtable]$Previous,
        [hashtable]$Current,
        [DateTime]$Now
    )
    $events = @()

    if (-not $Current.ok) {
        switch ("$($Current.errorKind)") {
            'AUTH_ERROR' {
                $events += ,@{ event = $script:CQK_EV_AUTH_ERROR; message = [string]$Current.message }
            }
            'SCHEMA_UNKNOWN' {
                $events += ,@{ event = $script:CQK_EV_SCHEMA_UNKNOWN; message = [string]$Current.message }
            }
            default {
                # Transient failures (timeout/EOF/protocol/setup) are logged as errors
                # by the runner but do not advance the window state machine.
                $events += ,@{ event = 'READ_FAILED'; kind = [string]$Current.errorKind; message = [string]$Current.message }
            }
        }
        return ,$events
    }

    $curMap = Get-WindowMap $Current.windows
    $prevMap = @{}
    $nowEpoch = ConvertTo-EpochSeconds $Now
    $changes = @()
    if ($Previous -and $Previous.windows) {
        $prevMap = Get-WindowMap $Previous.windows
    }

    $firstObservation = ($prevMap.Count -eq 0)

    foreach ($name in $curMap.Keys) {
        $cur = $curMap[$name]
        $prev = $prevMap[$name]
        if ($null -eq $prev) {
            if (-not $firstObservation) { $changes += "window '$name' appeared" }
            continue
        }
        $resetObserved = $false
        if ([long]$prev.resetsAt -lt $nowEpoch -and [long]$cur.resetsAt -gt [long]$prev.resetsAt) {
            # Old window has expired and a fresh window started: reset observed.
            $eventId = Get-AnchorEventId ([long]$cur.minutes) ([long]$prev.resetsAt)
            $events += ,@{
                event            = $script:CQK_EV_WINDOW_RESET
                eventId          = $eventId
                windowName       = [string]$name
                minutes          = [long]$cur.minutes
                previousResetsAt = [long]$prev.resetsAt
                resetsAt         = [long]$cur.resetsAt
                usedPercent      = [double]$cur.usedPercent
            }
            $resetObserved = $true
        }
        if (-not $resetObserved -and [long]$cur.resetsAt -ne [long]$prev.resetsAt) {
            $changes += "window '$name' resetsAt changed"
        }
        if ([double]$cur.usedPercent -ne [double]$prev.usedPercent) {
            $changes += "window '$name' usedPercent changed"
        }
        if ([long]$cur.minutes -ne [long]$prev.minutes) {
            $changes += "window '$name' duration changed"
        }
    }

    foreach ($name in $prevMap.Keys) {
        if (-not $curMap.ContainsKey($name)) {
            # Only record; never infer a reset from a vanished window.
            $events += ,@{
                event      = $script:CQK_EV_WINDOW_GONE
                windowName = [string]$name
                minutes    = [long]$prevMap[$name].minutes
            }
            $changes += "window '$name' disappeared"
        }
    }

    if ($firstObservation) {
        $changes += 'first observation'
    }
    if ($changes.Count -gt 0) {
        # One aggregate snapshot event per poll; no event when nothing changed.
        $events += ,@{ event = $script:CQK_EV_SNAPSHOT_CHANGED; details = $changes }
    }

    if ($Current.rateLimitReachedType) {
        $events += ,@{ event = $script:CQK_EV_LIMIT_REACHED; rateLimitReachedType = [string]$Current.rateLimitReachedType }
    }

    return ,$events
}

function Get-LeaderChangedEvent {
    # Emits LEADER_CHANGED when the previously seen lease owner differs from the
    # current one (including takeover after expiry). $null previous owner = first sight.
    param([string]$PreviousOwnerId, [string]$CurrentOwnerId)
    if ([string]::IsNullOrEmpty($CurrentOwnerId)) { return $null }
    if ([string]::IsNullOrEmpty($PreviousOwnerId)) { return $null }
    if ($PreviousOwnerId -eq $CurrentOwnerId) { return $null }
    return @{ event = $script:CQK_EV_LEADER_CHANGED; previousOwnerId = $PreviousOwnerId; ownerId = $CurrentOwnerId }
}

function Test-ShouldAnchor {
    # AutoAnchor guard per doc 03 §8. Every condition must hold; any failure
    # returns should=$false with the reason (fail closed).
    param(
        [hashtable]$Config,
        [hashtable]$State,
        $Events,
        [bool]$IsLeader,
        [datetime]$Now,
        [string]$RemoteUnreachable = $null
    )
    $deny = { param($Reason) @{ should = $false; reason = $Reason; eventIds = @() } }

    if ([string]$Config.mode -ne 'AutoAnchor') { return & $deny 'mode is not AutoAnchor' }
    if ($Config.codex.autoAnchor -ne $true) { return & $deny 'codex.autoAnchor is not enabled' }
    if (-not $IsLeader) { return & $deny 'machine does not hold the leader lease' }
    if ($RemoteUnreachable -and $Config.github.enabled) {
        # Cannot prove exclusive leadership -> never anchor.
        return & $deny "remote coordination unreachable ($RemoteUnreachable); fail closed"
    }

    # No open errors: 429 / auth / schema unknown / usage limit block anchoring.
    foreach ($ev in @($Events)) {
        if ($null -eq $ev) { continue }
        if ($ev.event -in @($script:CQK_EV_LIMIT_REACHED, $script:CQK_EV_AUTH_ERROR, $script:CQK_EV_SCHEMA_UNKNOWN)) {
            return & $deny "open error present: $($ev.event)"
        }
    }
    if ($State.rateLimitReachedType) { return & $deny 'previous state shows rate limit reached' }
    if ($State.schemaUnknown) { return & $deny 'previous state had unknown schema' }

    # Daily cap + minimum gap.
    $today = $Now.ToString('yyyy-MM-dd')
    $day = [string]$State.anchors.day
    $count = [int]$State.anchors.count
    if ($day -ne $today) { $count = 0 }
    if ($count -ge [int]$Config.codex.maxAnchorsPerDay) {
        return & $deny "daily anchor cap reached ($count/$($Config.codex.maxAnchorsPerDay))"
    }
    if ($State.anchors.lastAnchorAt) {
        $last = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$State.anchors.lastAnchorAt, [ref]$last)) {
            $gapMinutes = ($Now - $last.LocalDateTime).TotalMinutes
            if ($gapMinutes -lt [double]$Config.codex.minimumAnchorGapMinutes) {
                return & $deny ("minimum anchor gap not elapsed ({0:n0} < {1} min)" -f $gapMinutes, $Config.codex.minimumAnchorGapMinutes)
            }
        }
    }

    # Collect unprocessed reset events (the only trigger).
    $pending = @()
    foreach ($ev in @($Events)) {
        if ($null -eq $ev) { continue }
        if ($ev.event -eq $script:CQK_EV_WINDOW_RESET) {
            $processed = @($State.processedEventIds) -contains [string]$ev.eventId
            if (-not $processed) { $pending += [string]$ev.eventId }
        }
    }
    if ($pending.Count -eq 0) { return & $deny 'no unprocessed reset event' }

    return @{ should = $true; reason = $null; eventIds = $pending }
}
