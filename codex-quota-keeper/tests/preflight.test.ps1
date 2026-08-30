# Tests for preflight.ps1 (uses the mock app-server; no real credentials).

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')
. (Join-Path $scriptDir 'quota-client.ps1')
. (Join-Path $scriptDir 'preflight.ps1')

$mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'

Start-TestGroup 'preflight: happy path with mock codex and github disabled'

$ws = New-TestWorkspace
try {
    $cfgFile = Join-Path $ws 'config.json'
    $cfg = New-TestConfig @{
        github = @{ enabled = $false }
        codex  = @{ command = $mockPath; queryTimeoutSeconds = 10 }
    }
    $null = Write-TestConfigFile $cfgFile $cfg
    $r = Invoke-Preflight -Config $cfg -ConfigPath $cfgFile -KeeperRoot $ws
    Assert-True $r.ok "preflight ok ($($r.issues -join '; '))"
    Assert-NotNull $r.codexPath 'codex path resolved'
    Assert-NotNull $r.machine 'machine identity ensured'
    Assert-True (Test-Path (Get-MachinePath $ws)) 'machine.json created'
    Assert-True (Test-Path (Get-RuntimeDir $ws)) 'runtime dirs created'

    Start-TestGroup 'preflight: probeCodex does a read-only quota probe'

    $env:CQK_MOCK_MODE = 'normal'
    try {
        $r2 = Invoke-Preflight -Config $cfg -ConfigPath $cfgFile -KeeperRoot $ws -ProbeCodex $true
        Assert-True $r2.ok 'probe ok with mock'
        Assert-True $r2.probe.ok 'probe result ok'
        Assert-Equal 2 @($r2.probe.windows).Count 'probe saw two windows'
    } finally {
        Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
    }

    Start-TestGroup 'preflight: probe failure surfaces as issue'

    $env:CQK_MOCK_MODE = 'auth-error'
    try {
        $r3 = Invoke-Preflight -Config $cfg -ConfigPath $cfgFile -KeeperRoot $ws -ProbeCodex $true
        Assert-False $r3.ok 'auth failure fails preflight'
        Assert-True (($r3.issues -join ' ') -match 'quota probe failed') 'probe issue reported'
    } finally {
        Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
    }

    Start-TestGroup 'preflight: missing codex / bad config / bad repo'

    $cfgNoCodex = New-TestConfig @{ github = @{ enabled = $false }; codex = @{ command = 'auto' } }
    $cfgNoCodex.codex.command = 'no-such-codex-binary-xyz'
    $r4 = Invoke-Preflight -Config $cfgNoCodex -KeeperRoot $ws
    Assert-False $r4.ok 'missing codex binary fails preflight'

    $r5 = Invoke-Preflight -Config $null -ConfigPath (Join-Path $ws 'missing.json') -KeeperRoot $ws
    Assert-False $r5.ok 'missing config fails preflight'

    $badRepo = Join-Path $ws 'plain'
    New-Item -ItemType Directory -Path $badRepo -Force | Out-Null
    $cfgBadRepo = New-TestConfig @{ github = @{ enabled = $true; repoPath = $badRepo } }
    $r6 = Invoke-Preflight -Config $cfgBadRepo -KeeperRoot $ws
    Assert-False $r6.ok 'non-git log repo fails preflight'
} finally {
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "preflight.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
