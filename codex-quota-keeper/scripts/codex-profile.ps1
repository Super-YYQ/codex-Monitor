# Codex Quota Keeper - Execution Profile resolver (CQK-038, design doc v3.0 §6).
#
# Answers the one question an unattended AutoAnchor must not guess: which model
# and which reasoning effort would a `codex exec` started RIGHT NOW actually use,
# and does the Codex CLI installed on THIS machine still serve them?
#
#   codex.autoAnchor.model ─────────────┐
#   config/read.model ──────────────────┼─> effectiveModel ─> L2: present in the
#   model/list default entry ───────────┘                       live model catalog?
#
#   codex.autoAnchor.reasoningEffort ───┐
#   config/read.model_reasoning_effort ─┼─> effectiveReasoningEffort ─> L3: in the
#   target model defaultReasoningEffort ┘                                model's list?
#
# Two rules shape everything below:
#   * No static model whitelist lives in this repository (§5 设计原则). The only
#     authority is what the local CLI + account + provider report, read live.
#   * The profile is resolved in the SAME Codex environment `codex exec` runs in
#     (§6.2) - same binary, same proxy environment - and within ONE session, so a
#     proxy that would break the model call cannot be routed around silently
#     while "proving" that the model itself is fine.
#
# Read-only: this module never calls a model and never writes keeper state. What a
# VALID / INVALID / UNAVAILABLE profile MEANS is the caller's decision - §7 makes
# it an Install/Apply gate only when AutoAnchor is armed, §8 makes it a Runtime
# gate that must sit BEFORE the Claim.

$script:CqkCodexProfileDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkCodexProfileDir 'common.ps1')
}
if (-not (Get-Command Invoke-CodexAppServerSession -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkCodexProfileDir 'app-server-client.ps1')
}

function New-ExecutionProfile {
    # The §6.1 shape, constructed in exactly one place. Every field is present even
    # when unknown, so callers have a stable key set. Optional identity strings
    # use '' consistently across the config, live result and cache APIs.
    return @{
        configuredModel           = ''
        configuredReasoningEffort = ''
        effectiveModel            = ''
        effectiveReasoningEffort  = ''
        modelProvider             = ''
        modelSource               = $null
        reasoningEffortSource     = $null
        supportedReasoningEfforts = @()
        validation                = 'UNAVAILABLE'
        validationReason          = $null
        validatedAt               = (Get-IsoTimestamp)
        # Not part of §6.1 on purpose: §11 makes errorKind/retryable the contract
        # every upper layer reads instead of re-parsing message text. They describe
        # THIS resolution attempt, so they are never persisted (§23).
        errorKind                 = $null
        retryable                 = $false
    }
}

function Get-ExecutionProfileSelection {
    # §6.2 priority + §5.1 L2/L3 semantic checks. Pure: takes the two read results
    # and returns the decision, with no I/O and no process - so the priority rules
    # and the "retired vs never existed" distinction are testable on their own.
    #
    # Returns @{ effectiveModel; effectiveReasoningEffort; modelSource;
    #            reasoningEffortSource; supportedReasoningEfforts;
    #            validation; validationReason; errorKind }.
    # On failure the resolved-so-far values are still returned: the audit record
    # should show what WAS known when the profile was rejected.
    param($ConfigRead, $Catalog, [string]$ConfiguredModel = '', [string]$ConfiguredEffort = '')

    $out = @{
        effectiveModel            = ''
        effectiveReasoningEffort  = ''
        modelSource               = $null
        reasoningEffortSource     = $null
        supportedReasoningEfforts = @()
        validation                = 'INVALID'
        validationReason          = $null
        errorKind                 = 'PROFILE_INVALID'
    }

    $cfgModel = ''
    $cfgEffort = ''
    if ($ConfigRead -is [hashtable]) {
        if ($ConfigRead.model) { $cfgModel = [string]$ConfigRead.model }
        if ($ConfigRead.modelReasoningEffort) { $cfgEffort = [string]$ConfigRead.modelReasoningEffort }
    }

    # ---- model (§6.2): explicit > CLI's effective config > catalog default ----
    $model = ''
    $source = $null
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredModel)) {
        $model = $ConfiguredModel
        $source = 'explicit'
    } elseif ($cfgModel) {
        $model = $cfgModel
        $source = 'codex-config'
    } elseif ($Catalog -is [hashtable] -and $Catalog.defaultModel) {
        $model = [string]$Catalog.defaultModel
        $source = 'catalog-default'
    }
    $out.effectiveModel = $model
    $out.modelSource = $source
    if (-not $model) {
        $out.validationReason = 'no model could be resolved: codex.autoAnchor.model is empty, config/read reported none, and the model catalog flags no default entry'
        return $out
    }

    # ---- L2: the model must exist in what this CLI actually serves ------------
    $entries = @()
    if ($Catalog -is [hashtable] -and $Catalog.models) { $entries = @($Catalog.models) }
    $entry = $null
    foreach ($e in $entries) {
        if ("$($e.model)" -eq $model) { $entry = $e; break }
    }
    if ($null -eq $entry) {
        $out.validationReason = ("model '{0}' (source: {1}) is not in this Codex CLI's model catalog ({2} entries)" -f $model, $source, @($entries).Count)
        return $out
    }
    $out.supportedReasoningEfforts = @($entry.supportedReasoningEfforts)
    if ([bool]$entry.hidden) {
        # Distinguishing this from "not in the catalog" is the whole reason the
        # client asks for hidden entries: a model that was retired by a CLI upgrade
        # and a model that never existed are the same INVALID, but only one of them
        # is fixed by correcting a typo.
        $out.validationReason = ("model '{0}' (source: {1}) exists but is hidden/retired in this CLI's catalog and is not offered for execution" -f $model, $source)
        return $out
    }

    # ---- reasoning effort (§6.2): explicit > CLI's effective config > model default
    $effort = ''
    $effortSource = $null
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredEffort)) {
        $effort = $ConfiguredEffort
        $effortSource = 'explicit'
    } elseif ($cfgEffort) {
        $effort = $cfgEffort
        $effortSource = 'codex-config'
    } elseif ($entry.defaultReasoningEffort) {
        $effort = [string]$entry.defaultReasoningEffort
        $effortSource = 'model-default'
    }
    $out.effectiveReasoningEffort = $effort
    $out.reasoningEffortSource = $effortSource

    if ($effort) {
        $supported = @($entry.supportedReasoningEfforts)
        if ($supported.Count -eq 0) {
            # Nothing to compare against. Refusing here is the fail-closed reading
            # of §21 ("cannot prove the profile is valid"): a catalog entry that
            # omits its capabilities cannot prove anything about this effort.
            $out.validation = 'UNAVAILABLE'
            $out.errorKind = 'SCHEMA_UNKNOWN'
            $out.validationReason = ("cannot verify reasoning effort '{0}': the catalog entry for model '{1}' reports no supportedReasoningEfforts" -f $effort, $model)
            return $out
        }
        $found = $false
        foreach ($s in $supported) {
            if ("$s" -eq $effort) { $found = $true; break }
        }
        if (-not $found) {
            $out.validationReason = ("reasoning effort '{0}' (source: {1}) is not supported by model '{2}' (supported: {3})" -f $effort, $effortSource, $model, ($supported -join '/'))
            return $out
        }
    }

    $out.validation = 'VALID'
    $out.errorKind = $null
    $out.validationReason = $null
    return $out
}

function Resolve-ExecutionProfile {
    # Live resolution: one app-server session, config/read + the full paginated
    # model/list, then the §6.2/L2/L3 selection. Never throws; a read failure is a
    # Profile with validation=UNAVAILABLE plus the client's own errorKind/retryable,
    # so the caller's policy (retry next poll / block install) stays out of here.
    #
    # No proxy fallback, unlike the quota read: §6.2 requires the profile to be read
    # in the environment exec will use, and a direct attempt after a failed proxy
    # attempt would answer for a different environment.
    #
    # Returns the §6.1 Profile (§9 audits it, §14.1 caches a whitelist subset).
    # Named $prof, not $profile: $PROFILE is a PowerShell automatic variable, and
    # the -Profile parameter names below stay because they are public API.
    param(
        [hashtable]$Config,
        [string]$CodexPath = '',
        [int]$TimeoutSeconds = 0,
        [string]$WorkingDirectory = ''
    )
    $prof = New-ExecutionProfile
    $aa = Get-AutoAnchorConfig $Config
    if ($aa) {
        if ($aa.model) { $prof.configuredModel = [string]$aa.model }
        if ($aa.reasoningEffort) { $prof.configuredReasoningEffort = [string]$aa.reasoningEffort }
    }

    $res = Invoke-CodexAppServerSession -Config $Config -CodexPath $CodexPath `
        -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $WorkingDirectory -Body {
        param($Session, $Timeout)
        # Both reads share one session: one child process, one environment, one
        # answer to "what would exec use?".
        $cfgRead = Invoke-CodexConfigReadInSession -Session $Session -TimeoutSeconds $Timeout
        if (-not $cfgRead.ok) {
            return @{ ok = $false; configRead = $cfgRead; catalog = $null
                      errorKind = $cfgRead.errorKind; message = $cfgRead.message }
        }
        $catalog = Invoke-CodexModelListInSession -Session $Session -TimeoutSeconds $Timeout -IncludeHidden $true
        if (-not $catalog.ok) {
            return @{ ok = $false; configRead = $cfgRead; catalog = $catalog
                      errorKind = $catalog.errorKind; message = $catalog.message }
        }
        return @{ ok = $true; configRead = $cfgRead; catalog = $catalog; errorKind = $null; message = $null }
    }
    $prof.validatedAt = Get-IsoTimestamp

    if (-not $res.ok) {
        $kind = [string]$res.errorKind
        if (-not $kind) { $kind = 'PROFILE_UNAVAILABLE' }
        $prof.validation = 'UNAVAILABLE'
        $prof.validationReason = [string]$res.message
        $prof.errorKind = $kind
        $prof.retryable = Get-CodexErrorRetryable $kind
        return $prof
    }

    $sel = Get-ExecutionProfileSelection -ConfigRead $res.configRead -Catalog $res.catalog `
        -ConfiguredModel $prof.configuredModel -ConfiguredEffort $prof.configuredReasoningEffort
    $prof.effectiveModel = [string]$sel.effectiveModel
    $prof.effectiveReasoningEffort = [string]$sel.effectiveReasoningEffort
    $prof.modelSource = $sel.modelSource
    $prof.reasoningEffortSource = $sel.reasoningEffortSource
    $prof.supportedReasoningEfforts = @($sel.supportedReasoningEfforts)
    $prof.validation = [string]$sel.validation
    $prof.validationReason = $sel.validationReason
    $prof.errorKind = $sel.errorKind
    # PROFILE_INVALID is not retryable: the same catalog will say the same thing on
    # the next poll, so a caller must not treat it as a transient read failure.
    $prof.retryable = Get-CodexErrorRetryable ([string]$sel.errorKind)
    # Provider is informational only (environment consistency + status display,
    # §23). It never decides anything: a null provider is a normal answer.
    if ($res.configRead -is [hashtable] -and $res.configRead.modelProvider) {
        $prof.modelProvider = [string]$res.configRead.modelProvider
    }
    return $prof
}

function Get-ExecutionProfileExecArgs {
    # How a validated Profile turns into `codex exec` arguments: pass ONLY what
    # config.json explicitly configured, exactly as it was configured, and let the
    # CLI resolve the rest itself (§6.2 priority). Handing exec the
    # effectiveModel / effectiveReasoningEffort instead would create a second
    # source of truth for the call - and would silently defeat the runtime
    # revalidation this ticket is about: if the model was retired between the
    # profile read and the exec, exec must fail against the configured value the
    # audit shows, not succeed on a rewritten one.
    #
    # So the Profile's job is to PROVE the call is safe, never to rewrite it. The
    # two things are kept separate but equal by Get-ExecutionProfileSelection,
    # which resolves the configured value itself against L2/L3 (an explicit model
    # is checked as-is, not swapped for a default).
    #
    # Returns @{ model; reasoningEffort } - both '' when the Profile configures
    # nothing, which is a legitimate VALID answer meaning "use the CLI defaults".
    param($Profile)
    $configuredModel = ''
    $configuredEffort = ''
    if ($Profile -is [hashtable]) {
        if ($Profile.configuredModel) { $configuredModel = [string]$Profile.configuredModel }
        if ($Profile.configuredReasoningEffort) { $configuredEffort = [string]$Profile.configuredReasoningEffort }
    }
    return @{ model = $configuredModel; reasoningEffort = $configuredEffort }
}

function Get-ExecutionProfileCacheFields {
    # §14.1 + §23: the cache is a whitelist, not a Profile dump. Model, effort,
    # provider, the two sources, the verdict and when it was taken - nothing else.
    # In particular NOT the catalog, NOT supportedReasoningEfforts, NOT a token,
    # NOT any part of the raw config/read answer, and not configuredModel either
    # (that is read straight from config.json by whoever displays it).
    #
    # validationReason / errorKind are deliberately OUT even though the offline
    # panel would look better with them: §23 limits the cache to the fields it
    # names, and a reason string is text this repository does not control (an
    # app-server message can quote a path, an account label or a URL). A status
    # panel that wants the WHY has to go -Live, which is exactly the boundary the
    # doc draws between the safe cache and the live read.
    param($Profile)
    $out = @{
        effectiveModel           = ''
        effectiveReasoningEffort = ''
        modelProvider            = ''
        modelSource              = ''
        reasoningEffortSource    = ''
        validation               = ''
        validatedAt              = ''
    }
    if ($Profile -isnot [hashtable]) { return $out }
    foreach ($k in @($out.Keys)) {
        if ($Profile.ContainsKey($k) -and $null -ne $Profile[$k]) { $out[$k] = Hide-SensitiveText ([string]$Profile[$k]) }
    }
    return $out
}

function Write-ExecutionProfileCache {
    # Last safely-cached profile (runtime/execution-profile.json), so the default
    # status panel can show it without going online (§14.1). A write failure is
    # reported, never thrown: the cache is a convenience, and a full disk must not
    # turn a good VALID profile into a failed anchor.
    # Returns @{ ok; path; value; message }.
    param([string]$KeeperRoot, $Profile)
    $path = Get-ExecutionProfilePath $KeeperRoot
    $value = Get-ExecutionProfileCacheFields $Profile
    try {
        Write-JsonFileAtomic -Path $path -Value $value
        return @{ ok = $true; path = $path; value = $value; message = $null }
    } catch {
        return @{ ok = $false; path = $path; value = $value
                  message = (Hide-SensitiveText "could not write the execution profile cache: $($_.Exception.Message)") }
    }
}

function Read-ExecutionProfileCache {
    # Returns @{ ok; path; value; message }. ok=$false when nothing has been cached
    # yet (a normal first-run state) or when the file is unreadable - the caller
    # decides what "no cache" means for its display.
    param([string]$KeeperRoot)
    $path = Get-ExecutionProfilePath $KeeperRoot
    $raw = Read-JsonFile -Path $path
    if ($raw -isnot [hashtable]) {
        return @{ ok = $false; path = $path; value = $null; message = 'no cached execution profile' }
    }
    return @{ ok = $true; path = $path; value = (Get-ExecutionProfileCacheFields $raw); message = $null }
}
