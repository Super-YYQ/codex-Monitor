# Exercise status collection with the real logger and zero, one, or many errors.
# Task Scheduler and CLI discovery are mocked; no task or model is started.
$ErrorActionPreference = 'Stop'
$testsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'logger.ps1')
. (Join-Path $scriptDir 'status.ps1')

function Get-ScheduledTask {
    param([string]$TaskName)
    return $null
}
function Resolve-CodexCommand {
    param([hashtable]$Config)
    return $null
}

$ws = New-TestWorkspace
try {
    $cfg = New-TestConfig @{
        github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
    }
    $null = Write-TestConfigFile (Join-Path $ws 'config.json') $cfg

    Start-TestGroup 'status: no errors'
    $status = Get-KeeperStatus -KeeperRoot $ws
    Assert-True $status.configOk 'fixture config reaches normal status collection'
    Assert-Null $status.lastError 'missing logs leave lastError unset'
    Write-KeeperLog -Root $ws -Event 'RUNNER_OK'
    $status = Get-KeeperStatus -KeeperRoot $ws
    Assert-Null $status.lastError 'INFO logs do not become recent errors'

    Start-TestGroup 'status: a single error keeps its event and message'
    Write-KeeperLog -Root $ws -Event 'READ_FAILED' -Level 'ERROR' -ErrorText 'app-server initialization timed out'
    $status = Get-KeeperStatus -KeeperRoot $ws
    Assert-Equal 'READ_FAILED: app-server initialization timed out' $status.lastError 'singleton logger result is collected as an array'

    Start-TestGroup 'status: the newest error is preserved'
    Write-KeeperLog -Root $ws -Event 'AUTH_ERROR' -Level 'ERROR' -ErrorText 'login required'
    Write-KeeperLog -Root $ws -Event 'RUNNER_OK'
    $status = Get-KeeperStatus -KeeperRoot $ws
    Assert-Equal 'AUTH_ERROR: login required' $status.lastError 'Take=1 retains the newest ERROR despite a later INFO entry'
} finally {
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
Write-Host "status-collection: $($result.checks) checks, $($result.failures) failures"
exit ([int]($result.failures -gt 0))
