# Tests the pure expiry-alarm plan and the Windows Task Scheduler adapter seam.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'state-machine.ps1')
. (Join-Path $scriptDir 'anchor-alarm.ps1')

$now = [DateTime]::Parse('2026-09-14 08:00:00')
$nowEpoch = ConvertTo-EpochSeconds $now

function New-AlarmConfig {
    param($Expiry = @('secondary'))
    return New-TestConfig @{
        mode = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; anchorOnExpiry = @($Expiry) } }
        task = @{ name = 'CQK.Test'; startWithWindows = $false; runIfNetworkAvailable = $true; wakeToRun = $false; alarmName = '' }
    }
}

function New-AlarmState {
    # usedPercent > 0 makes these real open windows: a window with no usage whose
    # resetsAt sits at exactly now + duration is an idle prediction, not a boundary.
    param($Primary = ($nowEpoch + 18000), $Secondary = ($nowEpoch + 604800), $Used = 20)
    $state = New-KeeperState
    $state.buckets = @(@{ bucketId = 'default'; windows = @(
        @{ windowType = 'primary'; resetsAt = $Primary; usedPercent = $Used; windowDurationMins = 300 },
        @{ windowType = 'secondary'; resetsAt = $Secondary; usedPercent = $Used; windowDurationMins = 10080 }
    ) })
    return $state
}

Start-TestGroup 'alarm plan: earliest configured future expiry plus one minute'

$cfg = New-AlarmConfig -Expiry @('primary', 'secondary')
$state = New-AlarmState
$plan = Get-AnchorAlarmPlan -Config $cfg -State $state -Now $now
Assert-Equal 'set' $plan.action 'future expiry creates an alarm plan'
Assert-Equal ($nowEpoch + 18060) $plan.targetEpoch 'earliest expiry plus 60 seconds selected'
Assert-Equal 'CQK.Test.AnchorAlarm' $plan.taskName 'default alarm name derived from poll task'

$custom = New-AlarmConfig
$custom.task.alarmName = 'CQK.Custom.Alarm'
Assert-Equal 'CQK.Custom.Alarm' (Get-AnchorAlarmPlan -Config $custom -State $state -Now $now).taskName 'custom alarm name honored'

Start-TestGroup 'alarm plan: clear when disarmed or no tracked future expiry'

$off = New-AlarmConfig
$off.codex.autoAnchor.enabled = $false
Assert-Equal 'clear' (Get-AnchorAlarmPlan -Config $off -State $state -Now $now).action 'disarmed config clears stale alarm'
$expired = New-AlarmState -Secondary ($nowEpoch - 1)
Assert-Equal 'clear' (Get-AnchorAlarmPlan -Config (New-AlarmConfig) -State $expired -Now $now).action 'expired snapshot carries no future alarm'

Start-TestGroup 'alarm adapter: one stable task name and runner re-check action'

$script:MockAlarmExisting = $null
$script:MockAlarmRegistered = $null
$script:MockAlarmRemoved = $null
function Get-ScheduledTask { param($TaskName, $ErrorAction) return $script:MockAlarmExisting }
function New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory) return @{ Execute = $Execute; Arguments = $Argument; WorkingDirectory = $WorkingDirectory } }
function New-ScheduledTaskTrigger { param([switch]$Once, $At) return @{ Once = [bool]$Once; At = $At } }
function New-ScheduledTaskSettingsSet { param($MultipleInstances, $ExecutionTimeLimit, $StartWhenAvailable, $AllowStartIfOnBatteries, $DontStopIfGoingOnBatteries, $WakeToRun, $RunOnlyIfNetworkAvailable) return @{ StartWhenAvailable = $StartWhenAvailable; WakeToRun = $WakeToRun } }
function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return @{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel } }
function Register-ScheduledTask {
    param($TaskName, $Action, $Trigger, $Settings, $Principal, $Description, [switch]$Force)
    $script:MockAlarmRegistered = @{ TaskName = $TaskName; Action = $Action; Trigger = $Trigger; Settings = $Settings; Principal = $Principal; Description = $Description; Force = [bool]$Force }
    return $script:MockAlarmRegistered
}
function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm); $script:MockAlarmRemoved = $TaskName }

$ws = New-TestWorkspace
try {
    $keeper = Join-Path $ws 'keeper'
    New-Item -ItemType Directory -Path (Join-Path $keeper 'scripts') -Force | Out-Null
    $cfgPath = Join-Path $keeper 'config.json'
    Write-TestConfigFile $cfgPath $cfg | Out-Null
    $sync = Sync-AnchorAlarmTask -Config $cfg -State $state -KeeperRoot $keeper -ConfigFile $cfgPath -Now $now
    Assert-True $sync.ok 'adapter registers alarm through the injected Task Scheduler seam'
    Assert-Equal 'ANCHOR_ALARM_SET' $sync.event 'set event returned'
    Assert-Equal 'CQK.Test.AnchorAlarm' $script:MockAlarmRegistered.TaskName 'stable task name used'
    Assert-True ($script:MockAlarmRegistered.Action.Arguments -match 'hidden-launch-anchor-alarm\.vbs') 'action launches generated hidden VBS'
    $vbs = Get-Content -LiteralPath (Join-Path $keeper 'runtime\hidden-launch-anchor-alarm.vbs') -Raw
    Assert-True ($vbs -match '-FromAlarm') 'alarm action identifies its source'
    Assert-True ($vbs -match '-WaitLockSeconds 60') 'alarm runner waits for a colliding poll'

    $script:MockAlarmExisting = @{ TaskName = 'CQK.Test.AnchorAlarm' }
    $clearCfg = New-AlarmConfig -Expiry @()
    $cleared = Sync-AnchorAlarmTask -Config $clearCfg -State $state -KeeperRoot $keeper -ConfigFile $cfgPath -Now $now
    Assert-True $cleared.ok 'clear succeeds'
    Assert-Equal 'ANCHOR_ALARM_CLEARED' $cleared.event 'clear event returned'
    Assert-Equal 'CQK.Test.AnchorAlarm' $script:MockAlarmRemoved 'same task is removed, no task proliferation'
} finally { Remove-TestWorkspace $ws }

Start-TestGroup 'alarm plan: an idle prediction is not a boundary worth waking for'

# An idle window reports resetsAt = now + duration every poll, so treating that as a
# real expiry pushes the alarm forward forever and it never fires.
$idleState = New-AlarmState -Secondary ($nowEpoch + 10080 * 60) -Used 0
$previousIdle = New-AlarmState -Primary ($nowEpoch + 18000 - 60) -Secondary ($nowEpoch + 10080 * 60 - 60) -Used 0
Update-ExpiryTrack -State $idleState -Buckets $previousIdle.buckets -Now $now.AddMinutes(-1)
Update-ExpiryTrack -State $idleState -Buckets $idleState.buckets -Now $now
$idlePlan = Get-AnchorAlarmPlan -Config (New-AlarmConfig) -State $idleState -Now $now
Assert-Equal 'clear' $idlePlan.action 'idle secondary prediction carries no alarm target'

$realPlan = Get-AnchorAlarmPlan -Config (New-AlarmConfig) -State (New-AlarmState -Secondary ($nowEpoch + 3600)) -Now $now
Assert-Equal 'set' $realPlan.action 'a real boundary inside the duration still arms the alarm'
Assert-Equal ($nowEpoch + 3660) $realPlan.targetEpoch 'real boundary plus 60 seconds selected'

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "anchor-alarm.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
