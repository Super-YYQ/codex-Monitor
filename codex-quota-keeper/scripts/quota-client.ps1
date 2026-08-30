# Codex Quota Keeper - official app-server quota client.
# Speaks newline-delimited JSON-RPC to `codex app-server`:
#   initialize -> initialized -> account/rateLimits/read
# Never reads auth.json, never touches the ChatGPT web UI. Fresh process per read
# so nothing stays resident between polls.

$script:CqkQuotaClientDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkQuotaClientDir 'common.ps1')
}

function Get-CodexServerStartInfo {
    # .ps1 targets (tests use a mock app-server) are launched through pwsh;
    # anything else is treated as the codex executable with the app-server subcommand.
    param([string]$CodexPath)
    if ($CodexPath -match '\.ps1$') {
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
        if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue) }
        if (-not $pwsh) { return $null }
        return @{ exe = $pwsh.Source; args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $CodexPath, 'app-server') }
    }
    return @{ exe = $CodexPath; args = @('app-server') }
}

function Start-AppServerSession {
    param([hashtable]$StartInfo)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $StartInfo.exe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($psi.PSObject.Properties['StandardInputEncoding']) {
        # UTF8Encoding($false): [Encoding]::UTF8 emits a BOM preamble on first write,
        # which corrupts the JSON-RPC line protocol (JSON must start with '{').
        $psi.StandardInputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    if ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $StartInfo.args) { [void]$psi.ArgumentList.Add([string]$a) }
    } else {
        $psi.Arguments = ($StartInfo.args | ForEach-Object { '"' + ("$_" -replace '"', '\"') + '"' }) -join ' '
    }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    return @{
        proc       = $proc
        stdin      = $proc.StandardInput
        stdout     = $proc.StandardOutput
        stderrTask = $stderrTask
    }
}

function Stop-AppServerSession {
    param($Session)
    if (-not $Session) { return }
    try { $Session.stdin.Close() } catch { }
    $proc = $Session.proc
    if (-not $proc.HasExited) {
        if (-not $proc.WaitForExit(2000)) {
            try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
        }
    }
    try { $proc.Dispose() } catch { }
}

function Send-AppServerMessage {
    param($Session, $Message)
    $json = ConvertTo-Json -InputObject $Message -Depth 10 -Compress
    $Session.stdin.WriteLine($json)
    $Session.stdin.Flush()
}

function Wait-AppServerResponse {
    # Reads stdout lines until the response with the wanted id arrives.
    # Notifications and unrelated messages are skipped. Honors a hard deadline.
    param($Session, [int]$Id, [int]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        if ([DateTime]::UtcNow -gt $deadline) {
            return @{ ok = $false; kind = 'TIMEOUT'; message = "timed out after ${TimeoutSeconds}s waiting for response id $Id" }
        }
        $task = $Session.stdout.ReadLineAsync()
        while (-not $task.IsCompleted) {
            if ([DateTime]::UtcNow -gt $deadline) {
                return @{ ok = $false; kind = 'TIMEOUT'; message = "timed out after ${TimeoutSeconds}s waiting for response id $Id" }
            }
            Start-Sleep -Milliseconds 20
        }
        $line = $task.GetAwaiter().GetResult()
        if ($null -eq $line) {
            return @{ ok = $false; kind = 'EOF'; message = 'app-server closed stdout before responding' }
        }
        # Defensive: strip a UTF-8 BOM if the child emits one.
        $line = $line.TrimStart([char]0xFEFF)
        $msg = ConvertFrom-JsonSafe $line
        if ($null -eq $msg) { continue }
        if ("$($msg.id)" -ne "$Id") { continue }
        return @{ ok = $true; response = $msg }
    }
}

function Test-NumericValue {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $true }
    $n = 0L
    return ([long]::TryParse("$Value", [ref]$n))
}

function ConvertTo-Numeric {
    param($Value)
    if ($Value -is [int] -or $Value -is [long]) { return [long]$Value }
    if ($Value -is [double] -or $Value -is [decimal]) { return [long][Math]::Round([double]$Value) }
    return [long]$Value
}

function Get-RateLimitReachedType {
    # The field may appear on the result or nested in rateLimits; anywhere else counts as absent.
    param($Result)
    if ($Result -is [hashtable]) {
        if ($Result.ContainsKey('rateLimitReachedType') -and $Result.rateLimitReachedType) {
            return [string]$Result.rateLimitReachedType
        }
        if ($Result.ContainsKey('rateLimits') -and $Result.rateLimits -is [hashtable] -and
            $Result.rateLimits.ContainsKey('rateLimitReachedType') -and $Result.rateLimits.rateLimitReachedType) {
            return [string]$Result.rateLimits.rateLimitReachedType
        }
    }
    return $null
}

function ConvertFrom-RateLimitsResponse {
    # Normalizes the app-server response into windows keyed by windowDurationMins.
    # Unknown structures yield schemaUnknown=true so callers fail closed.
    param($Response)
    if ($Response -is [hashtable] -and $Response.ContainsKey('error') -and $Response.error) {
        $errText = ''
        $errCode = ''
        if ($Response.error -is [hashtable]) {
            $errText = [string]$Response.error.message
            $errCode = [string]$Response.error.code
        } else {
            $errText = "$($Response.error)"
        }
        $combined = "$errCode $errText"
        $kind = 'PROTOCOL_ERROR'
        if ($combined -match '(?i)auth|login|unauthor|401|403|not\s+logged') { $kind = 'AUTH_ERROR' }
        return @{ ok = $false; windows = @(); rateLimitReachedType = $null; schemaUnknown = $false;
                  errorKind = $kind; message = (Hide-SensitiveText "app-server error ($errCode): $errText") }
    }

    $result = $null
    if ($Response -is [hashtable] -and $Response.ContainsKey('result')) { $result = $Response.result }
    if ($result -isnot [hashtable]) {
        return @{ ok = $false; windows = @(); rateLimitReachedType = $null; schemaUnknown = $true;
                  errorKind = 'SCHEMA_UNKNOWN'; message = 'response result is not an object' }
    }

    $rl = $null
    if ($result.ContainsKey('rateLimits')) { $rl = $result.rateLimits }
    if ($rl -isnot [hashtable]) {
        return @{ ok = $false; windows = @(); rateLimitReachedType = $null; schemaUnknown = $true;
                  errorKind = 'SCHEMA_UNKNOWN'; message = 'rateLimits object missing' }
    }

    # Some plans/periods return only one window, and rateLimits may carry extra
    # non-window fields (rateLimitReachedType). Validate only keys actually present;
    # 'primary'/'secondary' keep their canonical order, the rest follow alphabetically.
    $present = @($rl.Keys)
    $names = @()
    foreach ($n in @('primary', 'secondary')) {
        if ($present -ccontains $n) { $names += $n }
    }
    $names += @($present | Where-Object { $_ -ne 'primary' -and $_ -ne 'secondary' -and $_ -ne 'rateLimitReachedType' } | Sort-Object)

    $windows = @()
    $schemaUnknown = $false
    foreach ($name in $names) {
        $w = $rl[$name]
        if ($w -isnot [hashtable]) { $schemaUnknown = $true; continue }
        if (-not (Test-NumericValue $w['windowDurationMins']) -or
            -not (Test-NumericValue $w['usedPercent']) -or
            -not (Test-NumericValue $w['resetsAt'])) {
            $schemaUnknown = $true
            continue
        }
        $usedRaw = $w['usedPercent']
        $used = [double]0
        if ($usedRaw -is [double] -or $usedRaw -is [decimal]) { $used = [double]$usedRaw }
        else { $used = [double](ConvertTo-Numeric $usedRaw) }
        $windows += ,@{
            name        = [string]$name
            minutes     = ConvertTo-Numeric $w['windowDurationMins']
            usedPercent = $used
            resetsAt    = ConvertTo-Numeric $w['resetsAt']
        }
    }

    if ($schemaUnknown -or @($windows).Count -eq 0) {
        # Fail closed: an unrecognized structure must never reach the state machine
        # or AutoAnchor. Well-formed unknown window *names* were kept above; only
        # entries missing required fields land here.
        return @{ ok = $false; windows = @(); rateLimitReachedType = $null; schemaUnknown = $true;
                  errorKind = 'SCHEMA_UNKNOWN'; message = 'rateLimits structure not recognized; failing closed' }
    }

    return @{
        ok                   = $true
        windows              = $windows
        rateLimitReachedType = Get-RateLimitReachedType $result
        schemaUnknown        = $false
        errorKind            = $null
        message              = $null
    }
}

function Invoke-CodexRateLimitsRead {
    # One read-only quota probe against the official app-server protocol.
    # Returns @{ ok; windows; rateLimitReachedType; schemaUnknown; errorKind; message }
    param(
        [hashtable]$Config,
        [string]$CodexPath = '',
        [int]$TimeoutSeconds = 0
    )
    $empty = { @{ ok = $false; windows = @(); rateLimitReachedType = $null; schemaUnknown = $false; errorKind = $null; message = $null } }
    $out = & $empty

    if (-not $TimeoutSeconds -or $TimeoutSeconds -le 0) { $TimeoutSeconds = [int]$Config.codex.queryTimeoutSeconds }
    if (-not $CodexPath) { $CodexPath = Resolve-CodexCommand $Config }
    if (-not $CodexPath) {
        $out.errorKind = 'SETUP_ERR'
        $out.message = 'codex executable not found (set codex.command in config.json)'
        return $out
    }
    $startInfo = Get-CodexServerStartInfo $CodexPath
    if (-not $startInfo) {
        $out.errorKind = 'SETUP_ERR'
        $out.message = 'no PowerShell available to run the configured codex command'
        return $out
    }

    $session = $null
    try {
        $session = Start-AppServerSession $startInfo
        if ($session.proc.HasExited) {
            $out.errorKind = 'SETUP_ERR'
            $out.message = 'app-server process exited immediately'
            return $out
        }

        Send-AppServerMessage -Session $session -Message @{
            jsonrpc = '2.0'; id = 1; method = 'initialize'
            params  = @{ clientInfo = @{ name = 'codex-quota-keeper'; title = 'Codex Quota Keeper'; version = $script:CQK_VERSION } }
        }
        $handshake = Wait-AppServerResponse $session -Id 1 -TimeoutSeconds $TimeoutSeconds
        if (-not $handshake.ok) {
            $out.errorKind = $handshake.kind
            $out.message = (Hide-SensitiveText $handshake.message)
            return $out
        }

        Send-AppServerMessage -Session $session -Message @{ jsonrpc = '2.0'; method = 'initialized' }

        Send-AppServerMessage -Session $session -Message @{
            jsonrpc = '2.0'; id = 7; method = 'account/rateLimits/read'; params = @{}
        }
        $reply = Wait-AppServerResponse $session -Id 7 -TimeoutSeconds $TimeoutSeconds
        if (-not $reply.ok) {
            $out.errorKind = $reply.kind
            $out.message = (Hide-SensitiveText $reply.message)
            return $out
        }
        return ConvertFrom-RateLimitsResponse $reply.response
    } catch {
        $out.errorKind = 'PROTOCOL_ERROR'
        $out.message = (Hide-SensitiveText "app-server client failure: $($_.Exception.Message)")
        return $out
    } finally {
        Stop-AppServerSession $session
    }
}
