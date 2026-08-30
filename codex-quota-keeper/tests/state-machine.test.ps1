# Tests for state-machine.ps1: window identification, resetsAt comparison, event
# detection, SHA-256 eventId determinism, anchor guard (idempotency/cap/gap/fail-closed).

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'state-machine.ps1')

function New-Window {
    param([string]$Name, [long]$Minutes, [double]$Used, [long]$ResetsAt)
    return @{ name = $Name; minutes = $Minutes; usedPercent = $Used; resetsAt = $ResetsAt }
}

function New-ReadOk {
    param($Windows, [string]$LimitType = $null)
    return @{ ok = $true; windows = $Windows; rateLimitReachedType = $LimitType; schemaUnknown = $false; errorKind = $null; message = $null }
}

$now = [DateTime]::Parse('2026-08-30 12:00:00')
$nowEpoch = ConvertTo-EpochSeconds $now
$future1 = $nowEpoch + 3600        # current window resets in 1h
$future2 = $nowEpoch + 7200

Start-TestGroup 'events: first observation produces baseline snapshot only'

$prev = New-KeeperState
$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @((New-Window 'primary' 300 25 $future1))) -Now $now
Assert-Equal 1 @($events).Count 'single event on first observation'
Assert-Equal 'QUOTA_SNAPSHOT_CHANGED' $events[0].event 'baseline snapshot event'

Start-TestGroup 'events: no event when nothing changed'

$prev.windows = @((New-Window 'primary' 300 25 $future1), (New-Window 'secondary' 10080 43 ($nowEpoch + 400000)))
$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @((New-Window 'primary' 300 25 $future1), (New-Window 'secondary' 10080 43 ($nowEpoch + 400000)))) -Now $now
Assert-Equal 0 @($events).Count 'silent when identical snapshot'

Start-TestGroup 'events: usedPercent change -> QUOTA_SNAPSHOT_CHANGED'

$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @((New-Window 'primary' 300 31 $future1), (New-Window 'secondary' 10080 43 ($nowEpoch + 400000)))) -Now $now
Assert-Equal 1 @($events).Count 'one snapshot event'
Assert-Equal 'QUOTA_SNAPSHOT_CHANGED' $events[0].event 'snapshot changed'
Assert-True ("$($events[0].details)" -match 'usedPercent') 'detail mentions usedPercent'

Start-TestGroup 'events: resetsAt rescheduled (future) -> snapshot changed, not reset'

$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @((New-Window 'primary' 300 25 $future2), (New-Window 'secondary' 10080 43 ($nowEpoch + 400000)))) -Now $now
Assert-Equal 1 @($events).Count 'one event'
Assert-Equal 'QUOTA_SNAPSHOT_CHANGED' $events[0].event 'future reschedule is not a reset'

Start-TestGroup 'events: expired resetsAt + new window -> WINDOW_RESET_OBSERVED'

$expired = $nowEpoch - 600
$prev.windows = @((New-Window 'primary' 300 100 $expired), (New-Window 'secondary' 10080 43 ($nowEpoch + 400000)))
$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @((New-Window 'primary' 300 3 $future1), (New-Window 'secondary' 10080 43 ($nowEpoch + 400000)))) -Now $now
$resets = @($events | Where-Object { $_.event -eq 'WINDOW_RESET_OBSERVED' })
Assert-Equal 1 @($resets).Count 'reset observed exactly once'
Assert-Equal 300 $resets[0].minutes 'reset window identified by minutes'
Assert-Equal $expired $resets[0].previousResetsAt 'previous resetsAt recorded'
Assert-Equal $future1 $resets[0].resetsAt 'new resetsAt recorded'
$expectedId = Get-Sha256Hex "300|$expired|reset"
Assert-Equal $expectedId $resets[0].eventId 'eventId matches doc format SHA-256(300|prev|reset)'

Start-TestGroup 'events: window disappeared recorded, never inferred as reset'

$prev.windows = @((New-Window 'primary' 300 25 $future1), (New-Window 'secondary' 10080 43 ($nowEpoch + 400000)))
$events = Get-StateEvents -Previous $prev -Current (New-ReadOk @((New-Window 'primary' 300 25 $future1))) -Now $now
Assert-Equal 2 @($events).Count 'disappearance + snapshot change'
Assert-Equal 'WINDOW_DISAPPEARED' $events[0].event 'WINDOW_DISAPPEARED emitted'
Assert-Equal 'secondary' $events[0].windowName 'vanished window named'
$resets = @($events | Where-Object { $_.event -eq 'WINDOW_RESET_OBSERVED' })
Assert-Equal 0 @($resets).Count 'no reset inferred from disappearance'

Start-TestGroup 'events: limit reached and error kinds'

$events = Get-StateEvents -Previous (New-KeeperState) -Current (New-ReadOk @((New-Window 'primary' 300 100 $future1)) -LimitType 'primary') -Now $now
Assert-Contains ($events | ForEach-Object { $_.event }) 'LIMIT_REACHED' 'LIMIT_REACHED emitted'
Assert-Equal 'primary' (@($events | Where-Object { $_.event -eq 'LIMIT_REACHED' })[0].rateLimitReachedType) 'limit type carried'

$failed = @{ ok = $false; windows = @(); rateLimitReachedType = $null; schemaUnknown = $false; errorKind = 'AUTH_ERROR'; message = 'relogin required' }
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
Assert-NotNull $ev 'owner change emits event'
Assert-Equal 'LEADER_CHANGED' $ev.event 'LEADER_CHANGED type'

Start-TestGroup 'eventId: deterministic across window name and machine'

$id1 = Get-AnchorEventId 300 1788062400
$id2 = Get-AnchorEventId 300 1788062400
$id3 = Get-AnchorEventId 10080 1788062400
Assert-Equal $id1 $id2 'same inputs, same id'
Assert-True ($id1 -ne $id3) 'different window minutes -> different id'
Assert-True ($id1 -match '^[0-9a-f]{64}$') 'id is sha256 hex'

Start-TestGroup 'anchor guard: every condition enforced'

$cfg = New-TestConfig @{ mode = 'AutoAnchor'; codex = @{ autoAnchor = $true; anchorPrompt = 'Reply exactly OK.'; maxAnchorsPerDay = 2; minimumAnchorGapMinutes = 60 } }

$state = New-KeeperState
$resetEvent = @(@{ event = 'WINDOW_RESET_OBSERVED'; eventId = 'abc123'; windowName = 'primary'; minutes = 300; previousResetsAt = 1; resetsAt = 2; usedPercent = 1 })

# 1. default config (MonitorOnly / autoAnchor=false) denies
$deny = Test-ShouldAnchor -Config (New-TestConfig) -State $state -Events $resetEvent -IsLeader $true -Now $now
Assert-False $deny.should 'MonitorOnly default denies anchoring'

# 2. not leader denies
$deny = Test-ShouldAnchor -Config $cfg -State $state -Events $resetEvent -IsLeader $false -Now $now
Assert-False $deny.should 'non-leader denied'

# 3. open error events deny (fail closed)
foreach ($errEv in @('LIMIT_REACHED', 'AUTH_ERROR', 'SCHEMA_UNKNOWN')) {
    $deny = Test-ShouldAnchor -Config $cfg -State $state -Events @(@{ event = $errEv }) -IsLeader $true -Now $now
    Assert-False $deny.should "$errEv fails closed"
}

# 4. no pending reset event denies
$deny = Test-ShouldAnchor -Config $cfg -State $state -Events @(@{ event = 'QUOTA_SNAPSHOT_CHANGED' }) -IsLeader $true -Now $now
Assert-False $deny.should 'no reset event -> no anchor'

# 5. already processed eventId (idempotency) denies
$state.processedEventIds = @('abc123')
$deny = Test-ShouldAnchor -Config $cfg -State $state -Events $resetEvent -IsLeader $true -Now $now
Assert-False $deny.should 'processed eventId never re-anchored'

# 6. daily cap denies
$state = New-KeeperState
$state.anchors = @{ day = $now.ToString('yyyy-MM-dd'); count = 2; lastAnchorAt = $null }
$deny = Test-ShouldAnchor -Config $cfg -State $state -Events $resetEvent -IsLeader $true -Now $now
Assert-False $deny.should 'daily cap reached denies'

# 7. minimum gap denies
$state = New-KeeperState
$state.anchors = @{ day = $now.ToString('yyyy-MM-dd'); count = 1; lastAnchorAt = $now.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz') }
$deny = Test-ShouldAnchor -Config $cfg -State $state -Events $resetEvent -IsLeader $true -Now $now
Assert-False $deny.should 'minimum gap not elapsed denies'

# 8. all conditions met -> allow with pending ids
$state = New-KeeperState
$state.anchors = @{ day = $now.AddDays(-1).ToString('yyyy-MM-dd'); count = 2; lastAnchorAt = $now.AddHours(-2).ToString('yyyy-MM-ddTHH:mm:sszzz') }
$allow = Test-ShouldAnchor -Config $cfg -State $state -Events $resetEvent -IsLeader $true -Now $now
Assert-True $allow.should 'valid reset event anchors'
Assert-Contains $allow.eventIds 'abc123' 'pending eventId returned'

# 9. remote unreachable + github enabled -> fail closed even as leader
$allow2 = Test-ShouldAnchor -Config $cfg -State (New-KeeperState) -Events $resetEvent -IsLeader $true -Now $now -RemoteUnreachable 'git fetch failed'
Assert-False $allow2.should 'remote unreachable denies anchoring'

Start-TestGroup 'state: processed ids bounded, roundtrip persisted'

$ws = New-TestWorkspace
try {
    $state = New-KeeperState
    for ($i = 0; $i -lt 260; $i++) { Add-ProcessedEvent -State $state -EventId ("id-$i") }
    Assert-Equal 200 @($state.processedEventIds).Count 'id list capped at 200'
    Assert-Equal 'id-259' $state.processedEventIds[199] 'newest ids kept'

    Save-KeeperState -Root $ws -State $state
    $loaded = Load-KeeperState $ws
    Assert-Equal 200 @($loaded.processedEventIds).Count 'state roundtrip preserves ids'

    # Missing keys in an older state file are filled from defaults.
    $partial = @{ windows = @() }
    Write-JsonFileAtomic (Get-StatePath $ws) $partial
    $loaded2 = Load-KeeperState $ws
    Assert-NotNull $loaded2.anchors 'defaults merged into legacy state'
    Assert-False ([bool]$loaded2.schemaUnknown) 'legacy state gets conservative defaults'
} finally {
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "state-machine.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
