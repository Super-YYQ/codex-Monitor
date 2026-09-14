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

    Start-TestGroup 'install: task description follows the effective mode (CQK-032)'

    Assert-True ($tp.Description -match 'mode=MonitorOnly') 'default description names the read-only mode'
    Assert-True ($tp.Description -match 'read-only') 'default description promises read-only polling'
    Assert-True ($tp.Description -notmatch 'EXPERIMENTAL') 'MonitorOnly description does not mention anchoring'
    Assert-Equal (Get-KeeperTaskDescription -Config $cfg15) $tp.Description 'description comes from the shared helper'

    # mode=AutoAnchor alone is not enough - the runner only anchors when
    # codex.autoAnchor.enabled=true, so the description must not claim anchoring.
    # The configured mode is still echoed, so it does not claim MonitorOnly either.
    $cfgModeOnly = New-Cfg 15
    $cfgModeOnly.mode = 'AutoAnchor'
    $descModeOnly = Get-KeeperTaskDescription -Config $cfgModeOnly
    Assert-True ($descModeOnly -match 'read-only') 'mode=AutoAnchor with autoAnchor off described as polling only'
    Assert-True ($descModeOnly -match 'mode=AutoAnchor') 'disarmed AutoAnchor mode still echoed, not mislabelled'
    Assert-True ($descModeOnly -notmatch 'EXPERIMENTAL') 'no EXPERIMENTAL wording while anchoring is disarmed'

    $cfgArmed = New-Cfg 15
    $cfgArmed.mode = 'AutoAnchor'
    $cfgArmed.codex.autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; schedule = @('08:55', '13:55'); anchorOnExpiry = @('secondary') }
    $descArmed = Get-KeeperTaskDescription -Config $cfgArmed
    Assert-True ($descArmed -match 'EXPERIMENTAL') 'armed AutoAnchor is flagged EXPERIMENTAL'
    Assert-True ($descArmed -match 'auto-anchoring') 'armed description says what the task now also does'
    Assert-True ($descArmed -notmatch 'read-only') 'armed description drops the read-only claim'
    $tpArmed = New-KeeperTaskParameters -Config $cfgArmed -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal $descArmed $tpArmed.Description 'registered parameters carry the mode-derived description'
    Assert-True ($tpArmed.Description.Length -le 255) 'description fits the Task Scheduler length limit'
    Assert-Equal 4 @($tpArmed.Trigger).Count 'poll, logon, and two native daily schedule triggers are registered'
    $cfgDisarmedSchedule = New-Cfg 15
    $cfgDisarmedSchedule.codex.autoAnchor = @{ enabled = $false; schedule = @('08:55') }
    $tpDisarmedSchedule = New-KeeperTaskParameters -Config $cfgDisarmedSchedule -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 2 @($tpDisarmedSchedule.Trigger).Count 'disarmed schedule does not add unnecessary task triggers'

    Start-TestGroup 'install: deployment ACL write detection is precise'

    Assert-False (Test-FileSystemRightsWriteCapable -Rights ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)) 'read-only ACE is not reported as writable'
    Assert-True (Test-FileSystemRightsWriteCapable -Rights ([System.Security.AccessControl.FileSystemRights]::Write)) 'write ACE is reported'
    Assert-True (Test-FileSystemRightsWriteCapable -Rights ([System.Security.AccessControl.FileSystemRights]::Modify)) 'modify ACE is reported'
    Assert-True (Test-FileSystemRightsWriteCapable -Rights ([System.Security.AccessControl.FileSystemRights]::FullControl)) 'full-control ACE is reported'

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
    $cfgAaOn.codex.autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; anchorOnApply = $true }
    $spec = Get-ForcedAnchorLaunchSpec -Config $cfgAaOn -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-False $spec.skip 'spec produced when anchorOnApply=true and autoAnchor enabled'
    Assert-True ("$($spec.exe)" -match 'wscript') 'spec launches via wscript (windowless host)'
    $forcedVbs = [System.IO.File]::ReadAllText("$($spec.vbsPath)")
    Assert-True ("$forcedVbs" -match 'runner\.ps1') 'spec vbs runs runner.ps1'
    Assert-True ("$forcedVbs" -match '\-ForceAnchor') 'spec vbs passes -ForceAnchor'
    Assert-True ("$forcedVbs" -match '\-WaitLockSeconds 60') 'forced runner waits for a colliding scheduled poll'
    Assert-True ("$forcedVbs" -match [regex]::Escape([System.IO.Path]::GetFullPath($cfgFile))) 'spec vbs passes the custom config path'
    Assert-True ("$forcedVbs" -match 'WindowStyle Hidden') 'spec vbs hides the console window'

    $specOff = Get-ForcedAnchorLaunchSpec -Config (New-Cfg 15) -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-True $specOff.skip 'autoAnchor off -> no forced launch'

    $cfgAaOff = New-Cfg 15
    $cfgAaOff.codex.autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; anchorOnApply = $false }
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

    $null = Write-TestConfigFile $cfgFile (New-Cfg 1)
    $rejected = Invoke-ApplyConfig -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-False $rejected.ok '1-minute polling rejected'
    # The rejected config must not have been applied. 30 is the interval this file
    # successfully applied above (the Execution Profile groups below lean on that
    # number to prove a blocked install/apply leaves the task alone), so the task
    # being checked here is the task, not a stale expectation.
    Assert-Equal 30 (Get-TaskIntervalMinutes (Get-ScheduledTask -TaskName $taskName)) 'rejected apply leaves the live interval alone'

    # ===========================================================================
    # doc v3.0 §7 - the Execution Profile gate (CQK-039).
    #
    # Strong semantic validation is NOT a universal blocker: it only bites when a
    # model call is actually configured (mode=AutoAnchor AND autoAnchor.enabled).
    # These groups pin both halves of that sentence - the blocking half AND the
    # "a MonitorOnly user is never locked out of installing" half - and the
    # promise that a blocked install/apply leaves the Scheduled Task untouched.
    #
    # The bad model name is invented, not read from a list: this repository must
    # not carry a model whitelist, fixtures included (§22). What makes it invalid is
    # that the mock CLI's live catalog does not serve it.
    # ===========================================================================

    function New-ArmedCfg {
        # An armed AutoAnchor config that passes every L1 rule, so whatever these
        # groups reject is the execution profile and nothing else.
        #
        # -Timeout stays at 5, the smallest value L1 accepts: Test-ConfigShape has a
        # codex.queryTimeoutSeconds >= 5 floor of its own (common.ps1), so a 2-second
        # config would be rejected as a malformed file and never reach the profile
        # gate at all - which is exactly the kind of false green this group must not
        # have. 5 s also bounds any UNAVAILABLE path that does wait, and keeps the
        # poll-fit rule happy (budget 20 s inside a 15-minute poll).
        param([int]$Poll = 15, [string]$Model = '', [string]$Effort = '', [int]$Timeout = 5)
        $c = New-Cfg $Poll
        $c.mode = 'AutoAnchor'
        $c.codex.queryTimeoutSeconds = $Timeout
        $c.codex.autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6
                                 minimumGapMinutes = 60
                                 model = $Model; reasoningEffort = $Effort }
        # Belt and braces: if this config ever stops being L1-valid, say so here
        # rather than letting a malformed-file rejection masquerade as a profile
        # verdict several assertions down.
        $l1 = @(Test-ConfigShape $c)
        if ($l1.Count -gt 0) { throw "New-ArmedCfg produced an L1-invalid config: $($l1 -join '; ')" }
        return $c
    }

    $badModel = 'mock-model-gpt4o-fake'

    Start-TestGroup '§7 gate: armed AutoAnchor with an INVALID profile blocks install (T02)'

    $gateBad = New-ArmedCfg -Poll 15 -Model $badModel
    $null = Write-TestConfigFile $cfgFile $gateBad
    $env:CQK_MOCK_EXEC_ARGS_FILE = (Join-Path $ws 'exec-args-install-blocked.log')
    $blocked = Invoke-KeeperInstall -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-False $blocked.ok 'install blocked by an armed-but-invalid profile'
    Assert-Equal 1 @($blocked.issues).Count "exactly the profile issue is reported ($($blocked.issues -join '; '))"
    Assert-True ("$($blocked.issues -join ' ')" -match 'INVALID') 'the issue names the validation verdict'
    Assert-True ("$($blocked.issues -join ' ')" -match 'AutoAnchor is armed') 'the issue says WHY it blocks (armed), not just what'
    Assert-True ("$($blocked.issues -join ' ')" -match [regex]::Escape($badModel)) 'the issue quotes the configured model so the fix is obvious'
    Assert-Equal 0 @($blocked.warnings).Count 'an armed bad profile is an issue, never a warning'
    Assert-Equal 'INVALID' $blocked.profile.validation 'the returned gate carries the verdict'
    Assert-True $blocked.profile.armed 'and whether the gate considered AutoAnchor armed'
    Assert-Null $blocked.taskName 'no task name on a blocked install'
    # "task not registered" has to be proven against the LIVE task, not against the
    # return value: this task already exists (registered 30 minutes ago by the apply
    # group), so the real promise is that the blocked install did not rewrite it.
    Assert-NotNull (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) 'blocked install leaves the existing task in place'
    Assert-Equal 30 (Get-TaskIntervalMinutes (Get-ScheduledTask -TaskName $taskName)) 'blocked install does not touch its interval'
    # T02's other half: the rejected config never reached a model.
    Assert-False (Test-Path -LiteralPath $env:CQK_MOCK_EXEC_ARGS_FILE) 'T02: blocked install makes zero codex exec calls'

    Start-TestGroup '§7 gate: armed AutoAnchor cannot verify the profile -> UNAVAILABLE blocks (fail closed)'

    # Three ways the environment refuses to answer, all the same gate decision.
    # 'catalog-timeout' is deliberately not among them: that mode sleeps 120 s, and
    # a 2-second wait already proves the point (docs/findings.md).
    foreach ($unavailMode in @('config-error', 'catalog-error', 'catalog-badschema')) {
        $env:CQK_MOCK_MODE = $unavailMode
        $g = Get-ExecutionProfileGate -Config $gateBad -CodexPath $mockPath -KeeperRoot $keeperRoot -Stage 'Install'
        $env:CQK_MOCK_MODE = 'normal'
        Assert-True $g.attempted "[$unavailMode] the profile was actually resolved, not skipped"
        Assert-Equal 'UNAVAILABLE' $g.validation "[$unavailMode] an unreadable catalog is UNAVAILABLE, not INVALID"
        Assert-True $g.armed "[$unavailMode] gate sees AutoAnchor armed"
        Assert-Equal 1 @($g.issues).Count "[$unavailMode] armed + UNAVAILABLE is a blocking issue"
        Assert-True ("$($g.issues -join ' ')" -match 'could not be verified') "[$unavailMode] wording says unverified, not wrong"
        Assert-Equal 0 @($g.warnings).Count "[$unavailMode] never demoted to a warning"
    }
    # The error kind comes from the low-level client, not from re-reading the message
    # (§11): config/read failing for auth is a different kind from a malformed page.
    $env:CQK_MOCK_MODE = 'config-error'
    $gAuth = Get-ExecutionProfileGate -Config $gateBad -CodexPath $mockPath -KeeperRoot $keeperRoot -Stage 'Install'
    $env:CQK_MOCK_MODE = 'normal'
    Assert-True ([string]$gAuth.profile.errorKind -match 'AUTH|PROTOCOL|SCHEMA|NETWORK|RPC') "UNAVAILABLE carries a structured errorKind (got '$($gAuth.profile.errorKind)')"
    Assert-False (Test-Path -LiteralPath $env:CQK_MOCK_EXEC_ARGS_FILE) 'an unverified profile never reaches codex exec either'

    Start-TestGroup '§7 gate: not armed -> the same bad profile is a warning, never a blocker'

    # mode=MonitorOnly with a bad model: read-only installs are not held hostage to
    # a model they will never call.
    $cfgMonitorBad = New-Cfg 15
    $cfgMonitorBad.codex.autoAnchor = @{ enabled = $false; model = $badModel; reasoningEffort = 'low' }
    $gMonitor = Get-ExecutionProfileGate -Config $cfgMonitorBad -CodexPath $mockPath -KeeperRoot $keeperRoot -Stage 'Install'
    Assert-False $gMonitor.armed 'MonitorOnly is never armed'
    Assert-Equal 0 @($gMonitor.issues).Count 'and its bad profile raises no blocking issue'
    Assert-Equal 1 @($gMonitor.warnings).Count 'but the warning is still there'
    Assert-True ("$($gMonitor.warnings -join ' ')" -match 'not armed') 'the warning says why nothing blocks'
    Assert-True ("$($gMonitor.warnings -join ' ')" -match [regex]::Escape($badModel)) 'naming the model the operator still has to fix'

    # mode=AutoAnchor + enabled=false: §7 row two - the mode claims anchoring, the
    # switch does not, so no model runs today and nothing blocks.
    $cfgModeNoEnable = New-ArmedCfg -Model $badModel
    $cfgModeNoEnable.codex.autoAnchor.enabled = $false
    $gDisarmed = Get-ExecutionProfileGate -Config $cfgModeNoEnable -CodexPath $mockPath -KeeperRoot $keeperRoot -Stage 'Install'
    Assert-False $gDisarmed.armed 'mode=AutoAnchor alone is not armed (the runner needs enabled=true too)'
    Assert-Equal 0 @($gDisarmed.issues).Count 'disarmed AutoAnchor never blocks'
    Assert-Equal 1 @($gDisarmed.warnings).Count 'still warned'

    # End to end, so the branch is not only unit-true: a MonitorOnly config with the
    # same bad profile installs. 30-minute poll keeps the interval the status group
    # below expects.
    $cfgMApply = New-Cfg 30
    $cfgMApply.codex.autoAnchor = @{ enabled = $false; model = $badModel }
    $null = Write-TestConfigFile $cfgFile $cfgMApply
    $monitorApplied = Invoke-ApplyConfig -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-True $monitorApplied.ok "MonitorOnly with a bad profile still applies ($($monitorApplied.issues -join '; '))"
    Assert-True (@($monitorApplied.warnings).Count -ge 1) 'and reports the profile warning through the return value'
    Assert-Equal 'INVALID' $monitorApplied.profile.validation 'carrying the verdict for the console line'
    Assert-Equal 30 (Get-TaskIntervalMinutes (Get-ScheduledTask -TaskName $taskName)) 'the warning-only path did not change the interval either'

    Start-TestGroup '§7 gate: blocked Apply leaves the existing scheduled task unchanged'

    # §7 最后一条：Apply 失败时不能出现"新配置校验失败但计划任务已经部分更新".
    # Registration is a read-modify-write, so the only safe ordering is gate first -
    # which is what this pins: 20 minutes in the config, still 30 on the task.
    $cfgArmedBad20 = New-ArmedCfg -Poll 20 -Model $badModel
    $null = Write-TestConfigFile $cfgFile $cfgArmedBad20
    $applyBlocked = Invoke-ApplyConfig -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-False $applyBlocked.ok 'apply with an armed invalid profile is rejected'
    Assert-True ("$($applyBlocked.issues -join ' ')" -match 'INVALID') 'for the profile reason'
    Assert-Equal 0 @($applyBlocked.warnings).Count 'blocking, not warning'
    Assert-False $applyBlocked.taskCreated 'and nothing was created'
    Assert-Equal 30 (Get-TaskIntervalMinutes (Get-ScheduledTask -TaskName $taskName)) 'the live task keeps the OLD interval (20 never reached it)'
    Assert-Equal 'Codex Quota Keeper: scheduled read-only Codex quota polling (mode=MonitorOnly). One-shot runner, never resident.' `
        (Get-ScheduledTask -TaskName $taskName).Description 'its description is the old MonitorOnly one, not the rejected config'
    Assert-False (Test-Path -LiteralPath $env:CQK_MOCK_EXEC_ARGS_FILE) 'a rejected apply never calls the model either'

    Start-TestGroup '§14.1 cache: written on a verdict, never on a read failure'

    $cachePath = Get-ExecutionProfilePath $keeperRoot
    $cfgGood = New-ArmedCfg -Poll 15
    $gGood = Get-ExecutionProfileGate -Config $cfgGood -CodexPath $mockPath -KeeperRoot $keeperRoot -Stage 'Install'
    Assert-Equal 'VALID' $gGood.validation 'an armed AutoAnchor inheriting the CLI config is VALID (no explicit model needed to pass)'
    Assert-Equal 0 @($gGood.issues).Count 'a good profile blocks nothing'
    Assert-True $gGood.cache.ok 'the valid profile was cached'
    $cachedGood = Read-ExecutionProfileCache -KeeperRoot $keeperRoot
    Assert-True $cachedGood.ok 'the cache reads back'
    Assert-Equal 'mock-model-beta' $cachedGood.value.effectiveModel 'cached model is what the CLI config says (not a configured model)'
    # 'high', not the model's own default: §6.2 puts the Codex CLI config ABOVE the
    # catalog defaultReasoningEffort, and the mock's config/read reports high.
    Assert-Equal 'high' $cachedGood.value.effectiveReasoningEffort 'cached effort comes from the CLI config'
    Assert-Equal 'codex-config' $cachedGood.value.reasoningEffortSource 'and the cache keeps the source that explains it'
    Assert-Equal 'VALID' $cachedGood.value.validation 'with the verdict'

    # A read failure says nothing about the profile: the last real verdict survives,
    # or the offline panel would report a good profile as broken.
    $env:CQK_MOCK_MODE = 'config-error'
    $gUnavail = Get-ExecutionProfileGate -Config $gateBad -CodexPath $mockPath -KeeperRoot $keeperRoot -Stage 'Install'
    $env:CQK_MOCK_MODE = 'normal'
    Assert-Equal 'UNAVAILABLE' $gUnavail.validation 'UNAVAILABLE still blocks an armed config'
    $afterUnavail = Read-ExecutionProfileCache -KeeperRoot $keeperRoot
    Assert-Equal 'mock-model-beta' $afterUnavail.value.effectiveModel 'UNAVAILABLE does not overwrite the cache'
    Assert-Equal 'VALID' $afterUnavail.value.validation 'the last real verdict is still what the panel would show'

    $gBad = Get-ExecutionProfileGate -Config $gateBad -CodexPath $mockPath -KeeperRoot $keeperRoot -Stage 'Install'
    Assert-Equal 'INVALID' $gBad.validation 'INVALID is a real verdict, so it is worth showing offline'
    $afterInvalid = Read-ExecutionProfileCache -KeeperRoot $keeperRoot
    Assert-Equal 'INVALID' $afterInvalid.value.validation 'the cache now says INVALID'
    Assert-Equal $badModel $afterInvalid.value.effectiveModel 'and names the model that was rejected'
    # §23 on the write side too: the cache is a whitelist of profile facts.
    $cacheText = [System.IO.File]::ReadAllText($cachePath)
    foreach ($forbidden in @('notify', 'instructions', 'shell_environment_policy', 'enabled-reasoning-efforts', 'token', 'validationReason')) {
        Assert-False ($cacheText -match ('"' + [regex]::Escape($forbidden) + '"\s*:')) "cached profile does not carry [$forbidden]"
    }

    Start-TestGroup '§14.1 gate summary: the console line distinguishes VALID / INVALID / never-checked'

    Assert-True ((Get-ExecutionProfileGateSummary -Gate $gBad) -match 'INVALID \[armed\]') 'a blocking verdict is readable at a glance'
    Assert-True ((Get-ExecutionProfileGateSummary -Gate $gGood) -match 'VALID \[armed\]') 'a good profile says so, with the model'
    Assert-True ((Get-ExecutionProfileGateSummary -Gate $gMonitor) -match 'not armed') 'a warning-only verdict says it did not block'
    Assert-Equal 'not checked (environment validation failed first)' (Get-ExecutionProfileGateSummary -Gate $null) 'a gate that never ran is not reported as a pass'

    # Leave the workspace in the state the status groups below expect: a valid
    # MonitorOnly config at a 30-minute interval.
    $null = Write-TestConfigFile $cfgFile (New-Cfg 30)

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
    $cfgAa.codex.autoAnchor = @{ enabled = $true; schedule = @('09:30'); anchorOnExpiry = @('secondary') }
    $null = Write-TestConfigFile $cfgFile $cfgAa
    $statusAa = Get-KeeperStatus -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-True $statusAa.configOk "autoAnchor config valid ($($statusAa.lastError))"
    Assert-True $statusAa.autoAnchor 'autoAnchor reported ON (v2 nested config shape)'
    Assert-Equal 0 $statusAa.anchorKeepalive.intervalMinutes 'legacy keepalive projection is permanently off'
    Assert-Contains $statusAa.anchorExpiry.windows 'secondary' 'expiry window reported'
    Assert-Equal 1 @($statusAa.anchorSchedule.slots).Count 'schedule slots reported'
    Assert-Equal '09:30' $statusAa.anchorSchedule.slots[0] 'schedule slot preserved'
    $textAa = (Write-StatusText $statusAa | Out-String)
    Assert-True ("$textAa" -match '\*\*\* ON') 'ON warning shown in status text'
    Assert-True ("$textAa" -match 'Anchor on expiry') 'expiry trigger line shown'
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
    # The §7 groups point this at a workspace file to prove "codex exec = 0"; the
    # workspace goes anyway, but the variable must not outlive the file.
    Remove-Item Env:\CQK_MOCK_EXEC_ARGS_FILE -ErrorAction SilentlyContinue
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
