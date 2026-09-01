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
    # Launches any codex shape (native exe, npm codex.cmd, or a mock .ps1) through
    # the unified launcher (CQK-004).
    param([string]$CodexPath)
    return (Resolve-ExecutableLaunchSpec -Executable $CodexPath -ArgumentList @('app-server'))
}

function Start-AppServerSession {
    param(
        [hashtable]$StartInfo,
        [hashtable]$Environment = @{}
    )
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
    if ($StartInfo.ContainsKey('rawArgs') -and $StartInfo.rawArgs) {
        $psi.Arguments = [string]$StartInfo.rawArgs
    }
    elseif ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $StartInfo.args) { [void]$psi.ArgumentList.Add([string]$a) }
    } else {
        $psi.Arguments = ($StartInfo.args | ForEach-Object { '"' + ("$_" -replace '"', '\"') + '"' }) -join ' '
    }
    # Must be set before Start(); the child inherits the parent's environment
    # first, and these keys override/append it (proxy config, CQK-020).
    if ($Environment) {
        foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Environment[$k] }
    }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    # Pipe encodings + mock trace path are captured here so a TIMEOUT can report
    # exactly how the child was wired (5.1 and 7 take different code paths).
    $traceFile = $null
    if ($env:TEMP) { $traceFile = Join-Path (Join-Path $env:TEMP 'cqk-mock-trace') ('cqk-mock-{0}.trace' -f $proc.Id) }
    $launchSpec = if ($StartInfo.ContainsKey('rawArgs') -and $StartInfo.rawArgs) {
        ('"{0}" {1}' -f $StartInfo.exe, [string]$StartInfo.rawArgs)
    } else {
        ('"{0}" {1}' -f $StartInfo.exe, (($StartInfo.args | ForEach-Object { '"' + $_ + '"' }) -join ' '))
    }
    return @{
        proc           = $proc
        stdin          = $proc.StandardInput
        stdout         = $proc.StandardOutput
        stderrTask     = $stderrTask
        stdinEncoding  = [string]$proc.StandardInput.Encoding.WebName
        stdoutEncoding = [string]$proc.StandardOutput.Encoding.WebName
        traceFile      = $traceFile
        lastWritten    = $null
        launchSpec     = $launchSpec
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
    $Session.lastWritten = $json
}

function Get-AppServerFailureDetail {
    # One-line diagnostics for TIMEOUT/EOF failures: pipe encodings, what was
    # last written, the child's own trace (mock fixtures only), and stderr state.
    # Surfaces which pipe boundary broke without a debugger.
    param($Session, [int]$Id)
    $parts = @('id=' + $Id)
    if ($null -ne $Session) {
        if ($Session.launchSpec) { $parts += ('launch=' + $Session.launchSpec) }
        if ($Session.stdinEncoding)  { $parts += ('stdin=' + $Session.stdinEncoding) }
        if ($Session.stdoutEncoding) { $parts += ('stdout=' + $Session.stdoutEncoding) }
        if ($Session.lastWritten) {
            $parts += ('wrote=' + $Session.lastWritten.Substring(0, [Math]::Min(48, $Session.lastWritten.Length)))
        }
        if ($Session.traceFile -and (Test-Path -LiteralPath $Session.traceFile)) {
            $tail = @(Get-Content -LiteralPath $Session.traceFile -Tail 6 -ErrorAction SilentlyContinue)
            if (@($tail).Count -gt 0) { $parts += ('mockTrace=' + ($tail -join ' | ')) }
        } else {
            $parts += 'mockTrace=<none>'
        }
        if ($Session.proc) {
            if ($Session.proc.HasExited) {
                $parts += ('procExited=True exitCode=' + $Session.proc.ExitCode)
            } else {
                $parts += 'procExited=False'
                if ($Session.stderrTask.IsCompleted) { $parts += 'stderr=<closed>' } else { $parts += 'stderr=<open>' }
            }
        }
    }
    return ($parts -join '; ')
}

function Wait-AppServerResponse {
    # Reads stdout lines until the response with the wanted id arrives.
    # Notifications and unrelated messages are skipped. Honors a hard deadline.
    param($Session, [int]$Id, [int]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        if ([DateTime]::UtcNow -gt $deadline) {
            return @{ ok = $false; kind = 'TIMEOUT'; message = ("timed out after {0}s waiting for response id {1} [{2}]" -f $TimeoutSeconds, $Id, (Get-AppServerFailureDetail $Session $Id)) }
        }
        $task = $Session.stdout.ReadLineAsync()
        while (-not $task.IsCompleted) {
            if ([DateTime]::UtcNow -gt $deadline) {
                return @{ ok = $false; kind = 'TIMEOUT'; message = ("timed out after {0}s waiting for response id {1} [{2}]" -f $TimeoutSeconds, $Id, (Get-AppServerFailureDetail $Session $Id)) }
            }
            Start-Sleep -Milliseconds 20
        }
        $line = $task.GetAwaiter().GetResult()
        if ($null -eq $line) {
            return @{ ok = $false; kind = 'EOF'; message = ("app-server closed stdout before responding [{0}]" -f (Get-AppServerFailureDetail $Session $Id)) }
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

# ---------------------------------------------------------------------------
# QuotaSnapshot model (CQK-001, audit plan v1.0 §4)
#
#   snapshot := @{
#     ok; sourceSchemaVersion; accountPlanType; buckets[];
#     rateLimitReachedType?; credits?; spendControlReached?; rawMetadata;
#     schemaUnknown; errorKind; message
#   }
#   bucket := @{ bucketId; bucketName?; planType?; windows[] }
#   window := @{ windowType; usable; windowDurationMins?; usedPercent?; resetsAt? }
#
# Parsing is whitelist-based (primary/secondary window keys only). Unknown
# metadata keys are preserved in rawMetadata and never reach reset logic or
# the AutoAnchor guard. Optional/null fields degrade the window instead of
# failing the whole response.

$script:CQK_WINDOW_KEYS = @('primary', 'secondary')
$script:CQK_RATELIMITS_META_KEYS = @(
    'primary', 'secondary', 'limitId', 'limitName', 'planType', 'credits',
    'spendControlReached', 'rateLimitReachedType', 'individualLimit'
)

function Get-QuotaSnapshotWindow {
    # $null -> window absent. Hashtable -> usable (fields may be null/partial).
    # Anything else -> unusable window, response is degraded, not a crash.
    param([string]$WindowType, $Window)
    if ($null -eq $Window) { return $null }
    if ($Window -isnot [hashtable]) {
        return @{ windowType = $WindowType; usable = $false; unusableReason = 'window-not-an-object';
                  windowDurationMins = $null; usedPercent = $null; resetsAt = $null }
    }
    $duration = if (Test-NumericValue $Window['windowDurationMins']) { ConvertTo-Numeric $Window['windowDurationMins'] } else { $null }
    $used = $null
    if (Test-NumericValue $Window['usedPercent']) {
        if ($Window['usedPercent'] -is [double] -or $Window['usedPercent'] -is [decimal]) { $used = [double]$Window['usedPercent'] }
        else { $used = [double](ConvertTo-Numeric $Window['usedPercent']) }
    }
    $resets = if (Test-NumericValue $Window['resetsAt']) { ConvertTo-Numeric $Window['resetsAt'] } else { $null }
    return @{ windowType = [string]$WindowType; usable = $true; unusableReason = $null;
              windowDurationMins = $duration; usedPercent = $used; resetsAt = $resets }
}

function Get-QuotaSnapshotBucket {
    param([string]$BucketId, $Bucket)
    $windows = @()
    $allUsable = $false
    if ($Bucket -is [hashtable]) {
        $allUsable = $true
        foreach ($name in $script:CQK_WINDOW_KEYS) {
            $w = Get-QuotaSnapshotWindow -WindowType $name -Window $Bucket[$name]
            if ($null -ne $w) { $windows += ,$w }
        }
    }
    $meta = @{}
    if ($Bucket -is [hashtable]) {
        foreach ($k in @('limitName', 'planType', 'limitId')) {
            if ($Bucket.ContainsKey($k) -and $null -ne $Bucket[$k]) { $meta[$k] = $Bucket[$k] }
        }
    }
    return @{
        bucketId   = [string]$BucketId
        bucketName = $(if ($meta.ContainsKey('limitName')) { [string]$meta.limitName } else { $null })
        planType   = $(if ($meta.ContainsKey('planType')) { [string]$meta.planType } else { $null })
        windows    = $windows
        usable     = ($allUsable -and @($windows).Count -gt 0)
    }
}

function Get-FlattenedQuotaWindows {
    # Convenience view: every bucket window as one flat record. Derived data only.
    param($Buckets)
    $flat = @()
    foreach ($b in @($Buckets)) {
        foreach ($w in @($b.windows)) {
            $flat += ,@{
                name               = [string]$w.windowType
                bucketId           = [string]$b.bucketId
                minutes            = $w.windowDurationMins
                usedPercent        = $w.usedPercent
                resetsAt           = $w.resetsAt
                usable             = [bool]$w.usable
            }
        }
    }
    return ,$flat
}

function ConvertFrom-QuotaSnapshotResult {
    # Normalizes an app-server result object into a QuotaSnapshot.
    # SCHEMA_UNKNOWN only when the root is unrecognizable or nothing usable
    # (no usable window AND no known metadata) remains (audit plan §4.2).
    param($Result)
    $out = @{
        ok                   = $true
        sourceSchemaVersion  = $null
        accountPlanType      = $null
        buckets              = @()
        windows              = @()
        rateLimitReachedType = $null
        credits              = $null
        spendControlReached  = $null
        rawMetadata          = @{}
        schemaUnknown        = $false
        errorKind            = $null
        message              = $null
    }

    if ($Result -isnot [hashtable]) {
        $out.ok = $false; $out.schemaUnknown = $true; $out.errorKind = 'SCHEMA_UNKNOWN'
        $out.message = 'response result is not an object'
        return $out
    }


    $rl = $null
    if ($Result.ContainsKey('rateLimits')) { $rl = $Result.rateLimits }
    $byId = $null
    if ($Result.ContainsKey('rateLimitsByLimitId')) { $byId = $Result.rateLimitsByLimitId }
    $recognized = $false

    if ($byId -is [hashtable] -and @($byId.Keys).Count -gt 0) {
        $recognized = $true
        $out.sourceSchemaVersion = 'v2'
        foreach ($limitId in @($byId.Keys | Sort-Object)) {
            $b = $byId[$limitId]
            if ($b -is [hashtable]) { $out.buckets += ,(Get-QuotaSnapshotBucket -BucketId ([string]$limitId) -Bucket $b) }
        }
    }

    if ($rl -is [hashtable]) {
        $recognized = $true
        if (-not $out.sourceSchemaVersion) { $out.sourceSchemaVersion = 'v2' }
        # Known metadata, whitelisted (never parsed as windows).
        if ($rl.ContainsKey('planType') -and $null -ne $rl.planType) { $out.accountPlanType = [string]$rl.planType }
        elseif ($Result.ContainsKey('planType') -and $null -ne $Result.planType) { $out.accountPlanType = [string]$Result.planType }
        if (-not $out.rateLimitReachedType) { $out.rateLimitReachedType = Get-RateLimitReachedType $Result }
        if ($rl.ContainsKey('credits') -and $null -ne $rl.credits) { $out.credits = $rl.credits }
        elseif ($Result.ContainsKey('credits') -and $null -ne $Result.credits) { $out.credits = $Result.credits }
        if ($rl.ContainsKey('spendControlReached') -and $null -ne $rl.spendControlReached) { $out.spendControlReached = $rl.spendControlReached }
        elseif ($Result.ContainsKey('spendControlReached') -and $null -ne $Result.spendControlReached) { $out.spendControlReached = $Result.spendControlReached }

        if ($rl.ContainsKey('limitId') -or $rl.ContainsKey('primary') -or $rl.ContainsKey('secondary')) {
            # No rateLimitsByLimitId -> rateLimits itself is the single default bucket.
            if (-not ($byId -is [hashtable] -and @($byId.Keys).Count -gt 0)) {
                $bucketId = 'default'
                if ($rl.ContainsKey('limitId') -and $rl.limitId) { $bucketId = [string]$rl.limitId }
                $out.buckets += ,(Get-QuotaSnapshotBucket -BucketId $bucketId -Bucket $rl)
            }
        }

        # Unknown metadata preserved verbatim (primitives only), never parsed as windows.
        foreach ($k in @($rl.Keys)) {
            if ($script:CQK_RATELIMITS_META_KEYS -ccontains $k) { continue }
            $v = $rl[$k]
            if ($null -eq $v) { continue }
            if ($v -is [hashtable] -or $v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and $v -isnot [byte[]]) { continue }
            $out.rawMetadata[$k] = $v
        }
    }

    if (-not $recognized) {
        $out.ok = $false; $out.schemaUnknown = $true; $out.errorKind = 'SCHEMA_UNKNOWN'
        $out.windows = @(); $out.buckets = @()
        $out.message = 'no rateLimits-like structure recognized; failing closed'
        return $out
    }

    $hasUsableWindow = $false
    foreach ($b in @($out.buckets)) { foreach ($w in @($b.windows)) { if ($w.usable) { $hasUsableWindow = $true } } }
    $hasMetadata = ($null -ne $out.accountPlanType -or $null -ne $out.rateLimitReachedType -or
        $null -ne $out.credits -or $null -ne $out.spendControlReached -or @($out.rawMetadata.Keys).Count -gt 0)
    if (-not $hasUsableWindow -and -not $hasMetadata) {
        $out.ok = $false; $out.schemaUnknown = $true; $out.errorKind = 'SCHEMA_UNKNOWN'
        $out.windows = @(); $out.buckets = @()
        $out.message = 'structure recognized but no usable window or metadata; failing closed'
        return $out
    }

    $out.windows = Get-FlattenedQuotaWindows $out.buckets
    return $out
}

function ConvertFrom-RateLimitsResponse {
    # JSON-RPC response -> QuotaSnapshot. Error responses are classified here.
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
        return @{ ok = $false; buckets = @(); windows = @(); sourceSchemaVersion = $null; accountPlanType = $null;
                  rateLimitReachedType = $null; credits = $null; spendControlReached = $null; rawMetadata = @{};
                  schemaUnknown = $false; errorKind = $kind;
                  message = (Hide-SensitiveText "app-server error ($errCode): $errText") }
    }

    $result = $null
    if ($Response -is [hashtable] -and $Response.ContainsKey('result')) { $result = $Response.result }
    return ConvertFrom-QuotaSnapshotResult $result
}

function Invoke-CodexRateLimitsAttempt {
    # One read-only quota probe against the official app-server protocol with the
    # given child environment. Never retries; callers own the retry policy.
    # Returns @{ ok; windows; rateLimitReachedType; schemaUnknown; errorKind; message }
    param(
        [hashtable]$Config,
        [string]$CodexPath = '',
        [int]$TimeoutSeconds = 0,
        [hashtable]$Environment = @{}
    )
    $empty = { @{ ok = $false; buckets = @(); windows = @(); sourceSchemaVersion = $null; accountPlanType = $null;
                  rateLimitReachedType = $null; credits = $null; spendControlReached = $null; rawMetadata = @{};
                  schemaUnknown = $false; errorKind = $null; message = $null } }
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
        $session = Start-AppServerSession $startInfo -Environment $Environment
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

function Invoke-CodexRateLimitsRead {
    # Read-only quota probe with the no-endless-retry policy (CQK-020):
    #   no proxy configured -> exactly one attempt, no retry within the cycle
    #   proxy configured    -> one attempt through the proxy; if it fails (any
    #                          error kind) one fallback attempt WITHOUT the
    #                          proxy, then stop. Never retries a third time.
    # Returns @{ ok; ...; proxy = 'off'|'used'|'fallback'; attempts = 1|2 }
    param(
        [hashtable]$Config,
        [string]$CodexPath = '',
        [int]$TimeoutSeconds = 0
    )
    $envMap = Get-CodexProxyEnvironment $Config
    $out = Invoke-CodexRateLimitsAttempt -Config $Config -CodexPath $CodexPath `
        -TimeoutSeconds $TimeoutSeconds -Environment $envMap
    if (@($envMap.Keys).Count -eq 0) {
        $out.proxy = 'off'
        $out.attempts = 1
        return $out
    }
    if ($out.ok) {
        $out.proxy = 'used'
        $out.attempts = 1
        return $out
    }
    # Proxy path failed: exactly one fallback attempt without the keeper-set
    # proxy env vars. (System-level proxy vars, if any, stay inherited.)
    $direct = Invoke-CodexRateLimitsAttempt -Config $Config -CodexPath $CodexPath -TimeoutSeconds $TimeoutSeconds
    $direct.proxy = 'fallback'
    $direct.attempts = 2
    if ($direct.ok) { return $direct }
    $direct.message = "$($direct.message) (proxy attempt also failed: $($out.message))"
    return $direct
}
