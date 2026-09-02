# Tests for install/uninstall/apply-config/status. Uses a uniquely named task so
# the real Task Scheduler is exercised without touching user tasks.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'logger.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')
. (Join-Path $scriptDir 'quota-client.ps1')
. (Join-Path $scriptDir 'preflight.ps1')
. (Join-Path $scriptDir 'install.ps1')
. (Join-Path $scriptDir 'uninstall.ps1')
. (Join-Path $scriptDir 'apply-config.ps1')
. (Join-Path $scriptDir 'status.ps1')

$mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'
$pwsh = (Get-Process -Id $PID).Path
$taskName = "CQKTestTask.$([guid]::NewGuid().ToString('N').Substring(0, 12))"

$ws = New-TestWorkspace
try {
    $keeperRoot = Join-Path $ws 'keeper'
    New-Item -ItemType Directory -Path $keeperRoot -Force | Out-Null
    $cfgFile = Join-Path $keeperRoot 'config.json'

    function New-Cfg {
        param([int]$Poll = 15)
        New-TestConfig @{
            task   = @{ name = $taskName; startWithWindows = $true; runIfNetworkAvailable = $true; wakeToRun = $false }
            github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
            codex  = @{ command = $mockPath; queryTimeoutSeconds = 10; autoAnchor = $false }
            poll = @{ intervalMinutes = $Poll; minimumIntervalMinutes = 5 }
        }
    }
    $null = Write-TestConfigFile $cfgFile (New-Cfg 15)

    Start-TestGroup 'install: task definition objects'

    $cfg15 = New-Cfg 15
    $tp = New-KeeperTaskParameters -Config $cfg15 -KeeperRoot $keeperRoot
    Assert-Equal $taskName $tp.TaskName 'task name from config'
    Assert-True ("$($tp.Action.Execute)" -match 'pwsh|powershell') 'action uses powershell'
    Assert-True ("$($tp.Action.Arguments)" -match 'runner\.ps1') 'action runs runner.ps1'
    Assert-True ("$($tp.Action.Arguments)" -match '-NoProfile') 'action uses -NoProfile'
    Assert-True ("$($tp.Action.Arguments)" -match 'WindowStyle Hidden') 'action hides console window (no popup on scheduled run)'
    Assert-Equal (Join-Path $keeperRoot '') "$($tp.Action.WorkingDirectory)\" 'working directory pinned to project'
    $onceTrigger = @($tp.Trigger)[0]
    Assert-Equal 15 (Get-TaskIntervalMinutes $onceTrigger) 'repetition interval from config'
    Assert-Equal 'IgnoreNew' "$($tp.Settings.MultipleInstances)" 'no overlapping instances'
    Assert-Equal 'Interactive' "$($tp.Principal.LogonType)" 'per-user interactive, no admin'

    Start-TestGroup 'install: full registration with read-only probe'

    $env:CQK_MOCK_MODE = 'normal'
    $install = Invoke-KeeperInstall -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-True $install.ok "install ok ($($install.issues -join '; '))"
    Assert-Equal $taskName $install.taskName 'task registered under config name'
    Assert-NotNull $install.machine 'machine identity generated'
    Assert-True (Test-Path (Get-MachinePath $keeperRoot)) 'machine.json exists'

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Assert-NotNull $task 'task visible in Task Scheduler'
    Assert-True ($task.State -ne 'Disabled') 'task enabled'
    $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    Assert-NotNull $info 'task info readable'

    Start-TestGroup 'install: anchorOnApply decides the forced anchor launch'

    $cfgAaOn = New-Cfg 15
    $cfgAaOn.codex.autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 240; anchorOnApply = $true }
    $spec = Get-ForcedAnchorLaunchSpec -Config $cfgAaOn -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-False $spec.skip 'spec produced when anchorOnApply=true and autoAnchor enabled'
    Assert-True ("$($spec.arguments)" -match 'runner\.ps1') 'spec runs runner.ps1'
    Assert-True ("$($spec.arguments)" -match '\-ForceAnchor') 'spec passes -ForceAnchor'
    Assert-True ("$($spec.arguments)" -match 'WindowStyle Hidden') 'spec hides the console window'

    $specOff = Get-ForcedAnchorLaunchSpec -Config (New-Cfg 15) -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-True $specOff.skip 'autoAnchor off -> no forced launch'

    $cfgAaOff = New-Cfg 15
    $cfgAaOff.codex.autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 240; anchorOnApply = $false }
    $specAaOff = Get-ForcedAnchorLaunchSpec -Config $cfgAaOff -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-True $specAaOff.skip 'anchorOnApply=false -> no forced launch'

    Start-TestGroup 'apply-config: interval update 15 -> 30'

    $null = Write-TestConfigFile $cfgFile (New-Cfg 30)
    $applied = Invoke-ApplyConfig -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-True $applied.ok "apply-config ok ($($applied.issues -join '; '))"
    Assert-Equal 30 $applied.intervalMinutes 'new interval applied'
    $task30 = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $minutes = Get-TaskIntervalMinutes $task30
    Assert-Equal 30 $minutes 'task trigger now 30 minutes'

    Start-TestGroup 'apply-config: below-floor interval rejected'

    $badCfg = New-Cfg 1
    $badCfg.poll.minimumIntervalMinutes = 1
    $null = Write-TestConfigFile $cfgFile $badCfg
    $rejected = Invoke-ApplyConfig -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-False $rejected.ok '1-minute polling rejected'

    Start-TestGroup 'status: data collection and rendering'

    $null = Write-TestConfigFile $cfgFile (New-Cfg 30)
    $status = Get-KeeperStatus -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-True $status.task.installed 'status sees installed task'
    Assert-True $status.task.enabled 'task enabled in status'
    Assert-Equal 30 $status.pollIntervalMinutes 'poll interval from config'
    Assert-Equal $true $status.task.intervalMatchesConfig 'trigger matches config'
    Assert-True $status.role.localOnly 'github disabled -> local-only mode'
    Assert-False $status.autoAnchor 'autoAnchor reported OFF'

    $text = (Write-StatusText $status | Out-String)
    Assert-True ("$text" -match 'Codex Quota Keeper Status') 'status header'
    Assert-True ("$text" -match 'Task installed      : YES') 'task line'
    Assert-True ("$text" -match 'AutoAnchor          : OFF') 'anchor OFF line'
    Assert-True ("$text" -match 'MULTI-PC UNSAFE') 'local-only warning shown'

    Start-TestGroup 'status: autoAnchor reported ON when mode+enabled'

    $cfgAa = New-Cfg 30
    $cfgAa.mode = 'AutoAnchor'
    $cfgAa.codex.autoAnchor = @{ enabled = $true; schedule = @('09:30') }
    $null = Write-TestConfigFile $cfgFile $cfgAa
    $statusAa = Get-KeeperStatus -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-True $statusAa.configOk "autoAnchor config valid ($($statusAa.lastError))"
    Assert-True $statusAa.autoAnchor 'autoAnchor reported ON (v2 nested config shape)'
    Assert-Equal 300 $statusAa.anchorKeepalive.intervalMinutes 'keepalive interval reported'
    Assert-Equal 1 @($statusAa.anchorSchedule.slots).Count 'schedule slots reported'
    Assert-Equal '09:30' $statusAa.anchorSchedule.slots[0] 'schedule slot preserved'
    $textAa = (Write-StatusText $statusAa | Out-String)
    Assert-True ("$textAa" -match '\*\*\* ON') 'ON warning shown in status text'
    Assert-True ("$textAa" -match 'Anchor backstop') 'backstop line shown'
    Assert-True ("$textAa" -match 'Scheduled anchor\s+: 09:30') 'schedule line shown'
    $null = Write-TestConfigFile $cfgFile (New-Cfg 30)

    Start-TestGroup 'status-json: machine-readable output'

    $jsonOut = & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'status-json.ps1') -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    $parsed = ConvertFrom-JsonSafe ($jsonOut | Out-String)
    Assert-NotNull $parsed 'status json parses'
    Assert-True ($parsed.task.installed -eq $true) 'json task installed flag'
    Assert-NotNull $parsed.machineId 'json machine id'
    Assert-Equal 'MonitorOnly' $parsed.mode 'json mode'

    Start-TestGroup 'uninstall: task removed, history kept by default'

    $histDir = Get-HistoryDir $keeperRoot
    Ensure-Directory $histDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $histDir 'events-x.jsonl'), '{}')

    $un = Invoke-KeeperUninstall -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-True $un.removedTask 'task removed'
    Assert-Null (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) 'task gone from scheduler'
    Assert-True (Test-Path $histDir) 'history kept by default'

    $un2 = Invoke-KeeperUninstall -KeeperRoot $keeperRoot -ConfigFile $cfgFile -DeleteHistory
    Assert-False $un2.removedTask 'second uninstall: nothing to remove'
    Assert-True $un2.historyRemoved 'history deleted on request'
    Assert-False (Test-Path $histDir) 'history dir removed'
} finally {
    Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
    # Safety: never leave the test task behind.
    $null = Invoke-TestGit -RepoPath $null -ArgumentList @() # no-op keep helper loaded
    try {
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($t) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
    } catch { }
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "install-status.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
