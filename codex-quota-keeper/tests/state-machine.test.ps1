# Tests for state-machine.ps1 (CQK-003): bucket+window keying, eventId v2,
# null tolerance, legacy state migration, anchor guard under both config shapes.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'state-machine.ps1')

$now = [DateTime]::Parse('2026-08-30 12:00:00')
$nowEpoch = ConvertTo-EpochSeconds $now
$future1 = $nowEpoch + 3600
$future2 = $nowEpoch + 7200

function New-StateWindow {
    # bucket-model window record (as stored in state.json / read results).
    # Untyped fields so $null stays $null (typed [long]/[double] would coerce to 0).
    param([string]$WindowType, $Minutes, $Used, $ResetsAt, [string]$BucketId = 'default')
    return @{ windowType = $WindowType; usable = $true; windowDurationMins = $Minutes; usedPercent = $Used; resetsAt = $ResetsAt; bucketId = $BucketId }
}

function New-StateBucket {
    param([string]$BucketId = 'default', $Windows)
    return @{ bucketId = $BucketId; bucketName = $null; planType = $null; windows = $Windows }
}

function New-ReadOk {
    # current read result in flatten view (bucketId carried per window)
    param($Windows, [string]$LimitType = $null, $Buckets = $null)
    return @{ ok = $true; windows = $Windows; buckets = $Buckets; rateLimitReachedType = $LimitType; schemaUnknown = $false; errorKind = $null; message = $null }
}

Start-TestGroup 'events: first observation produces baseline snapshot only'

$prev = New-KeeperState
$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @((New-StateWindow 'primary' 300 25 $future1))) -Now $now
Assert-Equal 1 @($events).Count 'single event on first observation'
Assert-Equal 'QUOTA_SNAPSHOT_CHANGED' $events[0].event 'baseline snapshot event'

Start-TestGroup 'events: no event when nothing changed'

$prev.buckets = @((New-StateBucket 'default' @(
    (New-StateWindow 'primary' 300 25 $future1), (New-StateWindow 'secondary' 10080 43 ($nowEpoch + 400000)))))
$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @(
    (New-StateWindow 'primary' 300 25 $future1), (New-StateWindow 'secondary' 10080 43 ($nowEpoch + 400000)))) -Now $now
Assert-Equal 0 @($events).Count 'silent when identical snapshot'

Start-TestGroup 'events: usedPercent change -> QUOTA_SNAPSHOT_CHANGED'

$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @(
    (New-StateWindow 'primary' 300 31 $future1), (New-StateWindow 'secondary' 10080 43 ($nowEpoch + 400000)))) -Now $now
Assert-Equal 1 @($events).Count 'one snapshot event'
Assert-Equal 'QUOTA_SNAPSHOT_CHANGED' $events[0].event 'snapshot changed'
Assert-True ("$($events[0].details)" -match 'usedPercent') 'detail mentions usedPercent'

Start-TestGroup 'events: resetsAt rescheduled (future) -> snapshot changed, not reset'

$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @(
    (New-StateWindow 'primary' 300 25 $future2), (New-StateWindow 'secondary' 10080 43 ($nowEpoch + 400000)))) -Now $now
Assert-Equal 1 @($events).Count 'one event'
Assert-Equal 'QUOTA_SNAPSHOT_CHANGED' $events[0].event 'future reschedule is not a reset'

Start-TestGroup 'events: expired resetsAt + new window -> WINDOW_RESET_OBSERVED (key = bucket+type)'

$expired = $nowEpoch - 600
$prev.buckets = @((New-StateBucket 'default' @(
    (New-StateWindow 'primary' 300 100 $expired), (New-StateWindow 'secondary' 10080 43 ($nowEpoch + 400000)))))
$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @(
    (New-StateWindow 'primary' 300 3 $future1), (New-StateWindow 'secondary' 10080 43 ($nowEpoch + 400000)))) -Now $now
$resets = @($events | Where-Object { $_.event -eq 'WINDOW_RESET_OBSERVED' })
Assert-Equal 1 @($resets).Count 'reset observed exactly once'
Assert-Equal 'default' $resets[0].bucketId 'bucketId recorded'
Assert-Equal 'primary' $resets[0].windowType 'windowType recorded'
Assert-Equal 300 $resets[0].windowDuration 'window duration recorded'
$expectedId = Get-Sha256Hex "default|primary|300|$expired|reset"
Assert-Equal $expectedId $resets[0].eventId 'eventId v2 = SHA-256(bucketId|windowType|duration|prevResetsAt|reset)'

Start-TestGroup 'events: same windowType in different buckets are independent keys'

$prev.buckets = @(
    (New-StateBucket 'bucket-a' @((New-StateWindow 'primary' 300 100 $expired))),
    (New-StateBucket 'bucket-b' @((New-StateWindow 'primary' 300 50 $expired))))
$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @(
    (New-StateWindow 'primary' 300 1 $future1 -BucketId 'bucket-a'),
    (New-StateWindow 'primary' 300 2 $future1 -BucketId 'bucket-b'))) -Now $now
$resets = @($events | Where-Object { $_.event -eq 'WINDOW_RESET_OBSERVED' })
Assert-Equal 2 @($resets).Count 'both buckets reset independently'
$ids = @($resets | ForEach-Object { $_.eventId })
Assert-True ($ids[0] -ne $ids[1]) 'eventIds differ per bucket'

Start-TestGroup 'events: null fields skip reset inference but keep partial status'

$prev.buckets = @((New-StateBucket 'default' @(
    (New-StateWindow 'primary' 300 100 $expired))))
# current has resetsAt=null and duration=null: no crash, no reset, no resetsAt change event
$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @(
    (New-StateWindow 'primary' $null 25 $null))) -Now $now
$resets = @($events | Where-Object { $_.event -eq 'WINDOW_RESET_OBSERVED' })
Assert-Equal 0 @($resets).Count 'null resetsAt never infers reset'
Assert-True (@($events | Where-Object { $_.event -eq 'QUOTA_SNAPSHOT_CHANGED' }).Count -ge 1) 'usedPercent change still reported'
Assert-False ("$($events | ForEach-Object { $_.details })" -match 'resetsAt changed') 'no resetsAt comparison against null'

Start-TestGroup 'events: window disappeared recorded, never inferred as reset'

$prev.buckets = @((New-StateBucket 'default' @(
    (New-StateWindow 'primary' 300 25 $future1), (New-StateWindow 'secondary' 10080 43 ($nowEpoch + 400000)))))
$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @(
    (New-StateWindow 'primary' 300 25 $future1))) -Now $now
Assert-Equal 2 @($events).Count 'disappearance + snapshot change'
Assert-Equal 'WINDOW_DISAPPEARED' $events[0].event 'WINDOW_DISAPPEARED emitted'
Assert-Equal 'default|secondary' "$($events[0].bucketId)|$($events[0].windowType)" 'vanished window identified'
$resets = @($events | Where-Object { $_.event -eq 'WINDOW_RESET_OBSERVED' })
Assert-Equal 0 @($resets).Count 'no reset inferred from disappearance'

Start-TestGroup 'events: limit reached and error kinds'

$events = Get-StateEvents -Previous (New-KeeperState) -Current (New-ReadOk @((New-StateWindow 'primary' 300 100 $future1)) -LimitType 'primary') -Now $now
Assert-Contains ($events | ForEach-Object { $_.event }) 'LIMIT_REACHED' 'LIMIT_REACHED emitted'

$failed = @{ ok = $false; windows = @(); buckets = @(); rateLimitReachedType = $null; schemaUnknown = $false; errorKind = 'AUTH_ERROR'; message = 'relogin required' }
$events = Get-StateEvents -Previous (New-KeeperState) -Current $failed -Now $now
Assert-Equal 'AUTH_ERROR' $events[0].event 'AUTH_ERROR event'
$failed.errorKind = 'SCHEMA_UNKNOWN'
$events = Get-StateEvents -Previous (New-KeeperState) -Current $failed -Now $now
Assert-Equal 'SCHEMA_UNKNOWN' $events[0].event 'SCHEMA_UNKNOWN event'
$failed.errorKind = 'TIMEOUT'
$events = Get-StateEvents -Previous (New-KeeperState) -Current $failed -Now $now
Assert-Equal 'READ_FAILED' $events[0].event 'transient failure is READ_FAILED (state untouched)'

Start-TestGroup 'events: unified reset - both windows renew at once'

$prevUni = New-KeeperState
$prevUni.buckets = @((New-StateBucket 'default' @(
    (New-StateWindow 'primary' 300 100 $expired), (New-StateWindow 'secondary' 10080 100 ($nowEpoch - 1200)))))
$evUni = Get-StateEvents -Previous $prevUni -Current (New-ReadOk @(
    (New-StateWindow 'primary' 300 1 $future2), (New-StateWindow 'secondary' 10080 2 ($nowEpoch + 500000)))) -Now $now
$resetsUni = @($evUni | Where-Object { $_.event -eq 'WINDOW_RESET_OBSERVED' })
Assert-Equal 2 @($resetsUni).Count 'both windows produce a reset event'
Assert-True ($resetsUni[0].eventId -ne $resetsUni[1].eventId) 'distinct event ids per window'
Assert-Equal 'primary' "$($resetsUni[0].windowType)" 'first reset is the primary window'
$cfgUni = New-TestConfig @{ mode = 'AutoAnchor'; codex = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 1; keepaliveIntervalMinutes = 0 } } }
$allowUni = Test-ShouldAnchor -Config $cfgUni -State (New-KeeperState) -Events $evUni -IsLeader $true -Now $now
Assert-True $allowUni.should 'unified reset anchors'
Assert-Equal 2 @($allowUni.eventIds).Count 'both reset ids pending for one call'

Start-TestGroup 'events: LEADER_CHANGED only when owner actually changes'

Assert-Null (Get-LeaderChangedEvent -PreviousOwnerId $null -CurrentOwnerId 'A') 'first sight: no event'
Assert-Null (Get-LeaderChangedEvent -PreviousOwnerId 'A' -CurrentOwnerId 'A') 'same owner: no event'
$ev = Get-LeaderChangedEvent -PreviousOwnerId 'A' -CurrentOwnerId 'B'
Assert-Equal 'LEADER_CHANGED' $ev.event 'owner change emits event'

Start-TestGroup 'eventId: deterministic, keyed by bucket and window'

$id1 = Get-AnchorEventId -BucketId 'default' -WindowType 'primary' -WindowDuration 300 -PreviousResetsAt 1788062400
$id2 = Get-AnchorEventId -BucketId 'default' -WindowType 'primary' -WindowDuration 300 -PreviousResetsAt 1788062400
$id3 = Get-AnchorEventId -BucketId 'default' -WindowType 'secondary' -WindowDuration 10080 -PreviousResetsAt 1788062400
$id4 = Get-AnchorEventId -BucketId 'other' -WindowType 'primary' -WindowDuration 300 -PreviousResetsAt 1788062400
$id5 = Get-AnchorEventId -BucketId 'default' -WindowType 'primary' -WindowDuration $null -PreviousResetsAt 1788062400
Assert-Equal $id1 $id2 'same inputs, same id'
Assert-True ($id1 -ne $id3) 'different windowType -> different id'
Assert-True ($id1 -ne $id4) 'different bucketId -> different id'
Assert-True ($id1 -ne $id5) 'null duration -> different id'
Assert-True ($id1 -match '^[0-9a-f]{64}$') 'id is sha256 hex'

Start-TestGroup 'anchor guard: every condition enforced (v1 config shape)'

$cfg = New-TestConfig @{ mode = 'AutoAnchor'; codex = @{ autoAnchor = $true; anchorPrompt = 'Reply exactly OK.'; maxAnchorsPerDay = 2; minimumAnchorGapMinutes = 60 } }

$state = New-KeeperState
$resetEvent = @(@{ event = 'WINDOW_RESET_OBSERVED'; eventId = 'abc123'; bucketId = 'default'; windowType = 'primary'; windowDuration = 300; previousResetsAt = 1; resetsAt = 2; usedPercent = 1 })

$deny = Test-ShouldAnchor -Config (New-TestConfig) -State $state -Events $resetEvent -IsLeader $true -Now $now
Assert-False $deny.should 'MonitorOnly default denies anchoring'

$deny = Test-ShouldAnchor -Config $cfg -State $state -Events $resetEvent -IsLeader $false -Now $now
Assert-False $deny.should 'non-leader denied'

foreach ($errEv in @('LIMIT_REACHED', 'AUTH_ERROR', 'SCHEMA_UNKNOWN')) {
    $deny = Test-ShouldAnchor -Config $cfg -State $state -Events @(@{ event = $errEv }) -IsLeader $true -Now $now
    Assert-False $deny.should "$errEv fails closed"
}

$deny = Test-ShouldAnchor -Config $cfg -State $state -Events @(@{ event = 'QUOTA_SNAPSHOT_CHANGED' }) -IsLeader $true -Now $now
Assert-False $deny.should 'no reset event -> no anchor'

$state.processedEventIds = @('abc123')
$deny = Test-ShouldAnchor -Config $cfg -State $state -Events $resetEvent -IsLeader $true -Now $now
Assert-False $deny.should 'processed eventId never re-anchored'

$state = New-KeeperState
$state.anchors = @{ day = $now.ToString('yyyy-MM-dd'); count = 2; lastAnchorAt = $null }
$deny = Test-ShouldAnchor -Config $cfg -State $state -Events $resetEvent -IsLeader $true -Now $now
Assert-False $deny.should 'daily cap reached denies'

$state = New-KeeperState
$state.anchors = @{ day = $now.ToString('yyyy-MM-dd'); count = 1; lastAnchorAt = $now.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz') }
$deny = Test-ShouldAnchor -Config $cfg -State $state -Events $resetEvent -IsLeader $true -Now $now
Assert-False $deny.should 'minimum gap not elapsed denies'

$state = New-KeeperState
$state.anchors = @{ day = $now.AddDays(-1).ToString('yyyy-MM-dd'); count = 2; lastAnchorAt = $now.AddHours(-2).ToString('yyyy-MM-ddTHH:mm:sszzz') }
$allow = Test-ShouldAnchor -Config $cfg -State $state -Events $resetEvent -IsLeader $true -Now $now
Assert-True $allow.should 'valid reset event anchors'
Assert-Contains $allow.eventIds 'abc123' 'pending eventId returned'

$allow2 = Test-ShouldAnchor -Config $cfg -State (New-KeeperState) -Events $resetEvent -IsLeader $true -Now $now -RemoteUnreachable 'git fetch failed'
Assert-False $allow2.should 'remote unreachable denies anchoring'

Start-TestGroup 'anchor guard: v2 nested codex.autoAnchor config shape'

$cfgV2 = New-TestConfig @{
    mode  = 'AutoAnchor'
    codex = @{ command = 'auto'; queryTimeoutSeconds = 20; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 3; minimumGapMinutes = 45 } }
}
$aa = Get-AutoAnchorConfig $cfgV2
Assert-True $aa.enabled 'v2 nested autoAnchor enabled'
Assert-Equal 3 $aa.maxPerDay 'v2 maxPerDay'
Assert-Equal 'Reply exactly OK.' $aa.prompt 'v2 prompt'
$allowV2 = Test-ShouldAnchor -Config $cfgV2 -State (New-KeeperState) -Events $resetEvent -IsLeader $true -Now $now
Assert-True $allowV2.should 'guard works with v2 config shape'
$cfgV2Off = New-TestConfig @{ codex = @{ autoAnchor = @{ enabled = $false } } }
Assert-False (Test-AutoAnchorEnabled $cfgV2Off) 'v2 disabled flag respected'

Start-TestGroup 'anchor guard: idle detection - never used Codex, second observation fires once'

$cfgIdle = New-TestConfig @{
    mode  = 'AutoAnchor'
    codex = @{ command = 'auto'; queryTimeoutSeconds = 20; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 300; keepaliveIntervalMinutes = 0 } }
}
$zeroBuckets = @((New-StateBucket 'default' @((New-StateWindow 'primary' 300 0 $future1), (New-StateWindow 'secondary' 10080 0 ($nowEpoch + 400000)))))

# First observation: only a baseline, no second record yet -> no anchor.
$denyIdle1 = Test-ShouldAnchor -Config $cfgIdle -State (New-KeeperState) -Events @() -IsLeader $true -Now $now
Assert-False $denyIdle1.should 'first observation never anchors'
Assert-True ("$($denyIdle1.reason)" -match 'first observation') 'reason says first observation'

# Second record, still zero usage, never anchored -> FIRST anchor fires (keepalive=0!).
$stIdle = New-KeeperState
$stIdle.lastReadAt = '2026-08-29T12:00:00+08:00'
$stIdle.buckets = $zeroBuckets
$allowIdle = Test-ShouldAnchor -Config $cfgIdle -State $stIdle -Events @() -IsLeader $true -Now $now
Assert-True $allowIdle.should 'second observation with zero usage anchors even with keepalive=0'
Assert-Equal 'idle' $allowIdle.triggerKind 'trigger kind reported as idle'
$expectedIdle = Get-IdleDetectionEventId -Now $now
Assert-Contains $allowIdle.eventIds $expectedIdle 'idle eventId deterministic per day'

# Usage > 0: not idle - the rollover trigger will handle it later.
$stUsed = New-KeeperState
$stUsed.lastReadAt = '2026-08-29T12:00:00+08:00'
$stUsed.buckets = @((New-StateBucket 'default' @((New-StateWindow 'primary' 300 25 $future1))))
$denyIdle2 = Test-ShouldAnchor -Config $cfgIdle -State $stUsed -Events @() -IsLeader $true -Now $now
Assert-False $denyIdle2.should 'usage in progress -> idle detection waits'

# Same-day processed idle id -> no second fire.
$stProc = New-KeeperState
$stProc.lastReadAt = '2026-08-29T12:00:00+08:00'
$stProc.processedEventIds = @($expectedIdle)
$stProc.buckets = $zeroBuckets
$denyIdle3 = Test-ShouldAnchor -Config $cfgIdle -State $stProc -Events @() -IsLeader $true -Now $now
Assert-False $denyIdle3.should 'processed idle id denies (once per day)'

# This cycle's read failed -> fail closed.
$stFail = New-KeeperState
$stFail.lastReadAt = '2026-08-29T12:00:00+08:00'
$stFail.buckets = $zeroBuckets
$denyIdle4 = Test-ShouldAnchor -Config $cfgIdle -State $stFail -Events @(@{ event = 'READ_FAILED' }) -IsLeader $true -Now $now
Assert-False $denyIdle4.should 'failed read -> idle detection fails closed'

Start-TestGroup 'anchor guard: keepalive idle backstop (after a first anchor)'

$cfgKa = New-TestConfig @{
    mode  = 'AutoAnchor'
    codex = @{ command = 'auto'; queryTimeoutSeconds = 20; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 300; keepaliveIntervalMinutes = 300 } }
}
$expectedKa = Get-KeepaliveEventId -KeepaliveMinutes 300 -Now $now

# Never anchored is the idle-detection path, not a keepalive trigger.
$denyKa1 = Test-ShouldAnchor -Config $cfgKa -State (New-KeeperState) -Events @() -IsLeader $true -Now $now
Assert-False $denyKa1.should 'never anchored + first observation -> idle detection path, not keepalive'

# Anchored recently -> not due yet.
$stKa2 = New-KeeperState
$stKa2.anchors = @{ day = $now.ToString('yyyy-MM-dd'); count = 1; lastAnchorAt = $now.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz') }
$denyKa2 = Test-ShouldAnchor -Config $cfgKa -State $stKa2 -Events @() -IsLeader $true -Now $now
Assert-False $denyKa2.should 'keepalive not due shortly after an anchor'

# Anchored > 5h ago -> due again, same deterministic slot id.
$stKa3 = New-KeeperState
$stKa3.anchors = @{ day = $now.AddDays(-1).ToString('yyyy-MM-dd'); count = 1; lastAnchorAt = $now.AddHours(-5.2).ToString('yyyy-MM-ddTHH:mm:sszzz') }
$allowKa3 = Test-ShouldAnchor -Config $cfgKa -State $stKa3 -Events @() -IsLeader $true -Now $now
Assert-True $allowKa3.should 'keepalive fires once the interval elapsed'
Assert-Equal 'keepalive' $allowKa3.triggerKind 'trigger kind reported as keepalive'
Assert-Contains $allowKa3.eventIds $expectedKa 'keepalive eventId deterministic per slot'

# Processed slot id -> denied (no double-anchor of the same slot).
$stKa4 = New-KeeperState
$stKa4.anchors = @{ day = $now.ToString('yyyy-MM-dd'); count = 1; lastAnchorAt = $now.AddHours(-6).ToString('yyyy-MM-ddTHH:mm:sszzz') }
$stKa4.processedEventIds = @($expectedKa)
$denyKa4 = Test-ShouldAnchor -Config $cfgKa -State $stKa4 -Events @() -IsLeader $true -Now $now
Assert-False $denyKa4.should 'processed keepalive slot denied'

# keepalive=0 disables the backstop (idle detection remains the never-used path).
$cfgKa0 = New-TestConfig @{ mode = 'AutoAnchor'; codex = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0 } } }
$stKa0 = New-KeeperState
$stKa0.anchors = @{ day = $now.ToString('yyyy-MM-dd'); count = 1; lastAnchorAt = $now.AddHours(-9).ToString('yyyy-MM-ddTHH:mm:sszzz') }
$denyKa0 = Test-ShouldAnchor -Config $cfgKa0 -State $stKa0 -Events @() -IsLeader $true -Now $now
Assert-False $denyKa0.should 'keepalive=0 disables the backstop'

Start-TestGroup 'anchor guard: daily schedule (timer mode)'

$cfgSch = New-TestConfig @{
    mode  = 'AutoAnchor'
    codex = @{ command = 'auto'; queryTimeoutSeconds = 20; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 300; keepaliveIntervalMinutes = 0; schedule = @('09:30', '21:00') } }
}
$schSlot = '09:30'
$schNow = [DateTime]::Parse('2026-08-30 09:45:00')
$schId = Get-ScheduleEventId -Day '2026-08-30' -Slot $schSlot

# Slot not reached yet (09:15) -> falls through to the idle path, no timer fire.
$denySch1 = Test-ShouldAnchor -Config $cfgSch -State (New-KeeperState) -Events @() -IsLeader $true -Now $schNow.AddMinutes(-30)
Assert-False $denySch1.should 'scheduled slot not reached yet'

# Due slot: fires on the very first run - pure timer, no second observation,
# keepalive=0, no reset event.
$allowSch = Test-ShouldAnchor -Config $cfgSch -State (New-KeeperState) -Events @() -IsLeader $true -Now $schNow
Assert-True $allowSch.should 'due schedule slot fires on a run with no history at all'
Assert-Equal 'schedule' $allowSch.triggerKind 'trigger kind reported as schedule'
Assert-Contains $allowSch.eventIds $schId 'schedule eventId deterministic per day+slot'
Assert-Equal 1 @($allowSch.eventIds).Count 'the 21:00 slot is not due yet -> only 09:30 pending'

# Processed same-day slot -> denied.
$stSchProc = New-KeeperState
$stSchProc.processedEventIds = @($schId)
$denySch2 = Test-ShouldAnchor -Config $cfgSch -State $stSchProc -Events @() -IsLeader $true -Now $schNow
Assert-False $denySch2.should 'processed schedule slot denied'

# Explicit user time -> the minimum gap does not apply.
$stSchGap = New-KeeperState
$stSchGap.anchors = @{ day = '2026-08-30'; count = 1; lastAnchorAt = $schNow.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz') }
$allowSchGap = Test-ShouldAnchor -Config $cfgSch -State $stSchGap -Events @() -IsLeader $true -Now $schNow
Assert-True $allowSchGap.should 'due schedule slot bypasses the minimum gap'

# Read failure -> fails closed.
$denySch3 = Test-ShouldAnchor -Config $cfgSch -State (New-KeeperState) -Events @(@{ event = 'READ_FAILED' }) -IsLeader $true -Now $schNow
Assert-False $denySch3.should 'scheduled anchor fails closed on a failed read'

# A reset and a due slot in the same poll -> one allow carrying both ids.
$allowSchRes = Test-ShouldAnchor -Config $cfgSch -State (New-KeeperState) -Events $resetEvent -IsLeader $true -Now $schNow
Assert-True $allowSchRes.should 'reset + due slot both pending in one poll'
Assert-Contains $allowSchRes.eventIds 'abc123' 'reset id pending alongside schedule'
Assert-Contains $allowSchRes.eventIds $schId 'schedule id pending alongside reset'
Assert-Equal 'reset' $allowSchRes.triggerKind 'reset remains the reported kind'

Start-TestGroup 'anchor guard: forced anchor (anchorOnApply)'

# Force fires with keepalive=0 and no reset event at all.
$allowForce = Test-ShouldAnchor -Config $cfgKa0 -State (New-KeeperState) -Events @() -IsLeader $true -Now $now -Force $true
Assert-True $allowForce.should 'force fires with zero keepalive and no reset'
Assert-Equal 'force' $allowForce.triggerKind 'trigger kind reported as force'
$expectedForce = Get-ForceAnchorEventId -Now $now
Assert-Contains $allowForce.eventIds $expectedForce 'force eventId deterministic per minute'

# Force bypasses the minimum gap: anchored 10 min ago, minGap 60, keepalive 0.
$stForce = New-KeeperState
$stForce.anchors = @{ day = $now.ToString('yyyy-MM-dd'); count = 1; lastAnchorAt = $now.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz') }
$allowForce2 = Test-ShouldAnchor -Config $cfgKa0 -State $stForce -Events @() -IsLeader $true -Now $now -Force $true
Assert-True $allowForce2.should 'force bypasses the minimum gap'

# The non-forced guard on the same state still denies (gap + no trigger).
$denyForce0 = Test-ShouldAnchor -Config $cfgKa0 -State $stForce -Events @() -IsLeader $true -Now $now
Assert-False $denyForce0.should 'non-forced guard still denies on the same state'

# Same-minute processed force id -> no double fire.
$stForce2 = New-KeeperState
$stForce2.processedEventIds = @($expectedForce)
$denyForce2 = Test-ShouldAnchor -Config $cfgKa0 -State $stForce2 -Events @() -IsLeader $true -Now $now -Force $true
Assert-False $denyForce2.should 'same-minute force id denied (no double fire)'

# Daily cap still blocks a forced anchor.
$stForce3 = New-KeeperState
$stForce3.anchors = @{ day = $now.ToString('yyyy-MM-dd'); count = 6; lastAnchorAt = $now.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz') }
$denyForce3 = Test-ShouldAnchor -Config $cfgKa0 -State $stForce3 -Events @() -IsLeader $true -Now $now -Force $true
Assert-False $denyForce3.should 'daily cap still blocks a forced anchor'

Start-TestGroup 'state: processed ids bounded, roundtrip persisted, legacy migration'

$ws = New-TestWorkspace
try {
    $state = New-KeeperState
    for ($i = 0; $i -lt 260; $i++) { Add-ProcessedEvent -State $state -EventId ("id-$i") }
    Assert-Equal 200 @($state.processedEventIds).Count 'id list capped at 200'
    Assert-Equal 'id-259' $state.processedEventIds[199] 'newest ids kept'

    Save-KeeperState -Root $ws -State $state
    $loaded = Load-KeeperState $ws
    Assert-Equal 200 @($loaded.processedEventIds).Count 'state roundtrip preserves ids'
    Assert-Equal 2 $loaded.schema 'state schema 2'

    Start-TestGroup 'state: legacy schema-1 windows migrate into default bucket'

    $legacy = @{
        schema = 1
        windows = @(@{ name = 'primary'; minutes = 300; usedPercent = 18; resetsAt = $future1 })
    }
    Write-JsonFileAtomic (Get-StatePath $ws) $legacy
    $migrated = Load-KeeperState $ws
    Assert-Equal 1 @($migrated.buckets).Count 'one default bucket'
    Assert-Equal 'default' $migrated.buckets[0].bucketId 'legacy bucket id'
    Assert-Equal 300 $migrated.buckets[0].windows[0].windowDurationMins 'legacy window migrated'
    Assert-Equal 'primary' $migrated.buckets[0].windows[0].windowType 'legacy windowType'
    Assert-Null $migrated.windows 'legacy key cleared'
} finally {
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "state-machine.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
