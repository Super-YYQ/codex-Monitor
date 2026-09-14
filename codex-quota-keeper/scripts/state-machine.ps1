# Codex Quota Keeper - state machine.
# Compares the previous quota snapshot with the current one, emits the events
# defined in the design doc (03 §7) and the audit plan v1.0 (§13):
#   - window key = bucketId + windowType (CQK-003)
#   - eventId    = SHA-256(bucketId|windowType|windowDuration|previousResetsAt|reset)
#   - null window fields skip reset inference but keep partial status
#   - processedEventIds is LOCAL dedup only; cross-machine idempotency is the
#     responsibility of the remote claim (CQK-013)
# Owns runtime/state.json persistence (schema 3, bucket model + expiry tracking).

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

$script:CQK_STATE_SCHEMA = 3

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
        anchors              = (Get-AnchorStatistics)
        expiryTrack          = @{}
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
    $state.anchors = Get-AnchorStatistics $loaded.anchors
    if ($loaded.expiryTrack -is [hashtable]) { $state.expiryTrack = @{} + $loaded.expiryTrack }
    else { $state.expiryTrack = @{} }
    $state.schema = $script:CQK_STATE_SCHEMA
    $state.windows = $null   # legacy key, no longer written
    $state.Remove('pendingAnchorEvents')
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

function Get-ExpiryAnchorEventId {
    # One deterministic trigger per observed expiry. The last non-empty
    # resetsAt changes when the window restarts, naturally arming the next cycle.
    param([string]$BucketId, [string]$WindowType, [long]$LastNonEmptyResetsAt)
    return Get-Sha256Hex "expiry|$BucketId|$WindowType|$LastNonEmptyResetsAt"
}

function Update-ExpiryTrack {
    # Remember future or expired non-empty reset timestamps before the current
    # snapshot is persisted. Missing windows deliberately leave their previous
    # value intact so a mid-cycle disappearance can be anchored once.
    param([hashtable]$State, $Buckets)
    if ($State.expiryTrack -isnot [hashtable]) { $State.expiryTrack = @{} }
    $map = Get-BucketWindowMap @($Buckets)
    foreach ($key in @($map.Keys)) {
        $win = $map[$key]
        if ($null -ne $win.resetsAt -and [long]$win.resetsAt -gt 0) {
            $State.expiryTrack[$key] = [long]$win.resetsAt
        }
    }
}

function Get-LastNonEmptyResetsAt {
    param([hashtable]$State, [string]$BucketId, [string]$WindowType)
    $key = Get-WindowKey $BucketId $WindowType
    if ($State.expiryTrack -is [hashtable] -and $State.expiryTrack.ContainsKey($key)) {
        return [long]$State.expiryTrack[$key]
    }
    $map = Get-BucketWindowMap @($State.buckets)
    if ($map.ContainsKey($key) -and $null -ne $map[$key].resetsAt) {
        return [long]$map[$key].resetsAt
    }
    return [long]0
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
    # The external seam for all anchor decisions. Callers provide the latest
    # successful snapshot in State; this function collects independent schedule
    # and expiry triggers, while keeping all fail-closed policy in one place.
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

    if ($State.stale) { return & $deny 'quota snapshot is stale; anchor fails closed' }
    # No open errors: 429 / auth / schema unknown / usage limit block anchoring.
    foreach ($ev in @($Events)) {
        if ($null -eq $ev) { continue }
        if ($ev.event -eq 'READ_FAILED') { return & $deny 'quota read failed this cycle; anchor fails closed' }
        if ($ev.event -in @($script:CQK_EV_LIMIT_REACHED, $script:CQK_EV_AUTH_ERROR, $script:CQK_EV_SCHEMA_UNKNOWN)) {
            return & $deny "open error present: $($ev.event)"
        }
    }
    if ($State.rateLimitReachedType) { return & $deny 'previous state shows rate limit reached' }
    if ($State.schemaUnknown) { return & $deny 'previous state had unknown schema' }

    # Daily cap is always enforced, including explicit forced anchors.
    $anchorCfg = Get-AutoAnchorConfig $Config
    $today = $Now.ToString('yyyy-MM-dd')
    $stats = Get-AnchorStatistics -Anchors $State.anchors -Today $today
    $count = $stats.attemptCount
    if ($count -ge [int]$anchorCfg.maxPerDay) {
        return & $deny "daily anchor cap reached ($count/$($anchorCfg.maxPerDay))"
    }
    # Explicit force wins and bypasses the minimum gap. It does not bypass any
    # safety guard above.
    if ($Force) {
        if ($stats.anchorOnApplyAttempted) { return & $deny 'anchorOnApply already attempted today' }
        $forceId = Get-ForceAnchorEventId -Now $Now
        if (@($State.processedEventIds) -contains $forceId) {
            return & $deny 'forced anchor already executed this minute'
        }
        return @{ should = $true; reason = $null; eventIds = @($forceId); triggerKind = 'force' }
    }

    $pending = @()
    $sources = @()
    $nowEpoch = ConvertTo-EpochSeconds $Now
    $curMap = Get-BucketWindowMap @($State.buckets)

    # Trigger 1: daily schedule. Native Task Scheduler triggers call the same
    # runner, and the poll remains a fallback. A late slot is consumed without a
    # model call. If the primary window is already running, the slot has already
    # achieved its purpose and is also consumed without a call.
    $scheduleIds = @()
    foreach ($slot in @($anchorCfg.schedule)) {
        if ([string]::IsNullOrWhiteSpace([string]$slot)) { continue }
        $slotTime = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$slot, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$slotTime)) { continue }
        $dueAt = $Now.Date.Add($slotTime.TimeOfDay)
        if ($Now -lt $dueAt) { continue }
        $sid = Get-ScheduleEventId -Day $today -Slot ([string]$slot)
        if (@($State.processedEventIds) -contains $sid) { continue }
        if (($Now - $dueAt).TotalMinutes -gt [double](Get-PollConfig $Config).intervalMinutes) {
            Add-ProcessedEvent -State $State -EventId $sid
            continue
        }
        $primaryWindows = @($curMap.Values | Where-Object { [string]$_.windowType -eq 'primary' })
        if ($primaryWindows.Count -eq 0) { continue }
        $primaryRunning = @($primaryWindows | Where-Object { $null -ne $_.resetsAt -and [long]$_.resetsAt -gt $nowEpoch }).Count -gt 0
        if ($primaryRunning) {
            Add-ProcessedEvent -State $State -EventId $sid
            continue
        }
        $scheduleIds += $sid
    }
    if ($scheduleIds.Count -gt 0) {
        $pending += @($scheduleIds)
        $sources += 'schedule'
    }

    # Trigger 2: each configured window type is evaluated independently from the
    # schedule. Iterate current and previously tracked keys so a window removed
    # by a unified reset still produces one deterministic expiry trigger.
    $expiryIds = @()
    foreach ($windowType in @($anchorCfg.anchorOnExpiry)) {
        $keys = @($curMap.Keys | Where-Object { [string]$curMap[$_].windowType -eq [string]$windowType })
        if ($State.expiryTrack -is [hashtable]) {
            $suffix = '|' + [string]$windowType
            $keys += @($State.expiryTrack.Keys | Where-Object { ([string]$_).EndsWith($suffix, [System.StringComparison]::Ordinal) })
        }
        foreach ($key in @($keys | Select-Object -Unique)) {
            $win = if ($curMap.ContainsKey($key)) { $curMap[$key] } else { $null }
            if ($win -and $null -ne $win.resetsAt -and [long]$win.resetsAt -gt $nowEpoch) { continue }
            $bucketId = if ($win) { [string]$win.bucketId } else { ([string]$key).Substring(0, ([string]$key).Length - $suffix.Length) }
            $lastResetsAt = Get-LastNonEmptyResetsAt -State $State -BucketId $bucketId -WindowType ([string]$windowType)
            $eid = Get-ExpiryAnchorEventId -BucketId $bucketId -WindowType ([string]$windowType) -LastNonEmptyResetsAt $lastResetsAt
            if (@($State.processedEventIds) -notcontains $eid) { $expiryIds += $eid }
        }
    }
    if ($expiryIds.Count -gt 0) {
        $pending += @($expiryIds)
        $sources += 'expiry'
    }

    $pending = @($pending | Select-Object -Unique)
    if ($pending.Count -eq 0) { return & $deny 'no due schedule slot and no expired tracked window' }

    # Schedule is an explicit time request and bypasses the gap. Expiry-only
    # calls retain the global gap as a secondary safety brake.
    if ($scheduleIds.Count -eq 0 -and $stats.lastAttemptAt) {
        $last = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$stats.lastAttemptAt, [ref]$last)) {
            $gapMinutes = ($Now - $last.LocalDateTime).TotalMinutes
            if ($gapMinutes -lt [double]$anchorCfg.minimumGapMinutes) {
                return & $deny ("minimum anchor gap not elapsed ({0:n0} < {1} min)" -f $gapMinutes, $anchorCfg.minimumGapMinutes)
            }
        }
    }

    return @{ should = $true; reason = $null; eventIds = $pending; triggerKind = ($sources -join '+') }
}
