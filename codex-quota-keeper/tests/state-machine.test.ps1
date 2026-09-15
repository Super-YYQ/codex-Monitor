# Tests for the schema-3 state machine and its public anchor-decision interface.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'state-machine.ps1')

$now = [DateTime]::Parse('2026-08-30 12:00:00')
$nowEpoch = ConvertTo-EpochSeconds $now
$future = $nowEpoch + 3600
$expired = $nowEpoch - 600

function New-StateWindow {
    param([string]$WindowType, $Minutes, $Used, $ResetsAt, [string]$BucketId = 'default')
    return @{ windowType = $WindowType; usable = $true; windowDurationMins = $Minutes; usedPercent = $Used; resetsAt = $ResetsAt; bucketId = $BucketId }
}

function New-StateBucket {
    param([string]$BucketId = 'default', $Windows)
    return @{ bucketId = $BucketId; bucketName = $null; planType = $null; windows = $Windows }
}

function New-ReadOk {
    param($Windows, [string]$LimitType = $null, $Buckets = $null)
    return @{ ok = $true; windows = $Windows; buckets = $Buckets; rateLimitReachedType = $LimitType; schemaUnknown = $false; errorKind = $null; message = $null }
}

function New-GuardConfig {
    param($Schedule = @(), $AnchorOnExpiry = @())
    return New-TestConfig @{
        mode = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex = @{ command = 'auto'; queryTimeoutSeconds = 20; autoAnchor = @{
            enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60
            schedule = @($Schedule); anchorOnExpiry = @($AnchorOnExpiry)
        } }
    }
}

function New-GuardState {
    param($PrimaryResetsAt = $future, $SecondaryResetsAt = ($nowEpoch + 400000))
    $state = New-KeeperState
    $state.buckets = @((New-StateBucket 'default' @(
        (New-StateWindow 'primary' 300 10 $PrimaryResetsAt),
        (New-StateWindow 'secondary' 10080 20 $SecondaryResetsAt)
    )))
    Update-ExpiryTrack -State $state -Buckets $state.buckets
    return $state
}

Start-TestGroup 'events: snapshot, reset, disappearance, and failures remain observable'

$first = Get-StateEvents -Previous (New-KeeperState) -Current (New-ReadOk @((New-StateWindow 'primary' 300 25 $future))) -Now $now
Assert-Equal 1 @($first).Count 'first observation emits one aggregate event'
Assert-Equal 'QUOTA_SNAPSHOT_CHANGED' $first[0].event 'first observation is a snapshot change'

$previous = New-GuardState -PrimaryResetsAt $expired
$current = New-ReadOk @((New-StateWindow 'primary' 300 1 $future), (New-StateWindow 'secondary' 10080 20 ($nowEpoch + 400000)))
$events = Get-StateEvents -Previous $previous -Current $current -Now $now
$reset = @($events | Where-Object { $_.event -eq 'WINDOW_RESET_OBSERVED' })
Assert-Equal 1 $reset.Count 'reset observation remains available for audit'
Assert-Equal (Get-AnchorEventId 'default' 'primary' 300 $expired) $reset[0].eventId 'reset audit id remains deterministic'

$gone = Get-StateEvents -Previous (New-GuardState) -Current (New-ReadOk @((New-StateWindow 'primary' 300 10 $future))) -Now $now
Assert-Equal 1 @($gone | Where-Object { $_.event -eq 'WINDOW_DISAPPEARED' }).Count 'disappearance remains observable'
Assert-Equal 0 @($gone | Where-Object { $_.event -eq 'WINDOW_RESET_OBSERVED' }).Count 'disappearance never fabricates a reset event'

$failed = @{ ok = $false; errorKind = 'AUTH_ERROR'; message = 'relogin required' }
Assert-Equal 'AUTH_ERROR' (Get-StateEvents -Previous (New-KeeperState) -Current $failed -Now $now)[0].event 'auth failure classified'
$failed.errorKind = 'TIMEOUT'
Assert-Equal 'READ_FAILED' (Get-StateEvents -Previous (New-KeeperState) -Current $failed -Now $now)[0].event 'transient failure classified'

Start-TestGroup 'expiry tracking: deterministic key and state migration'

$track = New-GuardState -PrimaryResetsAt $expired
Assert-Equal $expired (Get-LastNonEmptyResetsAt -State $track -BucketId 'default' -WindowType 'primary') 'last non-empty reset is tracked'
$expiryId = Get-ExpiryAnchorEventId -BucketId 'default' -WindowType 'primary' -LastNonEmptyResetsAt $expired
Assert-Equal $expiryId (Get-ExpiryAnchorEventId 'default' 'primary' $expired) 'expiry id is deterministic'
Assert-True ($expiryId -match '^[0-9a-f]{64}$') 'expiry id is sha256'

$ws = New-TestWorkspace
try {
    Save-KeeperState -Root $ws -State $track
    $loadedState = Load-KeeperState $ws
    Assert-Equal 3 $loadedState.schema 'state schema upgraded to 3'
    Assert-Equal $expired $loadedState.expiryTrack['default|primary'] 'expiry track survives roundtrip'

    $schema2 = @{ schema = 2; buckets = $track.buckets; pendingAnchorEvents = @(@{ eventId = 'old' }); anchors = @{ count = 2 } }
    Write-JsonFileAtomic (Get-StatePath $ws) $schema2
    $migrated = Load-KeeperState $ws
    Assert-Equal 3 $migrated.schema 'schema 2 migrates to schema 3'
    Assert-False $migrated.ContainsKey('pendingAnchorEvents') 'obsolete pending reset queue is discarded'
    Assert-Equal 0 @($migrated.expiryTrack.Keys).Count 'schema 2 starts with an empty expiry track'
    Assert-Equal 2 $migrated.anchors.attemptCount 'legacy anchor attempts migrate conservatively'
} finally { Remove-TestWorkspace $ws }

Start-TestGroup 'anchor guard: fail-closed policy is shared by every trigger'

$expiryCfg = New-GuardConfig -AnchorOnExpiry @('secondary')
$expiredSecondary = New-GuardState -SecondaryResetsAt $expired
Assert-False (Test-ShouldAnchor -Config (New-TestConfig) -State $expiredSecondary -Events @() -IsLeader $true -Now $now).should 'MonitorOnly denies anchoring'
Assert-False (Test-ShouldAnchor -Config $expiryCfg -State $expiredSecondary -Events @() -IsLeader $false -Now $now).should 'non-leader denied'
$expiredSecondary.stale = $true
Assert-False (Test-ShouldAnchor -Config $expiryCfg -State $expiredSecondary -Events @() -IsLeader $true -Now $now).should 'stale snapshot denied'
$expiredSecondary.stale = $false
Assert-False (Test-ShouldAnchor -Config $expiryCfg -State $expiredSecondary -Events @(@{ event = 'READ_FAILED' }) -IsLeader $true -Now $now).should 'read failure denied'
$expiredSecondary.anchors = @{ day = $now.ToString('yyyy-MM-dd'); attemptCount = 6 }
Assert-False (Test-ShouldAnchor -Config $expiryCfg -State $expiredSecondary -Events @() -IsLeader $true -Now $now).should 'daily cap denied'

Start-TestGroup 'anchorOnExpiry: current state, disappearance, and dedup'

$active = New-GuardState
Assert-False (Test-ShouldAnchor -Config $expiryCfg -State $active -Events @() -IsLeader $true -Now $now).should 'running secondary window is not anchored'

$expiredSecondary = New-GuardState -SecondaryResetsAt $expired
$allowExpiry = Test-ShouldAnchor -Config $expiryCfg -State $expiredSecondary -Events @() -IsLeader $true -Now $now
$expectedExpiry = Get-ExpiryAnchorEventId 'default' 'secondary' $expired
Assert-True $allowExpiry.should 'expired configured window anchors'
Assert-Equal 'expiry' $allowExpiry.triggerKind 'expiry trigger kind reported'
Assert-Contains $allowExpiry.eventIds $expectedExpiry 'expiry event id uses tracked reset timestamp'

$expiredSecondary.processedEventIds = @($expectedExpiry)
Assert-False (Test-ShouldAnchor -Config $expiryCfg -State $expiredSecondary -Events @() -IsLeader $true -Now $now).should 'same expiry is processed only once'

$missing = New-GuardState -SecondaryResetsAt $expired
$missing.buckets[0].windows = @($missing.buckets[0].windows | Where-Object { $_.windowType -ne 'secondary' })
$missingAllow = Test-ShouldAnchor -Config $expiryCfg -State $missing -Events @() -IsLeader $true -Now $now
Assert-True $missingAllow.should 'previously tracked window disappearance anchors once'
Assert-Contains $missingAllow.eventIds $expectedExpiry 'disappeared window keeps the prior expiry id'

$nullWindow = New-GuardState
$nullWindow.buckets[0].windows[1].resetsAt = $null
$nullWindow.expiryTrack.Remove('default|secondary')
$nullAllow = Test-ShouldAnchor -Config $expiryCfg -State $nullWindow -Events @() -IsLeader $true -Now $now
Assert-True $nullAllow.should 'present window with empty resetsAt is not running'
Assert-Contains $nullAllow.eventIds (Get-ExpiryAnchorEventId 'default' 'secondary' 0) 'first empty window uses zero fallback deterministically'

Start-TestGroup 'schedule: native slot semantics, lateness bound, and running-window skip'

$scheduleCfg = New-GuardConfig -Schedule @('09:30', '21:00')
$scheduleNow = [DateTime]::Parse('2026-08-30 09:31:00')
$scheduleExpired = ConvertTo-EpochSeconds $scheduleNow.AddMinutes(-1)
$scheduleState = New-GuardState -PrimaryResetsAt $scheduleExpired
$scheduleAllow = Test-ShouldAnchor -Config $scheduleCfg -State $scheduleState -Events @() -IsLeader $true -Now $scheduleNow
$scheduleId = Get-ScheduleEventId '2026-08-30' '09:30'
Assert-True $scheduleAllow.should 'due slot anchors when primary is not running'
Assert-Equal 'schedule' $scheduleAllow.triggerKind 'schedule trigger kind reported'
Assert-Contains $scheduleAllow.eventIds $scheduleId 'daily schedule id returned'

$runningAtSlot = New-GuardState -PrimaryResetsAt (ConvertTo-EpochSeconds $scheduleNow.AddHours(4))
$runningDenied = Test-ShouldAnchor -Config $scheduleCfg -State $runningAtSlot -Events @() -IsLeader $true -Now $scheduleNow
Assert-False $runningDenied.should 'already-running primary skips scheduled model call'
Assert-Contains $runningAtSlot.processedEventIds $scheduleId 'skipped running-window slot is consumed'

$lateState = New-GuardState -PrimaryResetsAt $scheduleExpired
$lateNow = [DateTime]::Parse('2026-08-30 10:31:00')
Assert-False (Test-ShouldAnchor -Config $scheduleCfg -State $lateState -Events @() -IsLeader $true -Now $lateNow).should 'slot over one poll interval late is not executed'
Assert-Contains $lateState.processedEventIds $scheduleId 'late slot is consumed to prevent retry'

Start-TestGroup 'schedule and expiry are independent and coalesce'

$bothCfg = New-GuardConfig -Schedule @('09:30') -AnchorOnExpiry @('secondary')
$bothState = New-GuardState -PrimaryResetsAt $scheduleExpired -SecondaryResetsAt $scheduleExpired
$both = Test-ShouldAnchor -Config $bothCfg -State $bothState -Events @() -IsLeader $true -Now $scheduleNow
Assert-True $both.should 'both independent triggers are eligible'
Assert-Equal 'schedule+expiry' $both.triggerKind 'merged source is explicit'
Assert-Equal 2 @($both.eventIds).Count 'both ids coalesce behind one guard result'

$gapState = New-GuardState -SecondaryResetsAt $expired
$gapState.anchors = @{ day = $now.ToString('yyyy-MM-dd'); attemptCount = 1; lastAttemptAt = $now.AddMinutes(-10).ToString('o') }
Assert-False (Test-ShouldAnchor -Config $expiryCfg -State $gapState -Events @() -IsLeader $true -Now $now).should 'expiry-only observes minimum gap'
$scheduleGap = New-GuardState -PrimaryResetsAt $scheduleExpired
$scheduleGap.anchors = @{ day = '2026-08-30'; attemptCount = 1; lastAttemptAt = $scheduleNow.AddMinutes(-10).ToString('o') }
Assert-True (Test-ShouldAnchor -Config $scheduleCfg -State $scheduleGap -Events @() -IsLeader $true -Now $scheduleNow).should 'schedule bypasses minimum gap'

Start-TestGroup 'reset audit events no longer drive anchoring; force remains explicit'

$resetOnly = @{ event = 'WINDOW_RESET_OBSERVED'; eventId = 'old-reset-id' }
Assert-False (Test-ShouldAnchor -Config (New-GuardConfig) -State (New-GuardState) -Events @($resetOnly) -IsLeader $true -Now $now).should 'reset event alone is audit-only'
$forceState = New-GuardState
$forced = Test-ShouldAnchor -Config (New-GuardConfig) -State $forceState -Events @() -IsLeader $true -Now $now -Force $true
Assert-True $forced.should 'explicit force remains available'
Assert-Equal 'force' $forced.triggerKind 'force trigger kind reported'
$forceId = Get-ForceAnchorEventId $now
Assert-Contains $forced.eventIds $forceId 'force id deterministic per minute'
$forceState.processedEventIds = @($forceId)
Assert-False (Test-ShouldAnchor -Config (New-GuardConfig) -State $forceState -Events @() -IsLeader $true -Now $now -Force $true).should 'same-minute force deduplicated'

Start-TestGroup 'processed event ids remain bounded'

$bounded = New-KeeperState
for ($i = 0; $i -lt 260; $i++) { Add-ProcessedEvent -State $bounded -EventId "id-$i" }
Assert-Equal 200 @($bounded.processedEventIds).Count 'id list capped at 200'
Assert-Equal 'id-259' $bounded.processedEventIds[199] 'newest ids retained'

Start-TestGroup 'window running detection separates an idle prediction from a real open window'

# Observed app-server semantics (D:\codex-quota-keeper logs 2026-09-14/15):
#   window open  -> resetsAt is a FIXED boundary and usedPercent climbs
#   window idle  -> resetsAt is a PREDICTION of now + windowDuration and used is 0
# A prediction is always in the future, so "resetsAt > now" alone cannot mean running.
$fiveHours = 300 * 60

Assert-False (Test-WindowRunning -Window $null -NowEpoch $nowEpoch) 'absent window is not running'
Assert-False (Test-WindowRunning -Window (New-StateWindow 'primary' 300 0 $null) -NowEpoch $nowEpoch) 'empty resetsAt is not running'
Assert-False (Test-WindowRunning -Window (New-StateWindow 'primary' 300 40 $expired) -NowEpoch $nowEpoch) 'past resetsAt is not running'

$openWindow = New-StateWindow 'primary' 300 63 ($nowEpoch + 7606)
Assert-True (Test-WindowRunning -Window $openWindow -NowEpoch $nowEpoch) 'used>0 with a fixed future boundary is running'

$idleExact = New-StateWindow 'primary' 300 0 ($nowEpoch + $fiveHours)
Assert-True (Test-WindowIdlePrediction -Window $idleExact -NowEpoch $nowEpoch) 'used=0 at exactly now+duration is a candidate prediction'
Assert-True (Test-WindowRunning -Window $idleExact -NowEpoch $nowEpoch) 'one zero-usage read cannot prove idle'

# Real reads land a few seconds short of the full duration because the query itself takes time.
$idleLatency = New-StateWindow 'primary' 300 0 ($nowEpoch + $fiveHours - 4)
Assert-True (Test-WindowIdlePrediction -Window $idleLatency -NowEpoch $nowEpoch) 'read latency still reads as a candidate prediction'

$openNoUsage = New-StateWindow 'primary' 300 0 ($nowEpoch + 3600)
Assert-True (Test-WindowRunning -Window $openNoUsage -NowEpoch $nowEpoch) 'boundary well inside the duration is a real open window'

Assert-True (Test-WindowRunning -Window (New-StateWindow 'primary' $null 0 ($nowEpoch + $fiveHours)) -NowEpoch $nowEpoch) 'unknown duration cannot prove idle and stays running'
Assert-True (Test-WindowRunning -Window (New-StateWindow 'primary' 300 $null ($nowEpoch + $fiveHours)) -NowEpoch $nowEpoch) 'unknown usage cannot prove idle and stays running'

Start-TestGroup 'schedule: an idle primary at the slot is the case the slot exists for'

# Reproduces the 2026-09-15 09:00 miss: used=0 and resetsAt=now+5h was consumed as "already running".
$idleCfg = New-GuardConfig -Schedule @('09:30')
$idleNow = [DateTime]::Parse('2026-08-30 09:31:00')
$idleEpoch = ConvertTo-EpochSeconds $idleNow
$idleState = New-GuardState
$idleState.buckets[0].windows[0].usedPercent = 0
$idleState.buckets[0].windows[0].resetsAt = $idleEpoch + $fiveHours - 4
$previousIdle = New-GuardState -PrimaryResetsAt ($idleEpoch + $fiveHours - 64)
$previousIdle.buckets[0].windows[0].usedPercent = 0
Update-ExpiryTrack -State $idleState -Buckets $previousIdle.buckets -Now $idleNow.AddMinutes(-1)
Update-ExpiryTrack -State $idleState -Buckets $idleState.buckets -Now $idleNow
$idleSlotId = Get-ScheduleEventId '2026-08-30' '09:30'
$idleDecision = Test-ShouldAnchor -Config $idleCfg -State $idleState -Events @() -IsLeader $true -Now $idleNow
Assert-True $idleDecision.should 'idle primary at a due slot anchors instead of being skipped'
Assert-Contains $idleDecision.eventIds $idleSlotId 'idle slot returns its schedule event id'

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "state-machine.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
