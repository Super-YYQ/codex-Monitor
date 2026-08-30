# Mock Codex app-server for tests/CI. Speaks the same newline-delimited JSON-RPC
# protocol but returns canned rate limit data selected by CQK_MOCK_MODE.
# Never touches the network or real OpenAI credentials.
#
# NOTE: do not touch [Console]::*Encoding here - when spawned with CreateNoWindow
# and redirected pipes (no console attached) the encoding setter can hang.
#
# Modes:
# Modes (v2 quota model per audit plan v1.0 §4):
#   normal        v2 single bucket: limitId/planType + primary + secondary
#   no-secondary  primary only
#   secondary-null secondary explicitly null
#   null-fields   window fields null/missing (partial info, must not fail)
#   changed       usedPercent values differ from 'normal'
#   swapped       primary carries a 10080-min window (identify by windowDurationMins, not name)
#   fractional    usedPercent with decimals
#   multi-bucket  rateLimitsByLimitId with two independent buckets
#   credits       credits / spendControlReached metadata
#   unknown-meta  unknown metadata keys must not break parsing
#   limit-reached rateLimitReachedType set on the result
#   rate-limit    error response mentioning 429/usage limit (backoff path)
#   reset         primary window renewed: old resetsAt past, new resetsAt future
#   unknown-schema rateLimits shape unrecognized -> client must fail closed
#   unrecognized-root result has no rateLimits structure at all
#   auth-error    error response mentioning authentication
#   protocol-error error response unrelated to auth
#   timeout       never answers the quota read (client timeout path)
#   start-failure exits before the handshake

$ErrorActionPreference = 'Stop'

$mode = if ($env:CQK_MOCK_MODE) { $env:CQK_MOCK_MODE } else { 'normal' }
$out = [Console]::Out

function Send-MockResponse {
    param($obj)
    $json = ConvertTo-Json -InputObject $obj -Depth 10 -Compress
    $out.WriteLine($json)
    $out.Flush()
}

function Get-MockWindow {
    param([long]$minutes, [double]$used, [long]$resetsAt)
    return @{ usedPercent = $used; windowDurationMins = $minutes; resetsAt = $resetsAt }
}

if ($mode -eq 'start-failure') { exit 1 }

# --- exec subcommand (AutoAnchor tests): CQK_MOCK_EXEC = ok | fail | timeout ---
if ($args.Count -ge 1 -and $args[0] -eq 'exec') {
    switch ($env:CQK_MOCK_EXEC) {
        'fail' { exit 1 }
        'timeout' { Start-Sleep -Seconds 120; exit 1 }
        default { exit 0 }
    }
}

# --- read countdown: after the first N successful reads, fail (verify-failure tests) ---
$script:CountdownFile = $env:CQK_MOCK_READ_COUNTDOWN_FILE
$script:FailReads = $false
if ($script:CountdownFile) {
    $n = 1
    if (Test-Path $script:CountdownFile) { $n = [int](Get-Content $script:CountdownFile -Raw) }
    $n = $n - 1
    Set-Content -Path $script:CountdownFile -Value ([string]$n)
    if ($n -lt 0) { $script:FailReads = $true }
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $msg = $null
    try { $msg = ConvertFrom-Json $line } catch { continue }
    if ($null -eq $msg -or -not $msg.method) { continue }

    switch ([string]$msg.method) {
        'initialize' {
            Send-MockResponse @{
                jsonrpc = '2.0'; id = $msg.id
                result  = @{ userAgent = @{ name = 'mock-codex'; version = '0.0.0-mock' } }
            }
        }
        'initialized' { }
        'account/rateLimits/read' {
            $id = $msg.id
            if ($script:FailReads) {
                Send-MockResponse @{
                    jsonrpc = '2.0'; id = $id
                    error   = @{ code = -32002; message = 'mock read failure after countdown' }
                }
                continue
            }
            switch ($mode) {
                'timeout' { Start-Sleep -Seconds 120; continue }
                'auth-error' {
                    Send-MockResponse @{
                        jsonrpc = '2.0'; id = $id
                        error   = @{ code = -32000; message = 'not authenticated: please run codex login' }
                    }
                    continue
                }
                'protocol-error' {
                    Send-MockResponse @{
                        jsonrpc = '2.0'; id = $id
                        error   = @{ code = -32601; message = 'method not found' }
                    }
                    continue
                }
                'rate-limit' {
                    Send-MockResponse @{
                        jsonrpc = '2.0'; id = $id
                        error   = @{ code = -32001; message = 'usage limit exceeded (429): slow down and retry later' }
                    }
                    continue
                }
                'unknown-schema' {
                    Send-MockResponse @{
                        jsonrpc = '2.0'; id = $id
                        result  = @{ rateLimits = @{ primary = 'unexpected-string' } }
                    }
                    continue
                }
                'unrecognized-root' {
                    Send-MockResponse @{
                        jsonrpc = '2.0'; id = $id
                        result  = @{ unrelated = 'value' }
                    }
                    continue
                }
            }

            $windows = @{}
            $extra = @{}
            switch ($mode) {
                'normal' {
                    $windows.primary = Get-MockWindow 300 25 1788062400
                    $windows.secondary = Get-MockWindow 10080 18 1788667200
                    $extra.limitId = 'codex-default'
                    $extra.limitName = 'Codex'
                    $extra.planType = 'plus'
                }
                'no-secondary' {
                    $windows.primary = Get-MockWindow 300 12 1788062400
                    $extra.limitId = 'codex-default'
                }
                'secondary-null' {
                    $windows.primary = Get-MockWindow 300 12 1788062400
                    $windows.secondary = $null
                    $extra.limitId = 'codex-default'
                }
                'null-fields' {
                    $windows.primary = @{ usedPercent = 25; windowDurationMins = $null; resetsAt = $null }
                    $windows.secondary = @{ usedPercent = $null; windowDurationMins = 10080; resetsAt = 1788667200 }
                    $extra.limitId = 'codex-default'
                }
                'changed' {
                    $windows.primary = Get-MockWindow 300 42 1788062400
                    $windows.secondary = Get-MockWindow 10080 31 1788667200
                    $extra.limitId = 'codex-default'
                }
                'swapped' {
                    $windows.primary = Get-MockWindow 10080 9 1788667200
                    $extra.limitId = 'codex-default'
                }
                'fractional' {
                    $windows.primary = Get-MockWindow 300 17.5 1788062400
                    $extra.limitId = 'codex-default'
                }
                'unknown-meta' {
                    $windows.primary = Get-MockWindow 300 10 1788062400
                    $windows.secondary = Get-MockWindow 10080 20 1788667200
                    $extra.limitId = 'codex-default'
                    $extra.individualLimit = @{ concurrentSessions = 3 }
                    $extra.futureField = 123
                }
                'credits' {
                    $windows.primary = Get-MockWindow 300 10 1788062400
                    $extra.limitId = 'codex-default'
                    $extra.credits = @{ hasCredits = $true; balance = 42.5 }
                    $extra.spendControlReached = $false
                }
                'limit-reached' {
                    $windows.primary = Get-MockWindow 300 100 1788062400
                    $extra.rateLimitReachedType = 'primary'
                    $extra.limitId = 'codex-default'
                }
                'reset' {
                    $windows.primary = Get-MockWindow 300 2 1900000000
                    $windows.secondary = Get-MockWindow 10080 18 1788667200
                    $extra.limitId = 'codex-default'
                }
                default {
                    $windows.primary = Get-MockWindow 300 25 1788062400
                    $extra.limitId = 'codex-default'
                }
            }

            if ($mode -eq 'multi-bucket') {
                Send-MockResponse @{
                    jsonrpc = '2.0'; id = $id
                    result  = @{
                        rateLimitsByLimitId = @{
                            'bucket-b' = @{ limitId = 'bucket-b'; limitName = 'Bucket B'; planType = 'pro'
                                            secondary = (Get-MockWindow 10080 33 1788667200) }
                            'bucket-a' = @{ limitId = 'bucket-a'; limitName = 'Bucket A'; planType = 'pro'
                                            primary = (Get-MockWindow 300 10 1788062400) }
                        }
                    }
                }
            } else {
                $rateLimits = $windows
                foreach ($k in $extra.Keys) { $rateLimits[$k] = $extra[$k] }
                Send-MockResponse @{
                    jsonrpc = '2.0'; id = $id
                    result  = @{ rateLimits = $rateLimits }
                }
            }
        }
        default { }
    }
}
exit 0
