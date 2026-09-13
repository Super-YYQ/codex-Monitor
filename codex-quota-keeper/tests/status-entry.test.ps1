# Exercise the public cmd entry with a local script spy; never call the real CLI.
$testsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $testsDir 'test-helper.ps1')
. (Join-Path (Split-Path -Parent $testsDir) 'scripts/common.ps1')
$ws = New-TestWorkspace
try {
    $entry = Join-Path $ws 'status.cmd'
    Copy-Item (Join-Path (Split-Path -Parent $testsDir) 'status.cmd') $entry
    Ensure-Directory (Join-Path $ws 'scripts') | Out-Null
    $spy = 'param([switch]$Live,[switch]$Detailed,[switch]$NoColor); Write-Output "live=$Live detailed=$Detailed noColor=$NoColor"; exit 7'
    [IO.File]::WriteAllText((Join-Path $ws 'scripts/status.ps1'), $spy)
    foreach ($flags in @('-Live -Detailed -NoColor --no-pause', '--no-pause -Live -Detailed -NoColor')) {
        $launch = Resolve-ExecutableLaunchSpec -Executable $entry -ArgumentList ($flags.Split(' '))
        $r = Invoke-External -FilePath $launch.exe -RawArguments $launch.rawArgs -TimeoutSeconds 15
        Assert-Equal 7 $r.exitCode 'public entry preserves child exit code'
        Assert-True ($r.stdout.Contains('live=True detailed=True noColor=True')) 'public entry forwards supported flags'
    }
    $launch = Resolve-ExecutableLaunchSpec -Executable $entry -ArgumentList @('--unknown', '--no-pause')
    $r = Invoke-External -FilePath $launch.exe -RawArguments $launch.rawArgs -TimeoutSeconds 15
    Assert-Equal 2 $r.exitCode 'unsupported flag is rejected explicitly'
} finally { Remove-TestWorkspace $ws }
$r = Get-TestResult
Write-Host "status-entry: $($r.checks) checks, $($r.failures) failures"
exit ([int]($r.failures -gt 0))
