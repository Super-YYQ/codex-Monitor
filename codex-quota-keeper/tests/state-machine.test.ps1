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
