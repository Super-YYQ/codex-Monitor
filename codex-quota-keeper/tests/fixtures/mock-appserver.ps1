# Mock Codex app-server for tests/CI. Speaks the same newline-delimited JSON-RPC
# protocol but returns canned rate limit data selected by CQK_MOCK_MODE.
# Never touches the network or real OpenAI credentials.
#
# NOTE: do not touch [Console]::*Encoding here - when spawned with CreateNoWindow
# and redirected pipes (no console attached) the encoding setter can hang.
#
# Modes:
#   normal        primary (300 min) + secondary (10080 min)
#   no-secondary  primary only
#   changed       usedPercent values differ from 'normal'
#   swapped       primary carries a 10080-min window (identify by windowDurationMins, not name)
#   fractional    usedPercent with decimals
#   limit-reached rateLimitReachedType set on the result
#   unknown-schema rateLimits shape unrecognized -> client must fail closed
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
                'unknown-schema' {
                    Send-MockResponse @{
                        jsonrpc = '2.0'; id = $id
                        result  = @{ rateLimits = @{ primary = 'unexpected-string' } }
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
                }
                'no-secondary' {
                    $windows.primary = Get-MockWindow 300 12 1788062400
                }
                'changed' {
                    $windows.primary = Get-MockWindow 300 42 1788062400
                    $windows.secondary = Get-MockWindow 10080 31 1788667200
                }
                'swapped' {
                    $windows.primary = Get-MockWindow 10080 9 1788667200
                }
                'fractional' {
                    $windows.primary = Get-MockWindow 300 17.5 1788062400
                }
                'limit-reached' {
                    $windows.primary = Get-MockWindow 300 100 1788062400
                    $extra.rateLimitReachedType = 'primary'
                }
                'extra-window' {
                    $windows.primary = Get-MockWindow 300 10 1788062400
                    $windows.secondary = Get-MockWindow 10080 20 1788667200
                    $windows.tertiary = Get-MockWindow 43200 5 1790000000
                }
                default {
                    $windows.primary = Get-MockWindow 300 25 1788062400
                }
            }

            $rateLimits = $windows
            foreach ($k in $extra.Keys) { $rateLimits[$k] = $extra[$k] }
            Send-MockResponse @{
                jsonrpc = '2.0'; id = $id
                result  = @{ rateLimits = $rateLimits }
            }
        }
        default { }
    }
}
exit 0
