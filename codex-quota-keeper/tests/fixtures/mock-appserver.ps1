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
#   multi-reset-baseline / multi-reset
#                 the same multi-bucket pair, each bucket carrying a PRIMARY
#                 window whose resetsAt advances between the two modes - doc
#                 v3.0 §19 T08's "2 resets in one tick" input (the ordinary
#                 multi-bucket mode cannot produce it: bucket-b has no primary)
#   credits       credits / spendControlReached metadata
#   unknown-meta  unknown metadata keys must not break parsing
#   limit-reached rateLimitReachedType set on the result
#   rate-limit    error response mentioning 429/usage limit (backoff path)
#   network-error transport failure wording ("error sending request", must NOT be classified 429)
#   idle          zero usage on both windows (never-used account, scenario-1 idle detection)
#   reset         primary window renewed: old resetsAt past, new resetsAt future
#   unknown-schema rateLimits shape unrecognized -> client must fail closed
#   unrecognized-root result has no rateLimits structure at all
#   auth-error    error response mentioning authentication
#   protocol-error error response unrelated to auth
#   timeout       never answers the quota read (client timeout path)
#   start-failure exits before the handshake
#
# Execution Profile modes (CQK-037/038) - config/read and model/list:
#   (default)     config/read answers with an effective config carrying model,
#                 model_reasoning_effort and noisy non-whitelisted keys; model/list
#                 answers with the full 6-entry catalog in one page
#   config-empty  config/read answers with no model keys at all (catalog default path)
#   config-error  config/read answers with an auth error
#   catalog-paged model/list serves the catalog 2 entries per page no matter the
#                 requested limit, so a client that stops at page 1 misses models
#   catalog-cap   model/list never runs out of cursors (client page cap must fire)
#   catalog-error model/list answers with an error (UNAVAILABLE path)
#   catalog-timeout model/list never answers (client timeout path)
#   catalog-badschema model/list data is not a list
#   catalog-hidden  every catalog entry is hidden: only a request that passes
#                 includeHidden=true sees them (a client that asks for the visible
#                 page alone would read an empty catalog and wrongly reject a model)

$ErrorActionPreference = 'Stop'

$mode = if ($env:CQK_MOCK_MODE) { $env:CQK_MOCK_MODE } else { 'normal' }
$out = [Console]::Out

# --- diagnostic trace (tests only) -----------------------------------------
# The shared session layer captures the child's PID; on a TIMEOUT it reads this
# file's tail to say whether the mock started / received / parsed / sent. File
# name must match Start-CodexAppServerSession's reader (app-server-client.ps1).
$script:TraceFile = $null
try {
    $traceDir = Join-Path $env:TEMP 'cqk-mock-trace'
    New-Item -ItemType Directory -Path $traceDir -Force | Out-Null
    $script:TraceFile = Join-Path $traceDir ('cqk-mock-{0}.trace' -f $PID)
} catch { }

function Write-MockTrace {
    param([string]$Text)
    if (-not $script:TraceFile) { return }
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Text
        [System.IO.File]::AppendAllText($script:TraceFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

Write-MockTrace ("started pid={0} mode={1} psver={2} pshome={3}" -f $PID, $mode, $PSVersionTable.PSVersion, $PSHOME)
try {
    Write-MockTrace ("console: InEnc={0} OutEnc={1} InRedirected={2} OutRedirected={3}" -f `
        [Console]::In.Encoding.WebName, [Console]::Out.Encoding.WebName, [Console]::IsInputRedirected,
        [Console]::IsOutputRedirected)
} catch {
    Write-MockTrace ("console: probe failed: {0}" -f $_.Exception.Message)
}

function Send-MockResponse {
    param($obj)
    $json = ConvertTo-Json -InputObject $obj -Depth 10 -Compress
    $out.WriteLine($json)
    $out.Flush()
    Write-MockTrace ("sent: id={0} len={1}" -f $obj.id, $json.Length)
}

function Get-MockWindow {
    param([long]$minutes, [double]$used, [long]$resetsAt)
    return @{ usedPercent = $used; windowDurationMins = $minutes; resetsAt = $resetsAt }
}

# --- Execution Profile fixtures (CQK-037/038) -------------------------------
# Names are deliberately synthetic (mock-model-*): the repository must never ship a
# list that looks like a real model whitelist (doc v3.0 §22). The shapes, however,
# copy what the live CLI sends - notably `supportedReasoningEfforts` as an ARRAY OF
# OBJECTS, opaque string cursors, hidden entries, and a pile of fields the client is
# required to throw away.
function Get-MockEfforts {
    param([string[]]$Efforts)
    $list = @()
    foreach ($e in $Efforts) { $list += @{ reasoningEffort = $e; description = "mock reasoning effort $e" } }
    return ,$list
}

function Get-MockParamValue {
    # RPC params arrive as PSCustomObject (ConvertFrom-Json) or hashtable depending
    # on the runtime, and 5.1 has no `.TryGetValue` on PSCustomObject. One accessor
    # for both shapes; $null means "absent".
    param($Params, [string]$Name)
    if ($null -eq $Params) { return $null }
    if ($Params -is [hashtable]) {
        if ($Params.ContainsKey($Name)) { return $Params[$Name] }
        return $null
    }
    $prop = $Params.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-MockCatalogEntries {
    $all = @(
        @{ model = 'mock-model-alpha'; id = 'mock-model-alpha'; displayName = 'Mock Alpha'
           description = 'first mock entry'; hidden = $false; isDefault = $true
           defaultReasoningEffort = 'low'; supportedReasoningEfforts = (Get-MockEfforts @('low', 'medium', 'high'))
           inputModalities = @('text'); serviceTiers = @('default') }
        @{ model = 'mock-model-beta'; id = 'mock-model-beta'; displayName = 'Mock Beta'
           description = 'second mock entry'; hidden = $false; isDefault = $false
           defaultReasoningEffort = 'medium'; supportedReasoningEfforts = (Get-MockEfforts @('low', 'medium', 'high', 'xhigh'))
           inputModalities = @('text', 'image') }
        @{ model = 'mock-model-gamma'; id = 'mock-model-gamma'; displayName = 'Mock Gamma'
           description = 'third mock entry'; hidden = $false; isDefault = $false
           defaultReasoningEffort = 'medium'; supportedReasoningEfforts = (Get-MockEfforts @('medium', 'high'))
           inputModalities = @('text') }
        @{ model = 'mock-model-delta'; id = 'mock-model-delta'; displayName = 'Mock Delta'
           description = 'fourth mock entry'; hidden = $false; isDefault = $false
           defaultReasoningEffort = 'high'; supportedReasoningEfforts = (Get-MockEfforts @('high'))
           inputModalities = @('text') }
        @{ model = 'mock-model-epsilon'; id = 'mock-model-epsilon'; displayName = 'Mock Epsilon'
           description = 'fifth mock entry'; hidden = $false; isDefault = $false
           defaultReasoningEffort = 'low'; supportedReasoningEfforts = (Get-MockEfforts @('low', 'medium'))
           inputModalities = @('text') }
        # Page-2 resident in catalog-paged mode: the entry a client that stops after
        # the first page would wrongly declare invalid.
        @{ model = 'mock-model-zeta'; id = 'mock-model-zeta'; displayName = 'Mock Zeta'
           description = 'last visible mock entry'; hidden = $false; isDefault = $false
           defaultReasoningEffort = 'low'; supportedReasoningEfforts = (Get-MockEfforts @('low', 'medium', 'high'))
           inputModalities = @('text') }
        # Never advertised unless the client passes includeHidden.
        @{ model = 'mock-model-retired'; id = 'mock-model-retired'; displayName = 'Mock Retired'
           description = 'hidden mock entry'; hidden = $true; isDefault = $false
           defaultReasoningEffort = 'low'; supportedReasoningEfforts = (Get-MockEfforts @('low'))
           inputModalities = @('text') }
    )
    return $all
}

if ($mode -eq 'start-failure') { exit 1 }

# --- proxy fallback test hook: die when the keeper-set proxy env is present ---
# The test config points codex.proxy at CQK_MOCK_PROXY_URL; the mock exits only
# when HTTPS_PROXY actually equals it, so a system-level proxy on the test host
# cannot make the fallback assertion flaky.
if ($env:CQK_MOCK_FAIL_WITH_PROXY -eq '1' -and $env:CQK_MOCK_PROXY_URL -and $env:HTTPS_PROXY -eq $env:CQK_MOCK_PROXY_URL) {
    Write-MockTrace 'proxy env present -> exiting (CQK_MOCK_FAIL_WITH_PROXY)'
    exit 1
}

# --- exec subcommand (AutoAnchor tests): CQK_MOCK_EXEC = ok | fail | timeout ---
# The full argument line is appended to CQK_MOCK_EXEC_ARGS_FILE so tests can
# assert exactly which flags the keeper passed to the CLI (model / reasoning
# effort passthrough).
if ($args.Count -ge 1 -and $args[0] -eq 'exec') {
    Write-MockTrace ("exec: mode={0}" -f $env:CQK_MOCK_EXEC)
    if ($env:CQK_MOCK_EXEC_ARGS_FILE) {
        try {
            $argLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            [System.IO.File]::AppendAllText($env:CQK_MOCK_EXEC_ARGS_FILE, $argLine + [Environment]::NewLine,
                (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
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

# --- stdin: read RAW bytes, decode UTF-8 ourselves --------------------------
# [Console]::In applies the console input encoding, and the parent (Windows
# PowerShell 5.1, .NET Framework) cannot set StandardInputEncoding - the writer
# and the reader can then disagree (observed on CI: 6 garbage bytes prepended to
# the first line). Reading the pipe stream directly keeps the JSON-RPC wire
# format intact regardless of what encoding the child inherited.
$script:StdinStream = $null
try { $script:StdinStream = [Console]::OpenStandardInput() } catch { }
$script:RawBuf = New-Object System.Text.StringBuilder
$script:Chunk = New-Object byte[] 4096

function Read-MockLine {
    # Returns the next newline-terminated line (UTF-8, leading BOM stripped),
    # or $null on EOF. Buffers partial pipe reads across chunks.
    if ($null -eq $script:StdinStream) { return [Console]::In.ReadLine() }
    while ($true) {
        $text = $script:RawBuf.ToString()
        $idx = $text.IndexOf("`n")
        if ($idx -ge 0) {
            $line = $text.Substring(0, $idx)
            $script:RawBuf.Length = 0
            [void]$script:RawBuf.Append($text.Substring($idx + 1))
            if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
            if ($line.StartsWith([char]0xFEFF)) { $line = $line.Substring(1) }
            return $line
        }
        $n = $script:StdinStream.Read($script:Chunk, 0, $script:Chunk.Length)
        if ($n -le 0) { return $null }
        [void]$script:RawBuf.Append([System.Text.Encoding]::UTF8.GetString($script:Chunk, 0, $n))
    }
}

while ($true) {
    $line = Read-MockLine
    if ($null -eq $line) { Write-MockTrace 'stdin: EOF'; break }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $hex = (($line.ToCharArray() | ForEach-Object { '{0:X2}' -f [int]$_ }) | Select-Object -First 48) -join ' '
    if ($line.Length -gt 48) { $hex += '...' }
    Write-MockTrace ("recv: len={0} hex={1}" -f $line.Length, $hex)
    $msg = $null
    try { $msg = ConvertFrom-Json $line } catch { }
    if ($null -eq $msg -or -not $msg.method) { Write-MockTrace 'recv: not parseable (no method)'; continue }
    Write-MockTrace ("recv: method={0} id={1}" -f [string]$msg.method, [string]$msg.id)

    switch ([string]$msg.method) {
        'initialize' {
            # CQK-038: one line per session. A test can then prove that the
            # Execution Profile resolver read config/read AND model/list over ONE
            # session - one child process, one environment, which is what doc
            # v3.0 §6.2 requires ("Profile 必须在与真正 codex exec 相同的 Codex
            # 环境中解析"). Two sessions would mean two environments.
            if ($env:CQK_MOCK_SESSIONS_FILE) {
                try {
                    [System.IO.File]::AppendAllText($env:CQK_MOCK_SESSIONS_FILE, 'session' + [Environment]::NewLine,
                        (New-Object System.Text.UTF8Encoding($false)))
                } catch { }
            }
            Send-MockResponse @{
                jsonrpc = '2.0'; id = $msg.id
                result  = @{ userAgent = @{ name = 'mock-codex'; version = '0.0.0-mock' } }
            }
        }
        'initialized' { }
        'config/read' {
            if ($mode -eq 'config-error') {
                Send-MockResponse @{
                    jsonrpc = '2.0'; id = $msg.id
                    error   = @{ code = -32000; message = 'not authenticated: please run codex login' }
                }
                continue
            }
            # The real blob is enormous and full of things that must never leave the
            # client (absolute paths, hook executables, env hashes, permissions).
            # The fixture mirrors that: the whitelisted keys plus a lot of noise.
            if ($mode -eq 'config-empty') {
                Send-MockResponse @{
                    jsonrpc = '2.0'; id = $msg.id
                    result  = @{ config = @{ model_provider = $null; notify = @('C:\mock\hook.exe') } }
                }
                continue
            }
            Send-MockResponse @{
                jsonrpc = '2.0'; id = $msg.id
                result  = @{
                    config = @{
                        model                          = 'mock-model-beta'
                        model_reasoning_effort         = 'high'
                        model_provider                 = 'mock-provider'
                        notify                         = @('C:\mock\hook.exe')
                        instructions                   = 'mock free-form instructions'
                        shell_environment_policy       = @{ set = @{ MOCK_SHA256S = 'deadbeef' } }
                        'desktop.enabled-reasoning-efforts' = @('low', 'medium', 'high')
                        cwd                            = 'C:\mock\private\path'
                    }
                }
            }
        }
        'model/list' {
            if ($mode -eq 'catalog-error') {
                Send-MockResponse @{
                    jsonrpc = '2.0'; id = $msg.id
                    error   = @{ code = -32000; message = 'not authenticated: please run codex login' }
                }
                continue
            }
            if ($mode -eq 'catalog-timeout') { Start-Sleep -Seconds 120; continue }
            if ($mode -eq 'catalog-badschema') {
                Send-MockResponse @{ jsonrpc = '2.0'; id = $msg.id; result = @{ data = 'not-a-list' } }
                continue
            }
            $allEntries = @(Get-MockCatalogEntries)
            $includeHidden = [bool](Get-MockParamValue $msg.params 'includeHidden')
            # Hidden entries are only advertised when the client asks for them.
            $visible = @($allEntries | Where-Object { $includeHidden -or -not $_.hidden })
            if ($mode -eq 'catalog-hidden') {
                # Only hidden entries exist in this catalog: a client that never
                # passes includeHidden reads an empty page.
                $visible = @($allEntries | Where-Object { $includeHidden -and $_.hidden })
            }
            $visibleCount = @($visible).Count
            $reqLimit = 0
            $limitValue = Get-MockParamValue $msg.params 'limit'
            if ($null -ne $limitValue -and $limitValue -ne '') { $reqLimit = [int]$limitValue }
            $pageSize = if ($reqLimit -gt 0) { $reqLimit } else { $visibleCount }
            # catalog-cap: hand back a cursor forever so the client's page cap fires.
            if ($mode -eq 'catalog-cap') { $pageSize = 1 }
            # catalog-paged: ignore the requested limit and serve 2 per page, which is
            # what makes a first-page-only client fail to see the last entry.
            if ($mode -eq 'catalog-paged') { $pageSize = 2 }
            if ($pageSize -lt 1) { $pageSize = 1 }

            $cursorText = Get-MockParamValue $msg.params 'cursor'
            $offset = 0
            if ($null -ne $cursorText -and "$cursorText" -ne '') {
                $parsed = 0L
                # Cursors are opaque to the client but the real server rejects a bad
                # one outright - mirrored here, because treating it as "no more pages"
                # is exactly the bug the pagination cap exists to avoid.
                if (-not [long]::TryParse("$cursorText", [ref]$parsed)) {
                    Send-MockResponse @{
                        jsonrpc = '2.0'; id = $msg.id
                        error   = @{ code = -32600; message = ('invalid cursor: {0}' -f $cursorText) }
                    }
                    continue
                }
                $offset = [int]$parsed
            }
            $page = @()
            if ($offset -lt $visibleCount) {
                $take = $pageSize
                if ($mode -ne 'catalog-cap' -and $offset + $take -gt $visibleCount) { $take = $visibleCount - $offset }
                if ($take -lt 1) { $take = 1 }
                $page = @($visible | Select-Object -Skip $offset -First $take)
            }
            $next = $null
            if ($mode -eq 'catalog-cap') {
                $next = [string]($offset + 1)
            } elseif ($offset + $pageSize -lt $visibleCount) {
                $next = [string]($offset + $pageSize)
            }
            Send-MockResponse @{
                jsonrpc = '2.0'; id = $msg.id
                result  = @{ data = @($page); nextCursor = $next }
            }
        }
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
                'network-error' {
                    Send-MockResponse @{
                        jsonrpc = '2.0'; id = $id
                        error   = @{ code = -32603; message = 'failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)' }
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
                'idle' {
                    # Never-used account: zero usage, window boundary fixed (never
                    # slides) so consecutive polls observe no reset - exactly the
                    # input the real server gives a fresh, unused ChatGPT plan.
                    $windows.primary = Get-MockWindow 300 0 1788062400
                    $windows.secondary = Get-MockWindow 10080 0 1788667200
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
            } elseif ($mode -eq 'multi-reset-baseline' -or $mode -eq 'multi-reset') {
                # T08 (doc v3.0 §19): "2 resets in the same tick -> 2 claims + 1
                # exec + 1 invocation audit". Both buckets must carry a PRIMARY
                # window, and the two modes must agree on the window KEYS
                # (bucketId|windowType) and on windowDurationMins - a key missing
                # from the previous snapshot is skipped (state-machine.ps1
                # Get-StateEvents) and the duration is part of the event id.
                # Only resetsAt may advance, which is what makes the reset fire.
                $reset = ($mode -eq 'multi-reset')
                Send-MockResponse @{
                    jsonrpc = '2.0'; id = $id
                    result  = @{
                        rateLimitsByLimitId = @{
                            'bucket-b' = @{ limitId = 'bucket-b'; limitName = 'Bucket B'; planType = 'pro'
                                            primary = (Get-MockWindow 300 $(if ($reset) { 3 } else { 10 }) $(if ($reset) { 1900001000 } else { 1788063000 })) }
                            'bucket-a' = @{ limitId = 'bucket-a'; limitName = 'Bucket A'; planType = 'pro'
                                            primary = (Get-MockWindow 300 $(if ($reset) { 2 } else { 10 }) $(if ($reset) { 1900000000 } else { 1788062400 })) }
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
