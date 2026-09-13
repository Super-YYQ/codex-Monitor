# CQK-044: install is the only layer allowed to perform a second quota round.
# Mock-only: no task registration, Git operation, credential, or model request.
$testsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $testsDir 'test-helper.ps1')
$scripts = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scripts 'install.ps1')
$mock = Join-Path $testsDir 'fixtures/mock-appserver.ps1'
$ws = New-TestWorkspace
try {
    Start-TestGroup 'install probe retries only transient failures'
    $sessions = Join-Path $ws 'sessions.txt'
    $env:CQK_MOCK_SESSIONS_FILE = $sessions
    $env:CQK_MOCK_MODE = 'network-error'
    $cfg = New-TestConfig @{ codex = @{ command = $mock; queryTimeoutSeconds = 5; proxy = 'http://mock-proxy.invalid:9' } }
    $result = Invoke-KeeperInstallProbe -Config $cfg -CodexPath $mock
    Assert-False $result.ok 'network failure remains failed'
    Assert-Equal 'NETWORK_ERROR' $result.errorKind 'failure is typed'
    Assert-True $result.retryable 'transient failure is marked retryable'
    Assert-Equal 2 $result.rounds 'exactly two rounds'
    Assert-Equal 4 $result.totalAttempts 'proxy plus direct in each round; never a fifth attempt'
    Assert-Equal 4 @(Get-Content $sessions).Count 'four child sessions were created'

    Start-TestGroup 'hard failures stop after the first low-level attempt'
    [IO.File]::WriteAllText($sessions, '')
    $env:CQK_MOCK_MODE = 'auth-error'
    $hard = Invoke-KeeperInstallProbe -Config $cfg -CodexPath $mock
    Assert-Equal 'AUTH_ERROR' $hard.errorKind 'authentication is a hard failure'
    Assert-False $hard.retryable 'authentication is not retryable'
    Assert-Equal 1 $hard.rounds 'no second round for hard failures'
    Assert-Equal 1 $hard.totalAttempts 'proxy fallback is also suppressed for hard failures'
    Assert-Equal 1 @(Get-Content $sessions).Count 'one child session only'
} finally {
    Remove-Item Env:\CQK_MOCK_SESSIONS_FILE, Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
    Remove-TestWorkspace $ws
}
$r = Get-TestResult
Write-Host "install-retry: $($r.checks) checks, $($r.failures) failures"
exit ([int]($r.failures -gt 0))
