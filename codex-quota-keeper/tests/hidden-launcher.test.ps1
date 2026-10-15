# Store PowerShell updates must not strand the generated scheduled launchers.
# Uses a harmless runner and real WSH, never the keeper or a model invocation.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'install.ps1')

$ws = New-TestWorkspace
$savedLocalAppData = $env:LOCALAPPDATA
$windowsPowerShell = (Microsoft.PowerShell.Core\Get-Command powershell -CommandType Application | Select-Object -First 1).Source
try {
    $keeper = Join-Path $ws 'keeper with spaces'
    $null = New-Item -ItemType Directory -Path (Join-Path $keeper 'scripts') -Force
    $configFile = Join-Path $keeper 'custom config.json'
    $marker = Join-Path $keeper 'launched.txt'
    $runner = @'
param([string]$KeeperRoot, [string]$ConfigFile, [switch]$ForceAnchor,
      [switch]$FromAlarm, [switch]$ReadOnlyRetry, [switch]$ScheduleRecovery,
      [int]$WaitLockSeconds)
[IO.File]::WriteAllText((Join-Path $KeeperRoot 'launched.txt'), $ConfigFile)
'@
    [IO.File]::WriteAllText((Join-Path $keeper 'scripts/runner.ps1'), $runner)

    $env:LOCALAPPDATA = Join-Path $ws 'local-app-data'
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/pwsh.exe'
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $alias) -Force
    $store = Join-Path $ws 'WindowsApps/Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe/pwsh.exe'
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $store) -Force
    [IO.File]::WriteAllText($store, '')
    $script:LauncherMockPowerShell = $store
    function Get-Command {
        param([string]$Name, [string]$ErrorAction, [string[]]$CommandType)
        if ($Name -eq 'pwsh') {
            foreach ($source in @($script:LauncherMockPowerShell)) {
                if ($source) { [pscustomobject]@{ Source = $source } }
            }
            return $null
        }
        Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
    }

    Start-TestGroup 'hidden launcher: stable Store execution alias'
    [IO.File]::WriteAllText($alias, '')
    Assert-Equal $alias (Get-KeeperPowerShellPath) 'Store package path is replaced with the stable execution alias'
    Remove-Item -LiteralPath $alias -Force
    Assert-Equal $windowsPowerShell (Get-KeeperPowerShellPath) 'Store without an enabled alias uses Windows PowerShell'
    $script:LauncherMockPowerShell = @($store, $windowsPowerShell)
    Assert-Equal $windowsPowerShell (Get-KeeperPowerShellPath) 'multiple matching applications resolve to one stable executable'

    Start-TestGroup 'hidden launcher: all callers survive removal of the old Store package'
    # Generate while the old package still exists, then remove it as a Store
    # update does. The runner only writes a marker, including the custom path.
    $launchers = @(
        (Get-KeeperHiddenLauncherSpec -KeeperRoot $keeper -ConfigFile $configFile)
        (Get-KeeperHiddenLauncherSpec -KeeperRoot $keeper -ConfigFile $configFile -ForceAnchorSwitch)
        (Get-AnchorAlarmLauncherSpec -KeeperRoot $keeper -ConfigFile $configFile)
        (Get-AnchorAlarmLauncherSpec -KeeperRoot $keeper -ConfigFile $configFile -ReadOnlyRetry)
        (Get-AnchorAlarmLauncherSpec -KeeperRoot $keeper -ConfigFile $configFile -ScheduleRecovery)
    )
    # Recovery shares the alarm filename; the flags are separately checked below.
    Assert-True ($launchers[2].innerCommand -match '-FromAlarm') 'expiry alarm keeps its trigger flag'
    Assert-True ($launchers[3].innerCommand -match '-ReadOnlyRetry') 'read retry keeps its read-only flag'
    Assert-True ($launchers[4].innerCommand -match '-ScheduleRecovery') 'schedule recovery keeps its trigger flag'
    Remove-Item -LiteralPath $store -Force
    foreach ($launcher in $launchers) {
        Assert-False ($launcher.innerCommand.Contains($store)) 'launcher never persists the versioned Store path'
        Assert-True ($launcher.arguments -match '(?i)//B\b') 'scheduled WSH errors cannot open a dialog'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Microsoft.PowerShell.Core\Get-Command cscript -CommandType Application).Source
        # cscript writes errors to the captured console; unlike wscript it does
        # not show an error dialog, so keep diagnostics available in failures.
        $psi.Arguments = '//NoLogo "{0}"' -f $launcher.vbsPath
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        try {
            $null = $p.Start()
            $exited = $p.WaitForExit(10000)
            if (-not $exited) { $p.Kill() }
            $diagnostic = if ($exited) { ($p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()).Trim() } else { 'timeout' }
            Assert-True ($exited -and $p.ExitCode -eq 0) "WSH starts the harmless runner after the Store update ($diagnostic)"
            if ($exited -and $p.ExitCode -eq 0) {
                for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $marker); $i++) { Start-Sleep -Milliseconds 50 }
            }
            Assert-True (Test-Path -LiteralPath $marker) 'runner actually executes, rather than only starting the WSH host'
            if (Test-Path -LiteralPath $marker) {
                Assert-Equal $configFile ([IO.File]::ReadAllText($marker)) 'custom config path survives quoting and launch'
                Remove-Item -LiteralPath $marker -Force
            }
        } finally { $p.Dispose() }
    }

    Start-TestGroup 'hidden launcher: stable non-Store installations remain selected'
    $script:LauncherMockPowerShell = $windowsPowerShell
    Assert-Equal $windowsPowerShell (Get-KeeperPowerShellPath) 'non-Store command resolution is preserved'
    $script:LauncherMockPowerShell = $null
    Assert-Equal $windowsPowerShell (Get-KeeperPowerShellPath) 'Windows PowerShell is selected when PS7 is absent'

    Start-TestGroup 'hidden launcher: batch mode reports launch failure without a dialog'
    $failed = Get-KeeperHiddenLauncherSpec -KeeperRoot $keeper -ConfigFile $configFile
    $null = Write-KeeperHiddenLauncherVbs -KeeperRoot $keeper -Name 'hidden-launch.vbs' -InnerCommand ('"{0}"' -f (Join-Path $ws 'absent.exe'))
    if ($failed.arguments -match '(?i)//B\b') {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $failed.exe
        $psi.Arguments = $failed.arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        try {
            $null = $p.Start()
            $exited = $p.WaitForExit(10000)
            if (-not $exited) { $p.Kill() }
            Assert-True $exited 'missing executable does not leave an interactive WSH dialog waiting'
            Assert-True ($exited -and $p.ExitCode -ne 0) 'launch failure is visible as a nonzero process exit code'
        } finally { $p.Dispose() }
    }
} finally {
    Remove-Item Function:Get-Command -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $savedLocalAppData
    # All generated processes have finished before removing this owned workspace.
    Remove-TestWorkspace $ws
}

$r = Get-TestResult
Write-Host "`n$($r.checks) checks, $($r.failures) failures."
exit $(if ($r.failures -eq 0) { 0 } else { 1 })
