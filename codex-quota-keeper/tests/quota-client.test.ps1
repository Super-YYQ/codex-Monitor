# Tests for quota-client.ps1 (CQK-001/002):
#   - Protocol contract tests against official v2 schema fixtures (no process spawn)
#   - End-to-end protocol tests against the mock app-server (no real credentials)
# Covers: whitelist parsing, optional/null fields, multi-bucket, metadata,
# unknown-metadata tolerance, fail-closed on unrecognized roots, launcher flow.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'quota-client.ps1')

$mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'
$schemaDir = Join-Path $testsDir 'fixtures\schema'

function Read-Fixture {
    param([string]$Name)
    return ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText((Join-Path $schemaDir $Name)))
}

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

# ---------------------------------------------------------------------------
# Contract tests: official v2 schema fixtures (audit plan §4.3)

Start-TestGroup 'contract: rate-limits-current-v2'

$f = ConvertFrom-QuotaSnapshotResult (Read-Fixture 'rate-limits-current-v2.json')
Assert-True $f.ok 'current v2 parses'
Assert-False $f.schemaUnknown 'not schema unknown'
Assert-Equal 'plus' $f.accountPlanType 'planType surfaced'
Assert-Equal 1 @($f.buckets).Count 'single default bucket'
$b = $f.buckets[0]
Assert-Equal 'codex-default' $b.bucketId 'bucketId from limitId'
Assert-Equal 2 @($b.windows).Count 'primary + secondary windows'
$pri = @($b.windows | Where-Object { $_.windowType -eq 'primary' })[0]
Assert-Equal 300 $pri.windowDurationMins 'primary duration'
Assert-Equal 25 $pri.usedPercent 'primary usedPercent'
Assert-Equal 1788062400 $pri.resetsAt 'primary resetsAt'
Assert-True ($null -ne $f.windows -and @($f.windows).Count -eq 2) 'flattened view available'

Start-TestGroup 'contract: rate-limits-secondary-null'

$f = ConvertFrom-QuotaSnapshotResult (Read-Fixture 'rate-limits-secondary-null.json')
Assert-True $f.ok 'secondary=null parses'
Assert-Equal 1 @($f.buckets).Count 'one bucket'
Assert-Equal 1 @($f.buckets[0].windows).Count 'only primary window present'
Assert-Equal 'primary' $f.buckets[0].windows[0].windowType 'primary kept'

Start-TestGroup 'contract: rate-limits-null-window-fields'

$f = ConvertFrom-QuotaSnapshotResult (Read-Fixture 'rate-limits-null-window-fields.json')
Assert-True $f.ok 'null window fields tolerated (partial info)'
Assert-Equal 2 @($f.buckets[0].windows).Count 'both windows present'
$pri = @($f.buckets[0].windows | Where-Object { $_.windowType -eq 'primary' })[0]
$sec = @($f.buckets[0].windows | Where-Object { $_.windowType -eq 'secondary' })[0]
Assert-Null $pri.windowDurationMins 'null duration stays null'
Assert-Null $pri.resetsAt 'null resetsAt stays null'
Assert-Equal 25 $pri.usedPercent 'present field still parsed'
Assert-Null $sec.usedPercent 'null usedPercent stays null'
Assert-Equal 10080 $sec.windowDurationMins 'secondary duration parsed'

Start-TestGroup 'contract: rate-limits-multi-bucket'

$f = ConvertFrom-QuotaSnapshotResult (Read-Fixture 'rate-limits-multi-bucket.json')
Assert-True $f.ok 'multi-bucket parses'
Assert-Equal 2 @($f.buckets).Count 'two buckets'
$a = @($f.buckets | Where-Object { $_.bucketId -eq 'bucket-a' })[0]
$b = @($f.buckets | Where-Object { $_.bucketId -eq 'bucket-b' })[0]
Assert-NotNull $a 'bucket-a found'
Assert-NotNull $b 'bucket-b found'
Assert-Equal 300 $a.windows[0].windowDurationMins 'bucket-a window'
Assert-Equal 10080 $b.windows[0].windowDurationMins 'bucket-b window'

Start-TestGroup 'contract: rate-limits-credits'

$f = ConvertFrom-QuotaSnapshotResult (Read-Fixture 'rate-limits-credits.json')
Assert-True $f.ok 'credits fixture parses'
Assert-NotNull $f.credits 'credits surfaced'
Assert-True ("$($f.credits.hasCredits)" -eq 'True') 'credits value'
Assert-False ([bool]$f.spendControlReached) 'spendControlReached surfaced'

Start-TestGroup 'contract: rate-limits-unknown-metadata'

$f = ConvertFrom-QuotaSnapshotResult (Read-Fixture 'rate-limits-unknown-metadata.json')
Assert-True $f.ok 'unknown metadata does not break parsing'
Assert-False $f.schemaUnknown 'not schema unknown'
Assert-Equal 2 @($f.buckets[0].windows).Count 'windows unaffected'
Assert-True $f.rawMetadata.ContainsKey('futureField') 'primitive metadata preserved'
Assert-Equal 123 $f.rawMetadata['futureField'] 'metadata value kept'

Start-TestGroup 'contract: rate-limits-unrecognized-root'

$f = ConvertFrom-QuotaSnapshotResult (Read-Fixture 'rate-limits-unrecognized-root.json')
Assert-False $f.ok 'unrecognized root fails closed'
Assert-True $f.schemaUnknown 'schema unknown flagged'
Assert-Equal 'SCHEMA_UNKNOWN' $f.errorKind 'SCHEMA_UNKNOWN kind'

Start-TestGroup 'contract: garbage window object fails closed only when nothing usable'

$f = ConvertFrom-QuotaSnapshotResult @{ rateLimits = @{ primary = 'unexpected-string' } }
Assert-False $f.ok 'no usable window and no metadata -> SCHEMA_UNKNOWN'
Assert-Equal 'SCHEMA_UNKNOWN' $f.errorKind 'fail closed'

$f = ConvertFrom-QuotaSnapshotResult @{ rateLimits = @{ primary = 'garbage'; planType = 'plus' } }
Assert-True $f.ok 'metadata alone keeps the snapshot usable (window degraded)'
Assert-Null $f.buckets[0].windows[0].usedPercent 'unusable window has no fields'

$f = ConvertFrom-QuotaSnapshotResult $null
Assert-False $f.ok 'null result fails closed'
$f = ConvertFrom-QuotaSnapshotResult 'a string'
Assert-False $f.ok 'non-object result fails closed'

# ---------------------------------------------------------------------------
# End-to-end protocol tests (mock app-server process)

Start-TestGroup 'protocol: handshake + v2 read'

$r = Invoke-MockRead 'normal'
Assert-True $r.ok 'read ok'
Assert-Equal 'plus' $r.accountPlanType 'planType'
Assert-Equal 1 @($r.buckets).Count 'one bucket'
Assert-Equal 2 @($r.windows).Count 'two windows flattened'
Assert-Null $r.rateLimitReachedType 'no limit reached flag'
Assert-False $r.schemaUnknown 'schema recognized'

Start-TestGroup 'protocol: window identification by windowDurationMins'

$r = Invoke-MockRead 'swapped'
Assert-True $r.ok 'read ok'
Assert-Equal 10080 $r.windows[0].minutes 'primary slot carries weekly duration as-is'

Start-TestGroup 'protocol: single window and explicit null secondary tolerated'

$r = Invoke-MockRead 'no-secondary'
Assert-True $r.ok 'read ok with one window'
Assert-Equal 1 @($r.windows).Count 'one window only'
$r = Invoke-MockRead 'secondary-null'
Assert-True $r.ok 'secondary=null read ok'
Assert-Equal 1 @($r.windows).Count 'null secondary skipped'

Start-TestGroup 'protocol: null window fields do not crash'

$r = Invoke-MockRead 'null-fields'
Assert-True $r.ok 'null fields tolerated'
Assert-Equal 2 @($r.windows).Count 'both windows present'
Assert-Null $r.windows[0].resetsAt 'null resetsAt preserved'

Start-TestGroup 'protocol: multi-bucket via rateLimitsByLimitId'

$r = Invoke-MockRead 'multi-bucket'
Assert-True $r.ok 'multi-bucket read ok'
Assert-Equal 2 @($r.buckets).Count 'two buckets'
Assert-Equal 2 @($r.windows).Count 'two windows total'
$wa = @($r.windows | Where-Object { $_.bucketId -eq 'bucket-a' })[0]
Assert-Equal 300 $wa.minutes 'bucket-a window identified'

Start-TestGroup 'protocol: fractional usedPercent not rounded'

$r = Invoke-MockRead 'fractional'
Assert-True $r.ok 'read ok'
Assert-Equal '17.5' "$($r.windows[0].usedPercent)" 'decimal percent kept'

Start-TestGroup 'protocol: unknown metadata keys never become windows'

$r = Invoke-MockRead 'unknown-meta'
Assert-True $r.ok 'read ok'
Assert-Equal 2 @($r.windows).Count 'only whitelist windows'
Assert-True $r.rawMetadata.ContainsKey('futureField') 'unknown primitive kept as metadata'
Assert-Equal 123 $r.rawMetadata['futureField'] 'metadata value'

Start-TestGroup 'protocol: credits and spendControlReached'

$r = Invoke-MockRead 'credits'
Assert-True $r.ok 'read ok'
Assert-NotNull $r.credits 'credits surfaced'
Assert-False ([bool]$r.spendControlReached) 'spend control surfaced'

Start-TestGroup 'schema: unknown structure fails closed'

$r = Invoke-MockRead 'unknown-schema'
Assert-False $r.ok 'unknown schema not ok'
Assert-True $r.schemaUnknown 'schemaUnknown flagged'
Assert-Equal 'SCHEMA_UNKNOWN' $r.errorKind 'SCHEMA_UNKNOWN kind'
Assert-Equal 0 @($r.windows).Count 'no windows on unknown schema'

$r = Invoke-MockRead 'unrecognized-root'
Assert-False $r.ok 'unrecognized root not ok'
Assert-Equal 'SCHEMA_UNKNOWN' $r.errorKind 'fail closed at root'

Start-TestGroup 'errors: auth / protocol / rate limit classified'

$r = Invoke-MockRead 'auth-error'
Assert-False $r.ok 'auth error not ok'
Assert-Equal 'AUTH_ERROR' $r.errorKind 'AUTH_ERROR kind'
$r = Invoke-MockRead 'protocol-error'
Assert-False $r.ok 'protocol error not ok'
Assert-Equal 'PROTOCOL_ERROR' $r.errorKind 'PROTOCOL_ERROR kind'
$r = Invoke-MockRead 'rate-limit'
Assert-False $r.ok 'rate limit not ok'
Assert-Equal 'PROTOCOL_ERROR' $r.errorKind 'transport-level 429 is protocol error'
Assert-True ("$($r.message)" -match '429') '429 text preserved for backoff classification'

Start-TestGroup 'errors: rateLimitReachedType surfaced'

$r = Invoke-MockRead 'limit-reached'
Assert-True $r.ok 'read ok'
Assert-Equal 'primary' $r.rateLimitReachedType 'limit type surfaced'

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

Start-TestGroup 'launcher: npm-style codex.cmd wrapper works end to end'

$cmdMock = Join-Path $testsDir 'fixtures\mock-appserver.cmd'
$env:CQK_MOCK_MODE = 'normal'
try {
    $cfgCmd = New-TestConfig @{ codex = @{ command = $cmdMock; queryTimeoutSeconds = 15 } }
    $rcmd = Invoke-CodexRateLimitsRead -Config $cfgCmd
    Assert-True $rcmd.ok "codex.cmd launch works via ComSpec ($($rcmd.message))"
    Assert-Equal 2 @($rcmd.windows).Count 'cmd-wrapped read returns windows'
} finally {
    Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
}

Start-TestGroup 'setup: missing codex command reported'

$cfg = New-TestConfig @{ codex = @{ command = 'auto'; queryTimeoutSeconds = 5 } }
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
