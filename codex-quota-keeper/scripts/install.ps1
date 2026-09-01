# Codex Quota Keeper - installer (doc 03 §4).
# Validates the environment, runs a read-only quota probe, generates the machine
# identity and registers a per-user Scheduled Task. No admin rights required.

param(
    [string]$KeeperRoot = '',
    [string]$ConfigFile = '',
    [switch]$SkipProbe
)

$script:CqkInstallDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkInstallDir 'common.ps1')
}
if (-not (Get-Command Invoke-Preflight -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkInstallDir 'preflight.ps1')
}
if (-not (Get-Command Invoke-CodexRateLimitsRead -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkInstallDir 'quota-client.ps1')
}

function Get-KeeperPowerShellPath {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    return (Get-Command powershell -ErrorAction SilentlyContinue).Source
}

function New-KeeperTaskParameters {
    # Builds the Register-/Set-ScheduledTask parameter objects. Pure construction
    # (no registration) so tests can inspect trigger/settings without touching
    # the real Task Scheduler.
    param([hashtable]$Config, [string]$KeeperRoot)
    $exe = Get-KeeperPowerShellPath
    if (-not $exe) { throw 'no PowerShell executable found for the task action' }
    $runner = Join-Path (Get-KeeperRoot $KeeperRoot) 'scripts\runner.ps1'

    $action = New-ScheduledTaskAction -Execute $exe `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`"" `
        -WorkingDirectory (Get-KeeperRoot $KeeperRoot)

    $interval = New-TimeSpan -Minutes (Get-PollConfig $Config).intervalMinutes
    # 3650 days: [TimeSpan]::MaxValue generates out-of-range XML on current
    # Windows builds; 10 years is accepted and effectively indefinite for a poller.
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval $interval -RepetitionDuration (New-TimeSpan -Days 3650)
    if ($Config.task.startWithWindows -eq $true) {
        $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $triggers = @($trigger, $logonTrigger)
    } else {
        $triggers = @($trigger)
    }

    $settingsParams = @{
        MultipleInstances           = 'IgnoreNew'
        ExecutionTimeLimit          = (New-TimeSpan -Minutes 15)
        StartWhenAvailable          = $true
        AllowStartIfOnBatteries     = $true
        DontStopIfGoingOnBatteries  = $true
    }
    if ($Config.task.wakeToRun -eq $true) { $settingsParams.WakeToRun = $true }
    if ($Config.task.runIfNetworkAvailable -eq $true) { $settingsParams.RunOnlyIfNetworkAvailable = $true }
    $settings = New-ScheduledTaskSettingsSet @settingsParams

    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

    return @{
        TaskName  = [string]$Config.task.name
        Action    = $action
        Trigger   = $triggers
        Settings  = $settings
        Principal = $principal
        Description = 'Codex Quota Keeper: scheduled read-only Codex quota polling (MonitorOnly). One-shot runner, never resident.'
    }
}

function Invoke-ImmediateRunIfRequested {
    # task.runAtInstall=true: start the freshly registered task right away so the
    # user can watch the first run without waiting for the poll interval. Fire and
    # forget: a start failure is reported but never fails the install.
    param([hashtable]$Config, [string]$TaskName)
    if ($Config.task -isnot [hashtable] -or $Config.task.runAtInstall -ne $true) {
        return @{ started = $false; reason = 'runAtInstall not enabled' }
    }
    try {
        Start-ScheduledTask -TaskName $TaskName
        return @{ started = $true; reason = $null }
    } catch {
        return @{ started = $false; reason = $_.Exception.Message }
    }
}

function Register-KeeperTask {
    param([hashtable]$Config, [string]$KeeperRoot)
    $tp = New-KeeperTaskParameters -Config $Config -KeeperRoot $KeeperRoot
    Register-ScheduledTask -TaskName $tp.TaskName `
        -Action $tp.Action -Trigger $tp.Trigger -Settings $tp.Settings `
        -Principal $tp.Principal -Description $tp.Description -Force | Out-Null
    return $tp.TaskName
}

function Invoke-KeeperInstall {
    # Returns @{ ok; issues; taskName; machine; probe; codexPath }
    param(
        [string]$KeeperRoot = '',
        [string]$ConfigFile = '',
        [switch]$SkipProbe
    )
    $issues = @()
    if (-not $KeeperRoot) { $KeeperRoot = Get-KeeperRoot }
    if (-not $ConfigFile) { $ConfigFile = Get-ConfigPath $KeeperRoot }

    # 1. Environment validation (PS version, git, codex, repo whitelist, runtime).
    $pf = Invoke-Preflight -Config $null -ConfigPath $ConfigFile -KeeperRoot $KeeperRoot
    if ($null -eq $pf -or -not $pf.machine) {
        return @{ ok = $false; issues = @('preflight failed before producing a machine identity'); taskName = $null; machine = $null; probe = $null; codexPath = $null }
    }
    $issues += $pf.issues
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        $issues += 'PowerShell 5.1 or newer is required'
    }

    # 2. Read-only connectivity probe (never calls the model).
    $probe = $null
    if (-not $SkipProbe -and $pf.codexPath) {
        $loaded = Load-Config $ConfigFile
        $probe = Invoke-CodexRateLimitsRead -Config $loaded.config -CodexPath $pf.codexPath
        if (-not $probe.ok) {
            $issues += "quota probe failed ($($probe.errorKind)): $($probe.message)"
        }
    }

    if ($issues.Count -gt 0) {
        return @{ ok = $false; issues = $issues; taskName = $null; machine = $pf.machine; probe = $probe; codexPath = $pf.codexPath }
    }

    # 3. Machine identity already ensured by preflight (random UUID + label).

    # 4/5. Register the per-user scheduled task.
    $loaded = Load-Config $ConfigFile
    $taskName = Register-KeeperTask -Config $loaded.config -KeeperRoot $KeeperRoot
    $immediateRun = Invoke-ImmediateRunIfRequested -Config $loaded.config -TaskName $taskName

    return @{ ok = $true; issues = @(); taskName = $taskName; machine = $pf.machine; probe = $probe; codexPath = $pf.codexPath; immediateRun = $immediateRun }
}

# Direct execution (pwsh -File / install.cmd): run the install interactively.
if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-KeeperInstall -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile -SkipProbe:$SkipProbe
    Write-Host 'Codex Quota Keeper - Install'
    Write-Host '========================================'
    foreach ($i in $result.issues) { Write-Host "  [ISSUE] $i" -ForegroundColor Yellow }
    if ($result.ok) {
        Write-Host "  Installed        : YES (task '$($result.taskName)')"
        Write-Host "  Machine identity : $($result.machine.label) [$($result.machine.machineId)]"
        Write-Host "  Quota probe      : $(if ($SkipProbe) { 'SKIPPED (-SkipProbe)' } else { 'OK (read-only, no model call)' })"
        Write-Host "  Immediate run    : $(if ($result.immediateRun.started) { 'STARTED (task.runAtInstall=true)' } else { "no ($($result.immediateRun.reason))" })"
        Write-Host ''
        Write-Host '  Next: double-click status.cmd to verify.'
    } else {
        Write-Host '  Installed        : NO (fix the issues above and re-run)' -ForegroundColor Red
    }
    exit $(if ($result.ok) { 0 } else { 1 })
}
