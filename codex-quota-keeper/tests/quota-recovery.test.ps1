# Offline regressions for rolling idle predictions and early quota recovery.
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'state-machine.ps1')
. (Join-Path $scriptDir 'anchor-alarm.ps1')

function New-RecoveryBucket {
    param([long]$Reset, [double]$Used = 0, [string]$Type = 'primary')
    $minutes = if ($Type -eq 'primary') { 300 } else { 10080 }
    return ,@(@{ bucketId = 'codex'; windows = @(@{
        windowType = $Type; windowDurationMins = $minutes; usedPercent = $Used
        resetsAt = $Reset; usable = $true
    }) })
}

function Set-RecoveryObservation {
    param($State, $Buckets, [datetime]$Now)
    Update-ExpiryTrack -State $State -Buckets $Buckets -Now $Now
    $State.buckets = $Buckets
    $State.lastGoodReadAt = $Now.ToString('o')
}

function New-RecoveryTime {
    param([string]$Text)
    return [datetime]::SpecifyKind([datetime]::Parse($Text), [DateTimeKind]::Local)
}

$cfg = New-TestConfig @{
    mode = 'AutoAnchor'
    github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
    codex = @{ autoAnchor = @{ enabled = $true; maxPerDay = 6; minimumGapMinutes = 300; schedule = @('09:00'); anchorOnExpiry = @() } }
}
$now = New-RecoveryTime '2026-09-15 09:00:08'
$epoch = ConvertTo-EpochSeconds $now
$slot = Get-ScheduleEventId '2026-09-15' '09:00'

Start-TestGroup 'schedule: a single zero-percent read stays pending; moving predictions confirm idle'
$state = New-KeeperState
Set-RecoveryObservation $state (New-RecoveryBucket ($epoch + 17996)) $now
$first = Test-ShouldAnchor -Config $cfg -State $state -Events @() -IsLeader $true -Now $now
Assert-False $first.should 'one rounded zero-percent read is insufficient to call'
Assert-False (@($state.processedEventIds) -contains $slot) 'uncertain slot is not consumed'
$later = $now.AddMinutes(1)
Set-RecoveryObservation $state (New-RecoveryBucket ($epoch + 18056)) $later
$second = Test-ShouldAnchor -Config $cfg -State $state -Events @() -IsLeader $true -Now $later
Assert-True $second.should 'moving idle prediction allows the still-due schedule'
Assert-Contains $second.eventIds $slot 'scheduled event is retained'

$fixed = New-KeeperState
Set-RecoveryObservation $fixed (New-RecoveryBucket ($epoch + 17996)) $now
Set-RecoveryObservation $fixed (New-RecoveryBucket ($epoch + 17996)) $later
Assert-False (Test-ShouldAnchor -Config $cfg -State $fixed -Events @() -IsLeader $true -Now $later).should 'fixed boundary at zero usage remains running'

Start-TestGroup 'upgrade: use the previous schema-3 snapshot without clearing processed slots'
$legacy = New-KeeperState
$legacy.Remove('windowObservations')
$legacy.buckets = New-RecoveryBucket ($epoch + 17936)
$legacy.lastGoodReadAt = $now.AddMinutes(-1).ToString('o')
$legacy.expiryTrack['codex|primary'] = $epoch + 17936
Set-RecoveryObservation $legacy (New-RecoveryBucket ($epoch + 17996)) $now
Assert-True (Test-ShouldAnchor -Config $cfg -State $legacy -Events @() -IsLeader $true -Now $now).should 'old snapshot can confirm idle on the first upgraded poll'
Add-ProcessedEvent -State $legacy -EventId $slot
Assert-False (Test-ShouldAnchor -Config $cfg -State $legacy -Events @() -IsLeader $true -Now $now).should 'upgrade preserves previously consumed daily slots'

Start-TestGroup 'expiry: replay the same idle period across polls and a state reload'
$expiryCfg = Merge-ConfigDefaults $cfg @{ codex = @{ autoAnchor = @{ schedule = @(); anchorOnExpiry = @('primary') } } }
$state = New-KeeperState
$oldAt = New-RecoveryTime '2026-09-15 02:56:53'
$oldBoundary = ConvertTo-EpochSeconds (New-RecoveryTime '2026-09-15 03:06:48')
Set-RecoveryObservation $state (New-RecoveryBucket $oldBoundary 63) $oldAt
foreach ($clock in @('03:56:53', '04:56:53')) {
    $at = New-RecoveryTime "2026-09-15 $clock"
    Set-RecoveryObservation $state (New-RecoveryBucket ((ConvertTo-EpochSeconds $at) + 17996)) $at
}
$decision = Test-ShouldAnchor -Config $expiryCfg -State $state -Events @() -IsLeader $true -Now $at
$expectedId = Get-ExpiryAnchorEventId 'codex' 'primary' $oldBoundary
Assert-True $decision.should 'confirmed idle after expiry triggers once'
Assert-Contains $decision.eventIds $expectedId 'event identifies the real previous boundary'
foreach ($id in $decision.eventIds) { Add-ProcessedEvent -State $state -EventId $id }
$state.anchors = @{ day = '2026-09-15'; attemptCount = 1; lastAttemptAt = $at.ToString('o') }
$ws = New-TestWorkspace
try {
    Save-KeeperState -Root $ws -State $state
    $state = Load-KeeperState $ws
    $at = New-RecoveryTime '2026-09-15 10:56:53'
    Set-RecoveryObservation $state (New-RecoveryBucket ((ConvertTo-EpochSeconds $at) + 17996)) $at
    Assert-Equal $oldBoundary $state.expiryTrack['codex|primary'] 'idle predictions never replace the real boundary'
    Assert-False (Test-ShouldAnchor -Config $expiryCfg -State $state -Events @() -IsLeader $true -Now $at).should 'same idle period stays deduplicated after minimum gap and reload'
    Assert-Equal 'clear' (Get-AnchorAlarmPlan -Config $expiryCfg -State $state -Now $at).action 'confirmed idle creates no moving expiry timer'

    # A genuinely new used window rearms expiry and its timer.
    $next = (ConvertTo-EpochSeconds $at) + 7200
    Set-RecoveryObservation $state (New-RecoveryBucket $next 1) $at.AddMinutes(1)
    Assert-Equal $next $state.expiryTrack['codex|primary'] 'new activity rearms a new boundary'
    Assert-Equal ($next + 60) (Get-AnchorAlarmPlan -Config $expiryCfg -State $state -Now $at.AddMinutes(1)).targetEpoch 'timer follows real new activity'
} finally { Remove-TestWorkspace $ws }

Start-TestGroup 'early recovery: replay weekly 90 to 10 before the previous expiry'
$before = New-KeeperState
$before.buckets = New-RecoveryBucket 1789806130 90 'secondary'
$current = @{ ok = $true; buckets = (New-RecoveryBucket 1789999608 10 'secondary') }
$recoveryAt = New-RecoveryTime '2026-09-14 22:56:53'
$events = Get-StateEvents -Previous $before -Current $current -Now $recoveryAt
$recovery = @($events | Where-Object { $_.event -eq 'QUOTA_RECOVERED_EARLY' })
Assert-Equal 1 $recovery.Count 'pre-expiry recovery has a dedicated event'
if ($recovery.Count -eq 1) {
    Assert-Equal 'secondary' $recovery[0].quotaChange.windowType 'weekly window identified'
    Assert-Equal 90 $recovery[0].quotaChange.previousUsedPercent 'before usage recorded'
    Assert-Equal 10 $recovery[0].quotaChange.usedPercent 'after usage recorded'
    Assert-Equal 1789806130 $recovery[0].quotaChange.previousResetsAt 'old deadline recorded'
    Assert-Equal 1789999608 $recovery[0].quotaChange.resetsAt 'new deadline recorded'
    Assert-Equal 'unknown' $recovery[0].quotaChange.reason 'does not invent a card redemption'
}
Assert-Equal 0 @($events | Where-Object { $_.event -eq 'WINDOW_RESET_OBSERVED' }).Count 'early recovery is not a natural expiry event'
Set-RecoveryObservation $before $current.buckets $recoveryAt
$weeklyCfg = Merge-ConfigDefaults $expiryCfg @{ codex = @{ autoAnchor = @{ anchorOnExpiry = @('secondary') } } }
Assert-False (Test-ShouldAnchor -Config $weeklyCfg -State $before -Events $events -IsLeader $true -Now $recoveryAt).should 'already used recovered week does not invoke a model'
Assert-Equal 1789999668 (Get-AnchorAlarmPlan -Config $weeklyCfg -State $before -Now $recoveryAt).targetEpoch 'timer replaces the pre-recovery deadline'
$again = Get-StateEvents -Previous $before -Current $current -Now $recoveryAt.AddHours(1)
Assert-Equal 0 @($again | Where-Object { $_.event -eq 'QUOTA_RECOVERED_EARLY' }).Count 'unchanged poll does not duplicate recovery'
$current.buckets = New-RecoveryBucket 1789999608 11 'secondary'
$usage = Get-StateEvents -Previous $before -Current $current -Now $recoveryAt.AddHours(2)
Assert-Equal 0 @($usage | Where-Object { $_.event -eq 'QUOTA_RECOVERED_EARLY' }).Count 'ordinary continued usage is not recovery'

Start-TestGroup 'early recovery: usage-only and boundary-only changes; partial data stays partial'
$before.buckets = New-RecoveryBucket 1789999608 90 'secondary'
$current.buckets = New-RecoveryBucket 1789999608 10 'secondary'
$usageOnly = Get-StateEvents -Previous $before -Current $current -Now $recoveryAt
Assert-Equal 1 @($usageOnly | Where-Object { $_.event -eq 'QUOTA_RECOVERED_EARLY' }).Count 'usage recovery with unchanged deadline is recorded'
$current.buckets = New-RecoveryBucket 1790003208 90 'secondary'
$boundaryOnly = Get-StateEvents -Previous $before -Current $current -Now $recoveryAt
Assert-Equal 1 @($boundaryOnly | Where-Object { $_.event -eq 'QUOTA_RECOVERED_EARLY' }).Count 'real boundary change without a usage drop is recorded'
$current.buckets[0].windows[0].usedPercent = $null
$current.buckets[0].windows[0].resetsAt = $null
$unknown = Get-StateEvents -Previous $before -Current $current -Now $recoveryAt
Assert-Equal 0 @($unknown | Where-Object { $_.event -eq 'QUOTA_RECOVERED_EARLY' }).Count 'null usage and deadline do not invent recovery'

$before.buckets = New-RecoveryBucket ($epoch + 17996)
$current.buckets = New-RecoveryBucket ($epoch + 21596)
$idleEvents = Get-StateEvents -Previous $before -Current $current -Now $now.AddHours(1)
Assert-Equal 0 @($idleEvents | Where-Object { $_.event -eq 'QUOTA_RECOVERED_EARLY' }).Count 'moving idle prediction is not early recovery'

$before.lastGoodReadAt = $now.ToString('o')
$current.buckets = New-RecoveryBucket ($epoch + 39596)
$longIdle = Get-StateEvents -Previous $before -Current $current -Now $now.AddHours(6)
Assert-Equal 0 @($longIdle | Where-Object { $_.event -in @('QUOTA_RECOVERED_EARLY', 'WINDOW_RESET_OBSERVED') }).Count 'a long gap between idle reads does not manufacture a reset'

$result = Get-TestResult
Write-Host "quota-recovery: $($result.checks) checks, $($result.failures) failures"
if ($result.failures -gt 0) { exit 1 }
exit 0
