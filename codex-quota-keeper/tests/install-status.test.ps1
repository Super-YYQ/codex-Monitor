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
    # CQK-022: deliberately a custom (non-default) config name - the default
    # fallback path <KeeperRoot>\config.json does not exist in this workspace,
    # so any code path that drops -ConfigFile is caught by these tests.
    $cfgFile = Join-Path $keeperRoot 'custom-config.json'

    function New-Cfg {
        param([int]$Poll = 15)
        New-TestConfig @{
            task   = @{ name = $taskName; startWithWindows = $true; runIfNetworkAvailable = $true; wakeToRun = $false }
            github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
            codex  = @{ command = $mockPath; queryTimeoutSeconds = 10; autoAnchor = $false }
            poll   = @{ intervalMinutes = $Poll; minimumIntervalMinutes = 5 }
            # CQK-021: lease TTL must satisfy >= max(2*poll, poll+grace+jitter).
            # Keep a 3x margin so every poll value here stays valid.
            leader = @{ leaseTtlMinutes = [Math]::Max(45, 3 * $Poll) }
        }
    }
    $null = Write-TestConfigFile $cfgFile (New-Cfg 15)

    Start-TestGroup 'install: task definition objects'

    $cfg15 = New-Cfg 15
    $tp = New-KeeperTaskParameters -Config $cfg15 -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal $taskName $tp.TaskName 'task name from config'
    Assert-True ("$($tp.Action.Execute)" -match 'wscript') 'action launches via wscript (windowless host, no console flash)'
    Assert-True ("$($tp.Action.Arguments)" -match 'hidden-launch\.vbs') 'action points at the generated hidden-launch.vbs'
    $vbsContent = [System.IO.File]::ReadAllText((Join-Path $keeperRoot 'runtime\hidden-launch.vbs'))
    Assert-True ("$vbsContent" -match 'runner\.ps1') 'vbs runs runner.ps1'
    Assert-True ("$vbsContent" -match '-NoProfile') 'vbs uses -NoProfile'
    Assert-True ("$vbsContent" -match 'WindowStyle Hidden') 'vbs hides console window (no popup on scheduled run)'
    Assert-True ("$vbsContent" -match '", 0, False') 'vbs Run uses window style 0 (hidden from creation)'
    # CQK-022: the custom config path must be baked into the scheduled command,
    # otherwise every poll silently falls back to <KeeperRoot>\config.json.
    Assert-True ("$vbsContent" -match '-ConfigFile') 'vbs passes -ConfigFile (custom config survives polling)'
    Assert-True ("$vbsContent" -match [regex]::Escape([System.IO.Path]::GetFullPath($cfgFile))) 'vbs carries the exact custom config path'
    Assert-True ("$vbsContent" -match '-KeeperRoot') 'vbs pins -KeeperRoot'
    Assert-True ("$vbsContent" -notmatch '-ForceAnchor') 'scheduled poll vbs does not force an anchor'
    Assert-Equal (Join-Path $keeperRoot '') "$($tp.Action.WorkingDirectory)\" 'working directory pinned to project'
    $onceTrigger = @($tp.Trigger)[0]
    Assert-Equal 15 (Get-TaskIntervalMinutes $onceTrigger) 'repetition interval from config'
    Assert-Equal 'IgnoreNew' "$($tp.Settings.MultipleInstances)" 'no overlapping instances'
    Assert-Equal 'Interactive' "$($tp.Principal.LogonType)" 'per-user interactive, no admin'

    Start-TestGroup 'install: ExecutionTimeLimit derived from the config (CQK-031)'

    # The ScheduledTask CimInstance exposes ExecutionTimeLimit as an ISO 8601
    # duration string (PT10M), not a TimeSpan - so TotalMinutes is never set and
    # the assertions have to parse it back.
    function Get-TestTaskLimitMinutes {
        param($Settings)
        $raw = "$($Settings.ExecutionTimeLimit)"
        if ([string]::IsNullOrWhiteSpace($raw)) { return 0 }
        return [int][System.Xml.XmlConvert]::ToTimeSpan($raw).TotalMinutes
    }

    # New-Cfg 15 -> 10 s timeout, no proxy, no remote: a 20 s budget, so the
    # 10-minute floor decides. The old hardcoded 15 min must not come back.
    Assert-Equal 10 (Get-TestTaskLimitMinutes $tp.Settings) 'defaults get the 10-minute floor, not the old fixed 15'
    Assert-Equal (Get-KeeperTaskExecutionTimeLimit $cfg15).minutes (Get-TestTaskLimitMinutes $tp.Settings) 'task limit equals the derived limit (single source of truth)'

    # A big timeout needs more room than the floor: 180 s x 2 waits x 2 proxy
    # attempts = 720 s -> 12 min, and a 60-minute poll leaves it uncapped.
    $cfgBig = New-Cfg 60
    $cfgBig.codex.queryTimeoutSeconds = 180
    $cfgBig.codex.proxy = 'http://proxy.invalid:7890'
    $tpBig = New-KeeperTaskParameters -Config $cfgBig -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 12 (Get-TestTaskLimitMinutes $tpBig.Settings) 'max timeout + proxy raises the limit to the budget'
    Assert-False (Get-KeeperTaskExecutionTimeLimit $cfgBig).cappedByPoll 'a 60-minute poll has room for that budget'

    # Tight poll: the clamp (poll - 2) wins over the budget so a hung runner cannot
    # swallow the next trigger. Legal config (budget 12 min <= poll 13), just no
    # margin left - which is why the status panel reports cappedByPoll as a warning.
    $cfgTight = New-Cfg 13
    $cfgTight.codex.queryTimeoutSeconds = 180
    $cfgTight.codex.proxy = 'http://proxy.invalid:7890'
    Assert-Equal 0 @(Test-ConfigShape $cfgTight).Count 'a 12-minute budget inside a 13-minute poll is valid'
    $limTight = Get-KeeperTaskExecutionTimeLimit $cfgTight
    Assert-Equal 11 $limTight.minutes 'limit clamped to poll - 2 min'
    Assert-True $limTight.cappedByPoll 'clamp reported for the status panel'
    Assert-Equal 11 (Get-TestTaskLimitMinutes (New-KeeperTaskParameters -Config $cfgTight -KeeperRoot $keeperRoot -ConfigFile $cfgFile).Settings) 'installed settings carry the clamped limit'

    # One poll shorter and the same config becomes hard invalid: the install layer
    # must not be able to register it quietly.
    $cfgOver = New-Cfg 11
    $cfgOver.codex.queryTimeoutSeconds = 180
    $cfgOver.codex.proxy = 'http://proxy.invalid:7890'
    Assert-True (@(Test-ConfigShape $cfgOver).Count -ge 1) 'budget overrunning the poll is a config error, not a silent clamp'

    # A remote-syncing MonitorOnly config: 20 s read + 240 s git = 260 s, still
    # under the floor, so coordination alone never inflates the limit.
    $cfgSync = New-Cfg 15
    $cfgSync.github = @{ coordination = @{ enabled = $true; repoPath = 'R:\repo' }; historySync = @{ enabled = $false } }
    Assert-Equal 260 (Get-CodexTickBudgetSeconds $cfgSync) 'sync budget = read + git'
    Assert-Equal 10 (Get-TestTaskLimitMinutes (New-KeeperTaskParameters -Config $cfgSync -KeeperRoot $keeperRoot -ConfigFile $cfgFile).Settings) 'sync still fits the floor'

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
    # CQK-022 end-to-end: after a real install with a custom -ConfigFile, the
    # generated launcher VBS must point the scheduled runner at that same file.
    $installedVbs = [System.IO.File]::ReadAllText((Join-Path $keeperRoot 'runtime\hidden-launch.vbs'))
    Assert-True ("$installedVbs" -match [regex]::Escape([System.IO.Path]::GetFullPath($cfgFile))) 'installed task vbs pins the custom config path'

    Start-TestGroup 'install: anchorOnApply decides the forced anchor launch'

    $cfgAaOn = New-Cfg 15
    $cfgAaOn.codex.autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 240; anchorOnApply = $true }
    $spec = Get-ForcedAnchorLaunchSpec -Config $cfgAaOn -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-False $spec.skip 'spec produced when anchorOnApply=true and autoAnchor enabled'
    Assert-True ("$($spec.exe)" -match 'wscript') 'spec launches via wscript (windowless host)'
    $forcedVbs = [System.IO.File]::ReadAllText("$($spec.vbsPath)")
    Assert-True ("$forcedVbs" -match 'runner\.ps1') 'spec vbs runs runner.ps1'
    Assert-True ("$forcedVbs" -match '\-ForceAnchor') 'spec vbs passes -ForceAnchor'
    Assert-True ("$forcedVbs" -match [regex]::Escape([System.IO.Path]::GetFullPath($cfgFile))) 'spec vbs passes the custom config path'
    Assert-True ("$forcedVbs" -match 'WindowStyle Hidden') 'spec vbs hides the console window'

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
    # CQK-022: apply-config re-registers the task - the vbs must keep the config path.
    $vbs30 = [System.IO.File]::ReadAllText((Join-Path $keeperRoot 'runtime\hidden-launch.vbs'))
    Assert-True ("$vbs30" -match [regex]::Escape([System.IO.Path]::GetFullPath($cfgFile))) 'vbs still pins the custom config after apply-config'

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

    Start-TestGroup 'status: anchor model/effort line when configured'

    $cfgMdl = New-Cfg 30
    $cfgMdl.mode = 'AutoAnchor'
    $cfgMdl.codex.autoAnchor = @{ enabled = $true; model = 'gpt-5-codex'; reasoningEffort = 'low' }
    $null = Write-TestConfigFile $cfgFile $cfgMdl
    $statusMdl = Get-KeeperStatus -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-True $statusMdl.configOk "model config valid ($($statusMdl.lastError))"
    Assert-Equal 'gpt-5-codex' $statusMdl.anchorExec.model 'anchor model reported'
    Assert-Equal 'low' $statusMdl.anchorExec.reasoningEffort 'anchor effort reported'
    $textMdl = (Write-StatusText $statusMdl | Out-String)
    Assert-True ("$textMdl" -match 'Anchor exec\s+: model gpt-5-codex, effort low') 'anchor exec line shown'
    # Unset sides must surface as CLI default, and nothing shows when both unset.
    $cfgEffOnly = New-Cfg 30
    $cfgEffOnly.mode = 'AutoAnchor'
    $cfgEffOnly.codex.autoAnchor = @{ enabled = $true; reasoningEffort = 'low' }
    $null = Write-TestConfigFile $cfgFile $cfgEffOnly
    $statusEff = Get-KeeperStatus -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    $textEff = (Write-StatusText $statusEff | Out-String)
    Assert-True ("$textEff" -match 'Anchor exec\s+: model CLI default, effort low') 'unset model shown as CLI default'
    $cfgOff = New-Cfg 30
    $cfgOff.mode = 'AutoAnchor'
    $cfgOff.codex.autoAnchor = @{ enabled = $true }
    $null = Write-TestConfigFile $cfgFile $cfgOff
    $statusOff2 = Get-KeeperStatus -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    $textOff2 = (Write-StatusText $statusOff2 | Out-String)
    Assert-False ("$textOff2" -match 'Anchor exec') 'no anchor exec line when both unset'
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
