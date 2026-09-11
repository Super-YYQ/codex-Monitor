# Codex Quota Keeper - shared `codex app-server` JSON-RPC client layer (CQK-037).
#
# One home for everything that is not quota-specific: process launch, pipe wiring,
# the initialize/initialized handshake, id-matched request/response reads, the hard
# timeout, proxy environment injection, error classification and teardown.
#
# Quota reads (quota-client.ps1) and Execution Profile reads (codex-profile.ps1)
# are both thin callers of Invoke-CodexAppServerSession below - design doc v3.0 §15
# is explicit that we must not end up with three copies of the client, because a
# fix to the timeout or the teardown otherwise only lands in one of them.
#
# Everything here is read-only against the official protocol. Never auth.json,
# never the ChatGPT web UI, and the child is a fresh process per capability so
# nothing stays resident between polls.

$script:CqkAppServerClientDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkAppServerClientDir 'common.ps1')
}

# JSON-RPC request ids. The handshake is id 1 and the first method call id 7 -
# the values the protocol trace and the existing mock fixtures were built
# against, kept stable so a wire capture from before and after the extraction
# still line up. Later calls in the same session take 8, 9, ...
$script:CQK_APPSERVER_HANDSHAKE_ID = 1
$script:CQK_APPSERVER_FIRST_REQUEST_ID = 7

# model/list pagination limits (doc v3.0 §15.1: strict page AND item caps).
# A real catalog is a handful of entries; the caps exist so a server that keeps
# handing back a cursor can never turn into an unbounded loop.
$script:CQK_MODEL_LIST_PAGE_SIZE = 50
$script:CQK_MODEL_LIST_MAX_PAGES = 6
$script:CQK_MODEL_LIST_MAX_ITEMS = 300
# Hidden entries are requested too. `model/list` omits them by default (verified
# live: 5 visible vs 7 with includeHidden), and an incomplete catalog is exactly
# what turns a working `codex.autoAnchor.model` into a false INVALID - which
# blocks an armed AutoAnchor. Asymmetric cost: a wider catalog can only ever
# make validation more permissive, a narrow one can wrongly refuse to run.
$script:CQK_MODEL_LIST_INCLUDE_HIDDEN = $true

function Get-CodexAppServerErrorKind {
    # Single classifier that turns a JSON-RPC error object into the operational
    # kind upper layers act on. Callers must not re-derive this from message
    # text (doc v3.0 §12 / CQK-043 keeps the taxonomy in one place).
    #
    # Today it distinguishes AUTH_ERROR from everything else, which is exactly
    # what the quota path has always done; CQK-043 extends the set here rather
    # than adding a second regex pile in runner.ps1 / install.ps1.
    param([string]$Code, [string]$Message)
    $combined = "$Code $Message"
    if ($combined -match '(?i)auth|login|unauthor|401|403|not\s+logged') { return 'AUTH_ERROR' }
    return 'PROTOCOL_ERROR'
}

function Get-CodexServerStartInfo {
    # Launches any codex shape (native exe, npm codex.cmd, or a mock .ps1) through
    # the unified launcher (CQK-004).
    param([string]$CodexPath)
    return (Resolve-ExecutableLaunchSpec -Executable $CodexPath -ArgumentList @('app-server'))
}

function Start-CodexAppServerSession {
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
        nextId         = $script:CQK_APPSERVER_FIRST_REQUEST_ID
    }
}

function Stop-CodexAppServerSession {
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
    # The server interleaves unsolicited notifications (observed live:
    # remoteControl/status/changed), so "read the next line" is never correct -
    # match by id and keep going. Honors a hard deadline.
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

function Initialize-CodexAppServer {
    # initialize -> initialized handshake. Every capability needs it, so it is not
    # repeated per caller. Returns @{ ok; errorKind; message }.
    param($Session, [int]$TimeoutSeconds = 20)
    Send-AppServerMessage -Session $Session -Message @{
        jsonrpc = '2.0'; id = $script:CQK_APPSERVER_HANDSHAKE_ID; method = 'initialize'
        params  = @{ clientInfo = @{ name = 'codex-quota-keeper'; title = 'Codex Quota Keeper'; version = $script:CQK_VERSION } }
    }
    $handshake = Wait-AppServerResponse $Session -Id $script:CQK_APPSERVER_HANDSHAKE_ID -TimeoutSeconds $TimeoutSeconds
    if (-not $handshake.ok) {
        return @{ ok = $false; errorKind = $handshake.kind; message = (Hide-SensitiveText $handshake.message) }
    }
    Send-AppServerMessage -Session $Session -Message @{ jsonrpc = '2.0'; method = 'initialized' }
    return @{ ok = $true; errorKind = $null; message = $null }
}

function Invoke-CodexAppServerRequest {
    # One request/response round trip inside a live, initialized session.
    # Never retries, never reuses an id, and never decides what an error *means*
    # beyond the shared classifier - retry policy and semantics belong to callers.
    # Returns @{ ok; response; errorKind; message }.
    param(
        $Session,
        [string]$Method,
        $Params = @{},
        [int]$TimeoutSeconds = 20
    )
    $id = [int]$Session.nextId
    $Session.nextId = $id + 1
    Send-AppServerMessage -Session $Session -Message @{
        jsonrpc = '2.0'; id = $id; method = $Method; params = $Params
    }
    $reply = Wait-AppServerResponse $Session -Id $id -TimeoutSeconds $TimeoutSeconds
    if (-not $reply.ok) {
        return @{ ok = $false; response = $null; errorKind = $reply.kind; message = (Hide-SensitiveText $reply.message) }
    }
    $resp = $reply.response
    if ($resp -is [hashtable] -and $resp.ContainsKey('error') -and $resp.error) {
        $errText = ''
        $errCode = ''
        if ($resp.error -is [hashtable]) {
            $errText = [string]$resp.error.message
            $errCode = [string]$resp.error.code
        } else {
            $errText = "$($resp.error)"
        }
        return @{
            ok        = $false
            response  = $resp
            errorKind = (Get-CodexAppServerErrorKind -Code $errCode -Message $errText)
            message   = (Hide-SensitiveText "app-server error ($errCode): $errText")
        }
    }
    return @{ ok = $true; response = $resp; errorKind = $null; message = $null }
}

function Invoke-CodexAppServerSession {
    # Start codex app-server, handshake, run $Body against the live session, and
    # ALWAYS tear the child down. The single place that owns the launch-failure
    # kinds and the process lifetime, so no capability can forget to kill.
    #
    # $Body receives the session object and returns whatever the caller wants;
    # its value is passed straight through. On launch/handshake failure $Body is
    # never called and this returns @{ ok=$false; errorKind; message }.
    #
    # -Environment $null means "use the same proxy environment the quota read
    # uses" - which is exactly the doc v3.0 §6.2 requirement that the Profile be
    # resolved in the same Codex environment the real `codex exec` will run in.
    #
    # $Options is an opaque caller-defined hashtable handed to $Body as its third
    # argument, for the same reason $Session and $Timeout are arguments: a body
    # cannot reach its definition site's locals.
    param(
        [hashtable]$Config,
        [string]$CodexPath = '',
        [int]$TimeoutSeconds = 0,
        $Environment = $null,
        $Options = $null,
        [scriptblock]$Body
    )
    # $Body is invoked here, and PowerShell scoping is dynamic - a scriptblock
    # passed as a callback does NOT see the definition site's locals. So anything
    # the body needs arrives as an explicit argument.
    $timeout = 0
    if (-not $TimeoutSeconds -or $TimeoutSeconds -le 0) { $timeout = [int]$Config.codex.queryTimeoutSeconds }
    else { $timeout = [int]$TimeoutSeconds }
    if ($timeout -le 0) { $timeout = 20 }
    if ($null -eq $Environment) { $Environment = Get-CodexProxyEnvironment $Config }
    if (-not $CodexPath) { $CodexPath = Resolve-CodexCommand $Config }
    if (-not $CodexPath) {
        return @{ ok = $false; errorKind = 'SETUP_ERR'; message = 'codex executable not found (set codex.command in config.json)' }
    }
    $startInfo = Get-CodexServerStartInfo $CodexPath
    if (-not $startInfo) {
        return @{ ok = $false; errorKind = 'SETUP_ERR'; message = 'no PowerShell available to run the configured codex command' }
    }

    $session = $null
    try {
        $session = Start-CodexAppServerSession $startInfo -Environment $Environment
        if ($session.proc.HasExited) {
            return @{ ok = $false; errorKind = 'SETUP_ERR'; message = 'app-server process exited immediately' }
        }
        $handshake = Initialize-CodexAppServer -Session $session -TimeoutSeconds $timeout
        if (-not $handshake.ok) {
            return @{ ok = $false; errorKind = $handshake.errorKind; message = $handshake.message }
        }
        return & $Body $session $timeout $Options
    } catch {
        return @{
            ok        = $false
            errorKind = 'PROTOCOL_ERROR'
            message   = (Hide-SensitiveText "app-server client failure: $($_.Exception.Message)")
        }
    } finally {
        Stop-CodexAppServerSession $session
    }
}

function Get-CodexAppServerConfigValue {
    # §23 privacy allowlist. `config/read` answers with a very large object that
    # carries local absolute paths, notification hook executables, pinned binary
    # hashes, permissions and free-form instructions. Only these three keys ever
    # leave this function, and only as plain strings.
    param($ConfigResult)
    $out = @{ model = $null; modelReasoningEffort = $null; modelProvider = $null }
    if ($ConfigResult -isnot [hashtable]) { return $out }
    $cfg = $ConfigResult
    if ($ConfigResult.ContainsKey('config') -and $ConfigResult.config -is [hashtable]) { $cfg = $ConfigResult.config }
    foreach ($pair in @(@('model', 'model'), @('model_reasoning_effort', 'modelReasoningEffort'), @('model_provider', 'modelProvider'))) {
        $key = [string]$pair[0]
        $name = [string]$pair[1]
        if (-not $cfg.ContainsKey($key)) { continue }
        $v = $cfg[$key]
        if ($null -eq $v) { continue }
        $out[$name] = [string]$v
    }
    return $out
}

function Invoke-CodexConfigRead {
    # Reads the *effective* Codex configuration for this environment (config.toml
    # + CLI defaults + account overrides, as the CLI itself resolves it).
    # Returns @{ ok; model; modelReasoningEffort; modelProvider; errorKind; message }.
    # The raw config object is deliberately not returned at all.
    param(
        [hashtable]$Config,
        [string]$CodexPath = '',
        [int]$TimeoutSeconds = 0,
        $Environment = $null
    )
    $res = Invoke-CodexAppServerSession -Config $Config -CodexPath $CodexPath `
        -TimeoutSeconds $TimeoutSeconds -Environment $Environment -Body {
        param($Session, $Timeout)
        return Invoke-CodexAppServerRequest -Session $Session -Method 'config/read' -Params @{} -TimeoutSeconds $Timeout
    }
    if (-not $res.ok) {
        return @{ ok = $false; model = $null; modelReasoningEffort = $null; modelProvider = $null;
                  errorKind = $res.errorKind; message = $res.message }
    }
    $result = $null
    if ($res.response -is [hashtable] -and $res.response.ContainsKey('result')) { $result = $res.response.result }
    if ($result -isnot [hashtable]) {
        return @{ ok = $false; model = $null; modelReasoningEffort = $null; modelProvider = $null;
                  errorKind = 'SCHEMA_UNKNOWN'; message = 'config/read returned no config object; failing closed' }
    }
    $values = Get-CodexAppServerConfigValue $result
    return @{
        ok                   = $true
        model                = $values.model
        modelReasoningEffort = $values.modelReasoningEffort
        modelProvider        = $values.modelProvider
        errorKind            = $null
        message              = $null
    }
}

function Get-CodexModelListEntry {
    # Project one catalog entry down to the fields validation needs. The server's
    # `supportedReasoningEfforts` is an ARRAY OF OBJECTS ({reasoningEffort,
    # description}), not a list of strings - verified against the live CLI - so it
    # is projected here once, and a plain-string array is still accepted.
    # Nothing else (descriptions, upgrade hints, modalities, tiers) is carried.
    param($Item)
    if ($Item -isnot [hashtable]) { return $null }
    $efforts = @()
    if ($Item.ContainsKey('supportedReasoningEfforts')) {
        foreach ($e in @($Item.supportedReasoningEfforts)) {
            if ($null -eq $e) { continue }
            if ($e -is [hashtable]) {
                if ($e.ContainsKey('reasoningEffort') -and $null -ne $e.reasoningEffort) { $efforts += [string]$e.reasoningEffort }
            } else {
                $efforts += [string]$e
            }
        }
    }
    $model = if ($Item.ContainsKey('model') -and $null -ne $Item.model) { [string]$Item.model } else { $null }
    $id = if ($Item.ContainsKey('id') -and $null -ne $Item.id) { [string]$Item.id } else { $null }
    if (-not $model) { $model = $id }
    if (-not $model) { return $null }
    return @{
        model                     = $model
        id                        = $id
        hidden                    = [bool]($Item.ContainsKey('hidden') -and $Item.hidden -eq $true)
        isDefault                 = [bool]($Item.ContainsKey('isDefault') -and $Item.isDefault -eq $true)
        defaultReasoningEffort    = $(if ($Item.ContainsKey('defaultReasoningEffort') -and $null -ne $Item.defaultReasoningEffort) { [string]$Item.defaultReasoningEffort } else { $null })
        supportedReasoningEfforts = $efforts
    }
}

function Invoke-CodexModelList {
    # Fetches the model catalog THIS Codex CLI + account + provider actually
    # serves. There is no static model list in this repository on purpose: the
    # only authority is what the local CLI reports (doc v3.0 §5 设计原则).
    #
    # Pagination is mandatory. `model/list` returns {data, nextCursor} and a
    # caller that stops after the first page can declare a model invalid merely
    # because it lives on page 2 - the failure mode §5.2 L2 explicitly forbids.
    # A cursor the server rejects is a hard error, never "no more pages" (the
    # live server answers -32600 "invalid cursor"), and hitting the page/item cap
    # fails closed instead of returning a confident partial answer.
    #
    # Returns @{ ok; models; defaultModel; pages; errorKind; message }.
    # -IncludeHidden defaults on, so a model that exists but is hidden is never
    # reported as invalid; the flag exists because a caller may want the strictly
    # advertised catalog instead.
    param(
        [hashtable]$Config,
        [string]$CodexPath = '',
        [int]$TimeoutSeconds = 0,
        $Environment = $null,
        [bool]$IncludeHidden = $script:CQK_MODEL_LIST_INCLUDE_HIDDEN
    )
    $res = Invoke-CodexAppServerSession -Config $Config -CodexPath $CodexPath `
        -TimeoutSeconds $TimeoutSeconds -Environment $Environment -Body {
        param($Session, $Timeout, $Options)
        # $IncludeHidden is the caller's parameter two frames up. PowerShell's
        # scoping is dynamic, so a callback body does see it - but only because
        # Invoke-CodexModelList is the function that passed this block. Keeping
        # the read loop's tunables as script constants and the caller's choice as
        # a named parameter is deliberate: the two are different in kind (a
        # hard ceiling vs a per-call decision), and the test suite pins both.
        $models = @()
        $seen = @{}
        $cursor = $null
        $pages = 0
        while ($true) {
            $params = @{ limit = $script:CQK_MODEL_LIST_PAGE_SIZE; includeHidden = $IncludeHidden }
            if ($null -ne $cursor) { $params['cursor'] = $cursor }
            $reply = Invoke-CodexAppServerRequest -Session $Session -Method 'model/list' -Params $params -TimeoutSeconds $Timeout
            if (-not $reply.ok) {
                return @{ ok = $false; models = @(); defaultModel = $null; pages = $pages;
                          errorKind = $reply.errorKind; message = $reply.message }
            }
            $pages++
            $result = $null
            if ($reply.response -is [hashtable] -and $reply.response.ContainsKey('result')) { $result = $reply.response.result }
            if ($result -isnot [hashtable] -or -not $result.ContainsKey('data')) {
                return @{ ok = $false; models = @(); defaultModel = $null; pages = $pages;
                          errorKind = 'SCHEMA_UNKNOWN'; message = 'model/list returned no data array; failing closed' }
            }
            $data = $result.data
            if ($data -is [string] -or $data -isnot [System.Collections.IEnumerable]) {
                return @{ ok = $false; models = @(); defaultModel = $null; pages = $pages;
                          errorKind = 'SCHEMA_UNKNOWN'; message = 'model/list data is not a list; failing closed' }
            }
            foreach ($item in @($data)) {
                $entry = Get-CodexModelListEntry $item
                if ($null -eq $entry) { continue }
                $key = $entry.model.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $models += ,$entry
            }
            if (@($models).Count -gt $script:CQK_MODEL_LIST_MAX_ITEMS) {
                return @{ ok = $false; models = @(); defaultModel = $null; pages = $pages;
                          errorKind = 'SCHEMA_UNKNOWN'
                          message = ("model/list exceeded {0} entries; the catalog was not fully read, so a missing model cannot be treated as invalid - failing closed" -f $script:CQK_MODEL_LIST_MAX_ITEMS) }
            }
            $next = $null
            if ($result.ContainsKey('nextCursor')) { $next = $result.nextCursor }
            if ($null -eq $next -or "$next" -eq '') { break }
            if ($pages -ge $script:CQK_MODEL_LIST_MAX_PAGES) {
                return @{ ok = $false; models = @(); defaultModel = $null; pages = $pages;
                          errorKind = 'SCHEMA_UNKNOWN'
                          message = ("model/list still had a cursor after {0} pages; the catalog was not fully read, so a missing model cannot be treated as invalid - failing closed" -f $script:CQK_MODEL_LIST_MAX_PAGES) }
            }
            $cursor = $next
        }
        $default = $null
        foreach ($m in @($models)) {
            if ($m.isDefault) { $default = $m.model; break }
        }
        if (@($models).Count -eq 0) {
            # A logged-in Codex CLI with no models at all is not a real state; an
            # "empty catalog" answer is far more likely to be a server/proxy that
            # gave us nothing. Returning it as a success would make every model
            # look invalid and refuse an armed AutoAnchor, so fail closed instead.
            return @{ ok = $false; models = @(); defaultModel = $null; pages = $pages;
                      errorKind = 'SCHEMA_UNKNOWN'
                      message = 'model/list answered with an empty catalog; refusing to treat it as "no model is valid"' }
        }
        return @{ ok = $true; models = @($models); defaultModel = $default; pages = $pages;
                  errorKind = $null; message = $null }
    }
    if ($res -is [hashtable] -and $res.ContainsKey('models')) { return $res }
    # Launch / handshake failure path: no catalog at all.
    return @{ ok = $false; models = @(); defaultModel = $null; pages = 0;
              errorKind = $res.errorKind; message = $res.message }
}
