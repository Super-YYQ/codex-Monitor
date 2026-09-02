# Codex Quota Keeper - state machine.
# Compares the previous quota snapshot with the current one, emits the events
# defined in the design doc (03 §7) and the audit plan v1.0 (§13):
#   - window key = bucketId + windowType (CQK-003)
#   - eventId    = SHA-256(bucketId|windowType|windowDuration|previousResetsAt|reset)
#   - null window fields skip reset inference but keep partial status
#   - processedEventIds is LOCAL dedup only; cross-machine idempotency is the
#     responsibility of the remote claim (CQK-013)
# Owns runtime/state.json persistence (schema 2, bucket model).

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

$script:CQK_STATE_SCHEMA = 2

function New-KeeperState {
    return @{
        schema               = $script:CQK_STATE_SCHEMA
        role                 = ''
        lastReadAt           = $null
        lastGoodReadAt       = $null
        stale                = $false
        buckets              = @()
        rateLimitReachedType = $null
        schemaUnknown        = $false
        lastError            = $null
        consecutiveReadFailures = 0
        processedEventIds    = @()
        anchors              = @{ day = $null; count = 0; lastAnchorAt = $null }
        leader               = @{ ownerId = $null; ownerLabel = $null; expiresAt = $null }
        heartbeat            = @{ ts = $null; role = $null }
        updatedAt            = $null
    }
}

function ConvertTo-StateBuckets {
    # Legacy state migration: schema 1 stored a flat windows[] list (name/minutes/
    # usedPercent/resetsAt). Map it into the bucket model under bucketId 'default'
    # so an upgrade does not fabricate one-shot 'window appeared' events.
    # Unary comma on every return: a single-element array must survive the
    # function-output unroll as an array.
    param($State)
    if ($null -eq $State) { return ,@() }
    if ($State.buckets -is [System.Collections.IEnumerable] -and $State.buckets -isnot [string] -and @($State.buckets).Count -gt 0) {
        return ,@($State.buckets)
    }
    if ($State.windows -is [System.Collections.IEnumerable] -and $State.windows -isnot [string] -and @($State.windows).Count -gt 0) {
        $windows = @()
        foreach ($w in @($State.windows)) {
            if ($w -isnot [hashtable]) { continue }
            $windows += ,@{
                windowType         = [string]$w.name
                usable             = $true
                windowDurationMins = $w.minutes
                usedPercent        = $w.usedPercent
                resetsAt           = $w.resetsAt
            }
        }
        return ,@(@{ bucketId = 'default'; bucketName = $null; planType = $null; windows = $windows })
    }
    return ,@()
}

function Load-KeeperState {
    param([string]$Root)
    $loaded = Read-JsonFile (Get-StatePath $Root)
    if ($null -eq $loaded -or $loaded -isnot [hashtable]) { return New-KeeperState }
    $state = Merge-ConfigDefaults (New-KeeperState) $loaded
    $state.buckets = ConvertTo-StateBuckets $loaded
    $state.schema = $script:CQK_STATE_SCHEMA
    $state.windows = $null   # legacy key, no longer written
    return $state
}

function Save-KeeperState {
    param([string]$Root, [hashtable]$State)
    $State.updatedAt = Get-IsoTimestamp
    Write-JsonFileAtomic (Get-StatePath $Root) $State
}

function Add-ProcessedEvent {
    # Local dedup list, capped so state.json cannot grow forever.
    param([hashtable]$State, [string]$EventId)
    if ([string]::IsNullOrEmpty($EventId)) { return }
    $ids = @($State.processedEventIds | Where-Object { $_ })
    $ids = @($ids + $EventId)
    if ($ids.Count -gt 200) { $ids = @($ids | Select-Object -Last 200) }
    $State.processedEventIds = $ids
}

function Get-WindowKey {
    # Unique window key: bucketId + windowType (CQK-003).
    param([string]$BucketId, [string]$WindowType)
    return "$BucketId|$WindowType"
}

function Get-BucketWindowMap {
    # buckets list -> map keyed by "bucketId|windowType"; each record carries bucketId.
    param($Buckets)
    $map = @{}
    foreach ($b in @($Buckets)) {
        if ($b -isnot [hashtable]) { continue }
        $bucketId = [string]$b.bucketId
        foreach ($w in @($b.windows)) {
            if ($w -isnot [hashtable]) { continue }
            $record = @{} + $w
            $record.bucketId = $bucketId
            $map[(Get-WindowKey $bucketId ([string]$w.windowType))] = $record
        }
    }
    return $map
}

function Get-AnchorEventId {
    # Deterministic across machines (audit plan §13):
    # SHA-256(bucketId|windowType|windowDuration|previousResetsAt|reset)
    param([string]$BucketId, [string]$WindowType, $WindowDuration, [long]$PreviousResetsAt)
    $durationPart = ''
    if ($null -ne $WindowDuration) { $durationPart = "$WindowDuration" }
    return Get-Sha256Hex "$BucketId|$WindowType|$durationPart|$PreviousResetsAt|reset"
}

function Get-KeepaliveEventId {
    # Deterministic per keepalive slot so repeat runs and other machines cannot
    # double-anchor the same idle period. Slot = epoch seconds floored to the
    # keepalive interval (e.g. 300 min -> boundaries every 5h).
    param([int]$KeepaliveMinutes, [DateTime]$Now)
    $intervalSeconds = $KeepaliveMinutes * 60
    $slotSeconds = [long](([Math]::Floor((ConvertTo-EpochSeconds $Now) / $intervalSeconds)) * $intervalSeconds)
    return Get-Sha256Hex "keepalive|$slotSeconds"
}

function Get-IdleDetectionEventId {
    # Scenario-1 idle detection: the keeper never anchored and Codex was never
    # used - after the second observation with zero usage it fires exactly one
    # anchor itself. Day-granularity slot so a stale remote CLAIMED record from
    # a crashed leader self-heals on the next day (the trigger only exists while
    # never-anchored, so a day slot is effectively once-per-lifetime).
    param([DateTime]$Now)
    return Get-Sha256Hex ("idle|" + $Now.ToString('yyyy-MM-dd'))
}

function Get-ScheduleEventId {
    # Daily scheduled anchor (timer mode): one deterministic slot per configured
    # HH:mm per day, so repeat runs and other machines cannot double-fire the
    # same scheduled anchor; the date in the id means a stale remote CLAIMED
    # record self-heals on the next day.
    param([string]$Day, [string]$Slot)
    return Get-Sha256Hex ("schedule|$Day|$Slot")
}

function Get-ForceAnchorEventId {
    # One-shot "anchor right now" (codex.autoAnchor.anchorOnApply -> runner
    # -ForceAnchor): one slot per minute, so back-to-back install/apply-config
    # runs cannot double-fire the same explicit request.
    param([DateTime]$Now)
    $minuteSeconds = [long](([Math]::Floor((ConvertTo-EpochSeconds $Now) / 60)) * 60)
    return Get-Sha256Hex "force|$minuteSeconds"
}

function Get-StateEvents {
    # Returns an ordered list of event hashtables describing the transition
    # from the previous snapshot (state.buckets) to the current read result
    # (flatten windows view carrying bucketId). Null-safe throughout.
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

    $curMap = Get-BucketWindowMap (@($Current.buckets))
    if (@($curMap.Keys).Count -eq 0 -and @($Current.windows).Count -gt 0) {
        # Current snapshot arrived via its flatten view only.
        $curMap = @{}
        foreach ($w in @($Current.windows)) {
            if ($w -is [hashtable]) {
                $windowType = if ($w.name) { [string]$w.name } else { [string]$w.windowType }
                $record = @{} + $w
                $record.windowType = $windowType
                $record.bucketId = [string]$w.bucketId
                $curMap[(Get-WindowKey ([string]$w.bucketId) $windowType)] = $record
            }
        }
    }
    $prevMap = @{}
    if ($Previous) { $prevMap = Get-BucketWindowMap (ConvertTo-StateBuckets $Previous) }

    $nowEpoch = ConvertTo-EpochSeconds $Now
    $changes = @()
    $firstObservation = ($prevMap.Count -eq 0)

    foreach ($key in $curMap.Keys) {
        $cur = $curMap[$key]
        $prev = $prevMap[$key]
        if ($null -eq $prev) {
            if (-not $firstObservation) { $changes += "window '$key' appeared" }
            continue
        }
        $resetObserved = $false
        if ($null -ne $prev.resetsAt -and $null -ne $cur.resetsAt -and
            [long]$prev.resetsAt -lt $nowEpoch -and [long]$cur.resetsAt -gt [long]$prev.resetsAt) {
            # Old window expired and a fresh window started: reset observed.
            $eventId = Get-AnchorEventId -BucketId ([string]$cur.bucketId) -WindowType ([string]$cur.windowType) `
                -WindowDuration $cur.windowDurationMins -PreviousResetsAt ([long]$prev.resetsAt)
            $events += ,@{
                event            = $script:CQK_EV_WINDOW_RESET
                eventId          = $eventId
                bucketId         = [string]$cur.bucketId
                windowType       = [string]$cur.windowType
                windowDuration   = $cur.windowDurationMins
                previousResetsAt = [long]$prev.resetsAt
                resetsAt         = [long]$cur.resetsAt
                usedPercent      = $cur.usedPercent
            }
            $resetObserved = $true
        }
        if (-not $resetObserved -and $null -ne $prev.resetsAt -and $null -ne $cur.resetsAt -and
            [long]$cur.resetsAt -ne [long]$prev.resetsAt) {
            $changes += "window '$key' resetsAt changed"
        }
        if ($null -ne $prev.usedPercent -and $null -ne $cur.usedPercent -and
            [double]$cur.usedPercent -ne [double]$prev.usedPercent) {
            $changes += "window '$key' usedPercent changed"
        }
        if ($null -ne $prev.windowDurationMins -and $null -ne $cur.windowDurationMins -and
            [long]$cur.windowDurationMins -ne [long]$prev.windowDurationMins) {
            $changes += "window '$key' duration changed"
        }
    }

    foreach ($key in $prevMap.Keys) {
        if (-not $curMap.ContainsKey($key)) {
            # Only record; never infer a reset from a vanished window.
            $prev = $prevMap[$key]
            $events += ,@{
                event      = $script:CQK_EV_WINDOW_GONE
                bucketId   = [string]$prev.bucketId
                windowType = [string]$prev.windowType
                minutes    = $prev.windowDurationMins
            }
            $changes += "window '$key' disappeared"
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
    # AutoAnchor guard per audit plan §20. Every condition must hold; any failure
    # returns should=$false with the reason (fail closed). -Force is the explicit
    # "anchor right now" request (anchorOnApply): it bypasses keepalive and the
    # minimum gap - the user asked for an immediate call - but never the daily
    # cap, open errors, or leader/remote checks.
    param(
        [hashtable]$Config,
        [hashtable]$State,
        $Events,
        [bool]$IsLeader,
        [datetime]$Now,
        [string]$RemoteUnreachable = $null,
        [bool]$Force = $false
    )
    $deny = { param($Reason) @{ should = $false; reason = $Reason; eventIds = @() } }

    if ([string]$Config.mode -ne 'AutoAnchor') { return & $deny 'mode is not AutoAnchor' }
    if (-not (Test-AutoAnchorEnabled -Config $Config)) { return & $deny 'codex.autoAnchor is not enabled' }
    if (-not $IsLeader) { return & $deny 'machine does not hold the leader lease' }
    if ($RemoteUnreachable -and (Test-CoordinationEnabled -Config $Config)) {
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

    # Daily cap (always enforced, even for a forced anchor) + minimum gap
    # (bypassed only by an explicit force or a due daily schedule slot).
    $anchorCfg = Get-AutoAnchorConfig $Config
    $today = $Now.ToString('yyyy-MM-dd')
    $day = [string]$State.anchors.day
    $count = [int]$State.anchors.count
    if ($day -ne $today) { $count = 0 }
    if ($count -ge [int]$anchorCfg.maxPerDay) {
        return & $deny "daily anchor cap reached ($count/$($anchorCfg.maxPerDay))"
    }
    $readFailed = $false
    foreach ($ev in @($Events)) {
        if ($ev -and $ev.event -eq 'READ_FAILED') { $readFailed = $true; break }
    }
    # Daily schedule (timer mode): every configured HH:mm fires one anchor on the
    # first poll at/after that time. Pure timer - no idle/reset judgment, no
    # second-observation requirement - and as an explicit user request it also
    # bypasses the minimum gap (the daily cap above still applies). Fails closed
    # on this cycle's read failure, exactly like idle detection.
    $scheduleIds = @()
    foreach ($slot in @($anchorCfg.schedule)) {
        if ([string]::IsNullOrWhiteSpace([string]$slot)) { continue }
        $slotTime = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$slot, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$slotTime)) { continue }
        if ($Now -lt $Now.Date.Add($slotTime.TimeOfDay)) { continue }
        $sid = Get-ScheduleEventId -Day $today -Slot ([string]$slot)
        if (@($State.processedEventIds) -contains $sid) { continue }
        $scheduleIds += $sid
    }
    $scheduleDue = ($scheduleIds.Count -gt 0)
    if ($scheduleDue -and $readFailed) {
        return & $deny 'quota read failed this cycle; scheduled anchor fails closed'
    }
    if ($State.anchors.lastAnchorAt -and -not $Force -and -not $scheduleDue) {
        $last = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$State.anchors.lastAnchorAt, [ref]$last)) {
            $gapMinutes = ($Now - $last.LocalDateTime).TotalMinutes
            if ($gapMinutes -lt [double]$anchorCfg.minimumGapMinutes) {
                return & $deny ("minimum anchor gap not elapsed ({0:n0} < {1} min)" -f $gapMinutes, $anchorCfg.minimumGapMinutes)
            }
        }
    }

    # Triggers. An explicit force wins (the user asked for the CLI right now and
    # even the minimum gap is bypassed); reset events (a real window rollover)
    # and due daily schedule slots come next; then the never-anchored idle
    # detection: Codex was never used, so after the second observation with zero
    # usage the keeper fires the FIRST anchor itself (scenario 1). Once an anchor
    # exists, keepalive is the idle backstop - no anchor within
    # keepaliveIntervalMinutes -> fire (default 300 min = one 5h window).
    $triggerKind = $null
    $pending = @()
    if ($Force) {
        $forceId = Get-ForceAnchorEventId -Now $Now
        if (@($State.processedEventIds) -contains $forceId) {
            return & $deny 'forced anchor already executed this minute'
        }
        $pending = @($forceId)
        $triggerKind = 'force'
    } else {
        $resetPending = $false
        foreach ($ev in @($Events)) {
            if ($null -eq $ev) { continue }
            if ($ev.event -eq $script:CQK_EV_WINDOW_RESET) {
                $processed = @($State.processedEventIds) -contains [string]$ev.eventId
                if (-not $processed) { $pending += [string]$ev.eventId; $resetPending = $true }
            }
        }
        # A due scheduled slot joins the same pending list: one poll carrying both
        # a reset and a due slot performs ONE model call and marks every id
        # (each slot stays at-most-once per day).
        if ($scheduleDue) {
            foreach ($sid in $scheduleIds) {
                if ($pending -notcontains $sid) { $pending += $sid }
            }
        }
        if ($pending.Count -gt 0) {
            $triggerKind = if ($resetPending) { 'reset' } else { 'schedule' }
        } elseif (-not $State.anchors.lastAnchorAt) {
            # Never anchored. The first observation is only a baseline; the idle
            # detection needs a second poll record to conclude "nobody is using
            # Codex", and then fires the first CLI call itself.
            if (-not $State.lastReadAt) {
                return & $deny 'first observation; idle detection needs two poll records'
            }
            if ($readFailed) { return & $deny 'quota read failed this cycle; idle detection fails closed' }
            $primary = @((Get-BucketWindowMap @($State.buckets)).Values | Where-Object { [string]$_.windowType -eq 'primary' } | Select-Object -First 1)
            if ($null -eq $primary -or $null -eq $primary.usedPercent) {
                return & $deny 'quota snapshot unavailable; idle detection fails closed'
            }
            if ([double]$primary.usedPercent -gt 0) {
                return & $deny 'quota in use; idle detection only fires on an unused window'
            }
            $idleId = Get-IdleDetectionEventId -Now $Now
            if (@($State.processedEventIds) -contains $idleId) {
                return & $deny 'idle detection already processed today'
            }
            $pending = @($idleId)
            $triggerKind = 'idle'
        } else {
            $ka = [int]$anchorCfg.keepaliveIntervalMinutes
            if ($ka -le 0) { return & $deny 'no unprocessed reset event' }
            $idleMinutes = [double]::PositiveInfinity
            $last = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse([string]$State.anchors.lastAnchorAt, [ref]$last)) {
                $idleMinutes = ($Now - $last.LocalDateTime).TotalMinutes
            }
            if ($idleMinutes -lt $ka) {
                return & $deny ("keepalive not due ({0:n0} < {1} min idle since last anchor)" -f $idleMinutes, $ka)
            }
            $keId = Get-KeepaliveEventId -KeepaliveMinutes $ka -Now $Now
            if (@($State.processedEventIds) -contains $keId) {
                return & $deny 'keepalive slot already processed'
            }
            $pending = @($keId)
            $triggerKind = 'keepalive'
        }
    }

    return @{ should = $true; reason = $null; eventIds = $pending; triggerKind = $triggerKind }
}
