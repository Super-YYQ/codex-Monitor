# Tests for quota-client.ps1 against the mock app-server (no real OpenAI credentials).
# Covers: handshake, window identification by windowDurationMins, missing secondary,
# fractional usage, unknown schema fail-closed, auth/protocol errors, timeout kill, start failure.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'quota-client.ps1')

$mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'

function Invoke-MockRead {
    param([string]$Mode, [int]$TimeoutSeconds = 10)
    $env:CQK_MOCK_MODE = $Mode
    try {
        $cfg = New-TestConfig @{ codex = @{ command = $mockPath; queryTimeoutSeconds = $TimeoutSeconds; autoAnchor = $false } }
        return Invoke-CodexRateLimitsRead -Config $cfg
    } finally {
        Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
    }
}

Start-TestGroup 'protocol: handshake + read returns both windows'

$r = Invoke-MockRead 'normal'
Assert-True $r.ok 'read ok'
Assert-Equal 2 @($r.windows).Count 'two windows'
$primary = @($r.windows | Where-Object { $_.name -eq 'primary' })[0]
$secondary = @($r.windows | Where-Object { $_.name -eq 'secondary' })[0]
Assert-Equal 300 $primary.minutes 'primary window is 300 min by windowDurationMins'
Assert-Equal 25 $primary.usedPercent 'primary usedPercent'
Assert-Equal 1788062400 $primary.resetsAt 'primary resetsAt epoch'
Assert-Equal 10080 $secondary.minutes 'secondary window is 10080 min'
Assert-Null $r.rateLimitReachedType 'no limit reached flag'
Assert-False $r.schemaUnknown 'schema recognized'

Start-TestGroup 'schema: identify windows by windowDurationMins, not by name'

$r = Invoke-MockRead 'swapped'
Assert-True $r.ok 'read ok'
Assert-Equal 10080 $r.windows[0].minutes 'primary slot carries weekly duration as-is'

Start-TestGroup 'schema: single window tolerated'

$r = Invoke-MockRead 'no-secondary'
Assert-True $r.ok 'read ok with one window'
Assert-Equal 1 @($r.windows).Count 'one window only'

Start-TestGroup 'schema: extra unknown window names preserved'

$r = Invoke-MockRead 'extra-window'
Assert-True $r.ok 'read ok'
Assert-Equal 3 @($r.windows).Count 'tertiary window kept verbatim'
Assert-Equal 'tertiary' $r.windows[2].name 'unknown window name preserved'

Start-TestGroup 'schema: fractional usedPercent not rounded'

$r = Invoke-MockRead 'fractional'
Assert-True $r.ok 'read ok'
Assert-Equal '17.5' "$($r.windows[0].usedPercent)" 'decimal percent kept'

Start-TestGroup 'schema: unknown structure fails closed'

$r = Invoke-MockRead 'unknown-schema'
Assert-False $r.ok 'unknown schema not ok'
Assert-True $r.schemaUnknown 'schemaUnknown flagged'
Assert-Equal 'SCHEMA_UNKNOWN' $r.errorKind 'SCHEMA_UNKNOWN kind'
Assert-Equal 0 @($r.windows).Count 'no windows on unknown schema'

Start-TestGroup 'errors: auth failure classified'

$r = Invoke-MockRead 'auth-error'
Assert-False $r.ok 'auth error not ok'
Assert-Equal 'AUTH_ERROR' $r.errorKind 'AUTH_ERROR kind'

Start-TestGroup 'errors: protocol failure classified'

$r = Invoke-MockRead 'protocol-error'
Assert-False $r.ok 'protocol error not ok'
Assert-Equal 'PROTOCOL_ERROR' $r.errorKind 'PROTOCOL_ERROR kind'

Start-TestGroup 'errors: rateLimitReachedType surfaced'

$r = Invoke-MockRead 'limit-reached'
Assert-True $r.ok 'read ok'
Assert-Equal 'primary' $r.rateLimitReachedType 'limit type surfaced (state machine will flag LIMIT_REACHED)'

Start-TestGroup 'errors: timeout kills the hung app-server'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-MockRead 'timeout' -TimeoutSeconds 2
$sw.Stop()
Assert-False $r.ok 'timeout not ok'
Assert-Equal 'TIMEOUT' $r.errorKind 'TIMEOUT kind'
Assert-True ($sw.Elapsed.TotalSeconds -lt 15) "timeout enforced quickly (took $([int]$sw.Elapsed.TotalSeconds)s)"

Start-TestGroup 'errors: app-server dying at start reported'

$r = Invoke-MockRead 'start-failure'
Assert-False $r.ok 'start failure not ok'
Assert-True ($r.errorKind -in @('EOF', 'SETUP_ERR', 'TIMEOUT')) "start failure kind ($($r.errorKind))"

Start-TestGroup 'setup: missing codex command reported'

$cfg = New-TestConfig @{ codex = @{ command = 'auto'; queryTimeoutSeconds = 5 } }
# PATH lookup for a fake name: temporarily use a config whose command cannot exist.
$cfg.codex.command = Join-Path $env:TEMP ('no-such-codex-' + [guid]::NewGuid().ToString('N') + '.exe')
$r = Invoke-CodexRateLimitsRead -Config $cfg
Assert-False $r.ok 'missing codex binary not ok'
Assert-Equal 'SETUP_ERR' $r.errorKind 'SETUP_ERR kind'

Start-TestGroup 'sanity: sanitized error text'

$r = Invoke-MockRead 'auth-error'
Assert-False ("$($r.message)" -match 'sk-[A-Za-z0-9]{6,}') 'no raw keys in messages'

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "quota-client.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
