# Codex Quota Keeper - official app-server quota client.
# Speaks newline-delimited JSON-RPC to `codex app-server`:
#   initialize -> initialized -> account/rateLimits/read
# Never reads auth.json, never touches the ChatGPT web UI. Fresh process per read
# so nothing stays resident between polls.
#
# The transport itself (launch, pipes, handshake, id matching, timeout, proxy env,
# error classification, teardown) lives in app-server-client.ps1 - the single
# shared session layer the Execution Profile resolver uses too (doc v3.0 §15:
# one client, not three copies). This file is only the quota *schema* on top of it.

$script:CqkQuotaClientDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkQuotaClientDir 'common.ps1')
}
if (-not (Get-Command Invoke-CodexAppServerSession -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkQuotaClientDir 'app-server-client.ps1')
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
        return @{ ok = $false; buckets = @(); windows = @(); sourceSchemaVersion = $null; accountPlanType = $null;
                  rateLimitReachedType = $null; credits = $null; spendControlReached = $null; rawMetadata = @{};
                  schemaUnknown = $false; errorKind = (Get-CodexAppServerErrorKind -Code $errCode -Message $errText);
                  message = (Hide-SensitiveText "app-server error ($errCode): $errText") }
    }

    $result = $null
    if ($Response -is [hashtable] -and $Response.ContainsKey('result')) { $result = $Response.result }
    return ConvertFrom-QuotaSnapshotResult $result
}

function Invoke-CodexRateLimitsAttempt {
    # One read-only quota probe against the official app-server protocol with the
    # given child environment. Never retries; callers own the retry policy.
    # Transport, handshake, timeout and teardown all come from the shared session
    # layer; this function only maps the answer onto the QuotaSnapshot model.
    # Returns @{ ok; windows; rateLimitReachedType; schemaUnknown; errorKind; message }
    param(
        [hashtable]$Config,
        [string]$CodexPath = '',
        [int]$TimeoutSeconds = 0,
        [hashtable]$Environment = @{}
    )
    return (Invoke-CodexAppServerSession -Config $Config -CodexPath $CodexPath `
        -TimeoutSeconds $TimeoutSeconds -Environment $Environment -Body {
        param($Session, $Timeout)
        $reply = Invoke-CodexAppServerRequest -Session $Session -Method 'account/rateLimits/read' -Params @{} -TimeoutSeconds $Timeout
        if (-not $reply.ok) {
            # Launch/handshake failures and JSON-RPC error replies both surface as a
            # failed snapshot with the same empty-but-well-shaped fields the parser
            # emits, so no caller has to null-check a partial object.
            return @{ ok = $false; buckets = @(); windows = @(); sourceSchemaVersion = $null; accountPlanType = $null;
                      rateLimitReachedType = $null; credits = $null; spendControlReached = $null; rawMetadata = @{};
                      schemaUnknown = $false; errorKind = $reply.errorKind; message = $reply.message }
        }
        return ConvertFrom-RateLimitsResponse $reply.response
    })
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
    $out = Complete-CodexResult $out
    if (@($envMap.Keys).Count -eq 0) {
        $out.proxy = 'off'
        $out.attempts = 1
        return $out
    }
    if ($out.ok -or -not $out.retryable) {
        $out.proxy = 'used'
        $out.attempts = 1
        return $out
    }
    # Proxy path failed: exactly one fallback attempt without the keeper-set
    # proxy env vars. (System-level proxy vars, if any, stay inherited.)
    $direct = Invoke-CodexRateLimitsAttempt -Config $Config -CodexPath $CodexPath -TimeoutSeconds $TimeoutSeconds
    $direct = Complete-CodexResult $direct
    $direct.proxy = 'fallback'
    $direct.attempts = 2
    if ($direct.ok) { return $direct }
    $direct.message = "$($direct.message) (proxy attempt also failed: $($out.message))"
    return $direct
}
