# Pending schedules recovered after a read-only retry. All CLI/task calls are
# mocked; the runner and its one-shot scheduling adapter execute unchanged.
$ErrorActionPreference = 'Stop'
$testsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $testsDir 'test-helper.ps1')
$scripts = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scripts 'anchor-alarm.ps1')

function New-ScheduleRecoveryConfig {
    param([string]$Slot = '11:00')
    return New-TestConfig @{
        mode = 'AutoAnchor'
        poll = @{ intervalMinutes = 60; minimumIntervalMinutes = 5 }
        leader = @{ enabled = $true; leaseTtlMinutes = 120; graceMinutes = 5 }
        github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
        codex = @{ command = (Join-Path $testsDir 'fixtures/mock-appserver.ps1'); queryTimeoutSeconds = 5
            autoAnchor = @{ enabled = $true; schedule = @($Slot); anchorOnExpiry = @(); maxPerDay = 6; minimumGapMinutes = 300; model = 'mock-model-alpha' } }
    }
}

function New-ScheduleRecoveryState {
    param([datetime]$Now)
    $state = New-KeeperState
    foreach ($at in @($Now.AddMinutes(-21), $Now)) {
        $buckets = @(@{ bucketId = 'codex-default'; windows = @(@{
            windowType = 'primary'; windowDurationMins = 300; usedPercent = 0
            resetsAt = (ConvertTo-EpochSeconds $at) + 17996; usable = $true
        }) })
        Update-ExpiryTrack -State $state -Buckets $buckets -Now $at
        $state.buckets = $buckets
        $state.lastGoodReadAt = $at.ToString('o')
    }
    return $state
}

$now = [datetime]::SpecifyKind([datetime]::Parse('2026-10-14 11:21:17'), [DateTimeKind]::Local)
$cfg = New-ScheduleRecoveryConfig
$state = New-ScheduleRecoveryState $now
$before = ConvertTo-Json $state -Depth 14 -Compress

Start-TestGroup '11:21 recovery keeps 11:00 pending and schedules a separate normal check'
$plan = Get-AnchorAlarmPlan -Config $cfg -State $state -Now $now -RecoverPendingSchedule
Assert-Equal 'set' $plan.action 'schedule-only configurations recover without an expiry trigger'
Assert-Equal ((ConvertTo-EpochSeconds $now) + 60) $plan.targetEpoch 'normal check leaves enough time for the next idle observation'
Assert-True ([bool]$plan.scheduleRecovery) 'the normal check is identified as a recovery'
Assert-Equal $before (ConvertTo-Json $state -Depth 14 -Compress) 'planning does not consume a pending slot'
Assert-Equal 'clear' (Get-AnchorAlarmPlan -Config $cfg -State $state -Now $now).action 'ordinary reads do not repeatedly arm recovery'
Assert-Equal 'clear' (Get-AnchorAlarmPlan (New-ScheduleRecoveryConfig '11:22') $state $now -RecoverPendingSchedule).action 'a future slot is not a pending recovered schedule'

Start-TestGroup 'recovery preserves schedule deadlines and active/processed/error guards'
$processed = ConvertTo-HashtableDeep $state
Add-ProcessedEvent -State $processed -EventId (Get-ScheduleEventId '2026-10-14' '11:00')
Assert-Equal 'clear' (Get-AnchorAlarmPlan $cfg $processed $now -RecoverPendingSchedule).action 'attempted schedules stay deduplicated'
$active = ConvertTo-HashtableDeep $state
$active.buckets[0].windows[0].usedPercent = 1
Assert-Equal 'clear' (Get-AnchorAlarmPlan $cfg $active $now -RecoverPendingSchedule).action 'user activity prevents another model call'
$uncertain = ConvertTo-HashtableDeep $state
$uncertain.windowObservations['codex-default|primary'].idleConfirmed = $false
Assert-Equal 'clear' (Get-AnchorAlarmPlan $cfg $uncertain $now -RecoverPendingSchedule).action 'uncertain zero usage still fails closed'
foreach ($field in @('stale', 'schemaUnknown', 'rateLimitReachedType')) {
    $blocked = ConvertTo-HashtableDeep $state
    $blocked[$field] = $(if ($field -eq 'rateLimitReachedType') { 'primary' } else { $true })
    Assert-Equal 'clear' (Get-AnchorAlarmPlan $cfg $blocked $now -RecoverPendingSchedule).action "$field blocks recovery"
}
$capped = ConvertTo-HashtableDeep $state
$capped.anchors = @{ day = '2026-10-14'; attemptCount = 6 }
Assert-Equal 'clear' (Get-AnchorAlarmPlan $cfg $capped $now -RecoverPendingSchedule).action 'daily attempt cap is preserved'
$late = [datetime]::SpecifyKind([datetime]::Parse('2026-10-14 11:59:58'), [DateTimeKind]::Local)
Assert-Equal 'clear' (Get-AnchorAlarmPlan $cfg (New-ScheduleRecoveryState $late) $late -RecoverPendingSchedule).action 'do not arm a check beyond the catch-up deadline'
$expiredBefore = ConvertTo-Json $state -Depth 14 -Compress
Assert-Equal 'clear' (Get-AnchorAlarmPlan $cfg $state $now.AddHours(1) -RecoverPendingSchedule).action 'expired schedules are not revived'
Assert-Equal $expiredBefore (ConvertTo-Json $state -Depth 14 -Compress) 'expired planning also leaves live state untouched'

Start-TestGroup 'existing weekly alarm is restored after the one-shot recovery'
$weeklyCfg = ConvertTo-HashtableDeep $cfg
$weeklyCfg.codex.autoAnchor.anchorOnExpiry = @('secondary')
$weekly = ConvertTo-HashtableDeep $state
$weekReset = (ConvertTo-EpochSeconds $now) + 3600
$weekly.buckets[0].windows += @{ windowType = 'secondary'; windowDurationMins = 10080; usedPercent = 6; resetsAt = $weekReset }
Assert-Equal ((ConvertTo-EpochSeconds $now) + 60) (Get-AnchorAlarmPlan $weeklyCfg $weekly $now -RecoverPendingSchedule).targetEpoch 'recovery runs before the later weekly boundary'
Assert-Equal ($weekReset + 60) (Get-AnchorAlarmPlan $weeklyCfg $weekly $now).targetEpoch 'normal reconciliation keeps the weekly alarm'

$ws = New-TestWorkspace
$hostExe = (Get-Process -Id $PID).Path
$saved = @{}
foreach ($key in @('CQK_MOCK_MODE','CQK_MOCK_POST_EXEC_MODE','CQK_MOCK_EXEC','CQK_MOCK_EXEC_ARGS_FILE')) {
    $saved[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    # The wrapper supplies only the Task Scheduler API seam. Registration is
    # written to the temporary workspace and never reaches Windows tasks.
    $wrapper = Join-Path $ws 'run-with-mock-tasks.ps1'
    $wrapperText = @'
param($Runner, $Root, [switch]$Retry, [switch]$Recovery, [switch]$Force)
$ErrorActionPreference = 'Stop'
$env:CQK_TEST_TASK_WRITES = Join-Path $Root 'task-writes.jsonl'
function Get-ScheduledTask { param($TaskName, $ErrorAction) return $null }
function New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory) return @{ Execute=$Execute; Arguments=$Argument; WorkingDirectory=$WorkingDirectory } }
function New-ScheduledTaskTrigger { param([switch]$Once, $At) return @{ At=$At } }
function New-ScheduledTaskSettingsSet { param($MultipleInstances,$ExecutionTimeLimit,$StartWhenAvailable,$AllowStartIfOnBatteries,$DontStopIfGoingOnBatteries,$WakeToRun,$RunOnlyIfNetworkAvailable) return @{} }
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) return @{} }
function Register-ScheduledTask {
    param($TaskName,$Action,$Trigger,$Settings,$Principal,$Description,[switch]$Force)
    $record = @{ name=$TaskName; action=$Action; trigger=$Trigger }
    [IO.File]::AppendAllText($env:CQK_TEST_TASK_WRITES, (ConvertTo-Json $record -Depth 6 -Compress) + [Environment]::NewLine)
}
function Unregister-ScheduledTask { param($TaskName,[switch]$Confirm) }
$arguments = @{ KeeperRoot=$Root; ConfigFile=(Join-Path $Root 'config.json'); NoSync=$true }
if ($Retry) { $arguments.ReadOnlyRetry=$true }
if ($Recovery) { $arguments.ScheduleRecovery=$true }
if ($Force) { $arguments.ForceAnchor=$true }
& $Runner @arguments
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($wrapper, $wrapperText, (New-Object Text.UTF8Encoding($false)))

    function Invoke-ScheduleRecoveryRunner {
        param([string]$Root, [switch]$Retry, [switch]$Recovery, [switch]$Force)
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper,'-Runner',(Join-Path $scripts 'runner.ps1'),'-Root',$Root)
        if ($Retry) { $arguments += '-Retry' }
        if ($Recovery) { $arguments += '-Recovery' }
        if ($Force) { $arguments += '-Force' }
        $output = & $hostExe @arguments 2>&1
        Assert-Equal 0 $LASTEXITCODE "mocked runner completes ($output)"
        if ($LASTEXITCODE -ne 0) {
            Get-ChildItem -LiteralPath (Join-Path $Root 'runtime/logs') -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
                Get-Content -LiteralPath $_.FullName | ForEach-Object { $entry = ConvertFrom-JsonSafe $_; if ($entry.error) { Write-Host "$($entry.event): $($entry.error)" } }
            }
        }
    }

    Start-TestGroup 'real runner: retry is model-free; recovery rechecks and executes the slot once'
    $root = Join-Path $ws 'pending'
    Ensure-Directory $root | Out-Null
    $liveCfg = New-ScheduleRecoveryConfig (Get-Date).ToString('HH:mm')
    Write-TestConfigFile (Join-Path $root 'config.json') $liveCfg | Out-Null
    $seed = New-ScheduleRecoveryState ((Get-Date).AddMinutes(-21))
    $seed.windowObservations['codex-default|primary'].idleConfirmed = $false
    $seed.stale = $true
    Save-KeeperState -Root $root -State $seed
    $env:CQK_MOCK_MODE = 'rolling-idle'; $env:CQK_MOCK_EXEC = 'ok'; $env:CQK_MOCK_POST_EXEC_MODE = 'reset'
    $env:CQK_MOCK_EXEC_ARGS_FILE = Join-Path $root 'model-calls.txt'
    Invoke-ScheduleRecoveryRunner $root -Retry -Force
    Assert-False (Test-Path $env:CQK_MOCK_EXEC_ARGS_FILE) 'even forced read-only retry never calls the model'
    $taskFile = Join-Path $root 'task-writes.jsonl'
    $tasks = @()
    if (Test-Path $taskFile) { $tasks = @(Get-Content $taskFile | ForEach-Object { ConvertFrom-JsonSafe $_ }) }
    Assert-Equal 1 $tasks.Count 'recovered schedule-only runner arranges exactly one alarm'
    if ($tasks.Count) {
        Assert-Equal "$($liveCfg.task.name).AnchorAlarm" $tasks[0].name 'recovery reuses the existing alarm task'
        $launcher = [IO.File]::ReadAllText((Join-Path $root 'runtime/hidden-launch-anchor-alarm.vbs'))
        Assert-True ($launcher -match '-ScheduleRecovery') 'scheduled action runs the normal recovery path'
        Assert-False ($launcher -match '-ReadOnlyRetry|-ForceAnchor') 'normal recovery cannot force or remain read-only'
    }
    # Advance the prior observation by the scheduled minute without sleeping.
    # The next real runner read still exercises the rolling-prediction guard.
    $recovered = Load-KeeperState $root
    Assert-True $recovered.windowObservations['codex-default|primary'].idleConfirmed 'retry confirms the 11:00-style idle candidate'
    $recovered.windowObservations['codex-default|primary'].observedAt -= 60
    $recovered.windowObservations['codex-default|primary'].resetsAt -= 60
    $recovered.buckets[0].windows[0].resetsAt -= 60
    $recovered.lastGoodReadAt = (Get-Date).AddMinutes(-1).ToString('o')
    Save-KeeperState -Root $root -State $recovered
    Invoke-ScheduleRecoveryRunner $root -Recovery
    Assert-Equal 1 @(Get-Content $env:CQK_MOCK_EXEC_ARGS_FILE -ErrorAction SilentlyContinue).Count 'the previously unattempted slot executes once'
    Invoke-ScheduleRecoveryRunner $root -Recovery
    Assert-Equal 1 @(Get-Content $env:CQK_MOCK_EXEC_ARGS_FILE -ErrorAction SilentlyContinue).Count 'repeated wakeups do not retry the processed slot'

    Start-TestGroup 'real runner: user activity before recovery prevents the pending call'
    $activeRoot = Join-Path $ws 'user-active'
    Ensure-Directory $activeRoot | Out-Null
    Write-TestConfigFile (Join-Path $activeRoot 'config.json') $liveCfg | Out-Null
    $env:CQK_MOCK_EXEC_ARGS_FILE = Join-Path $activeRoot 'model-calls.txt'
    $env:CQK_MOCK_MODE = 'expiry-active'; $env:CQK_MOCK_POST_EXEC_MODE = ''
    Invoke-ScheduleRecoveryRunner $activeRoot -Recovery
    Assert-False (Test-Path $env:CQK_MOCK_EXEC_ARGS_FILE) 'fresh running window blocks anchoring'

    Start-TestGroup 'real runner: failed recovery never creates another read retry'
    $failedRoot = Join-Path $ws 'failed-recovery'
    Ensure-Directory $failedRoot | Out-Null
    Write-TestConfigFile (Join-Path $failedRoot 'config.json') $liveCfg | Out-Null
    $env:CQK_MOCK_MODE = 'network-error'
    Invoke-ScheduleRecoveryRunner $failedRoot -Recovery
    Assert-False (Test-Path (Join-Path $failedRoot 'task-writes.jsonl')) 'recovery is bounded instead of chaining more tasks'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    Remove-TestWorkspace $ws
}
$result = Get-TestResult
Write-Host "schedule-recovery: $($result.checks) checks, $($result.failures) failures"
if ($result.failures) { exit 1 }
exit 0
