# Tests for app-server-client.ps1 (CQK-037): the shared JSON-RPC session layer.
#
# Two halves:
#   - Pure projection tests (no process spawn) for the two shapes that decide
#     whether a model validates: the §23 config/read allowlist and the model/list
#     entry projection.
#   - End-to-end tests against the mock app-server for the paths that were only
#     ever assumptions before: pagination (T05), the page/item caps, timeout
#     bounds, error classification, hidden-entry handling, and the guarantee that
#     a private config blob never leaves the client.
# The mock speaks the wire shapes captured from the live CLI 0.153.4
# (docs/findings.md): object-array reasoning efforts, opaque cursors, hidden
# entries, and a hard -32600 on a bad cursor.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'app-server-client.ps1')

$mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'

function New-MockCapConfig {
    param([int]$TimeoutSeconds = 10)
    return New-TestConfig @{ codex = @{ command = $mockPath; queryTimeoutSeconds = $TimeoutSeconds; autoAnchor = $false } }
}

function Invoke-MockConfigRead {
    param([string]$Mode, [int]$TimeoutSeconds = 10)
    $env:CQK_MOCK_MODE = $Mode
    try { return Invoke-CodexConfigRead -Config (New-MockCapConfig $TimeoutSeconds) }
    finally { Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue }
}

function Invoke-MockModelList {
    param([string]$Mode, [int]$TimeoutSeconds = 10, [bool]$IncludeHidden = $script:CQK_MODEL_LIST_INCLUDE_HIDDEN)
    $env:CQK_MOCK_MODE = $Mode
    try { return Invoke-CodexModelList -Config (New-MockCapConfig $TimeoutSeconds) -IncludeHidden $IncludeHidden }
    finally { Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue }
}

function Find-ModelEntry {
    param($Models, [string]$Name)
    foreach ($m in @($Models)) { if ($m.model -eq $Name) { return $m } }
    return $null
}

function Test-ModelNamed {
    param($Models, [string]$Name)
    foreach ($m in @($Models)) { if ("$($m.model)" -eq $Name) { return $true } }
    return $false
}

# ---------------------------------------------------------------------------
# Pure projection: §23 config/read allowlist

Start-TestGroup 'profile: config/read allowlist keeps only the three known keys'

$noisy = @{
    config = @{
        model                          = 'mock-model-beta'
        model_reasoning_effort         = 'high'
        model_provider                 = 'mock-provider'
        notify                         = @('C:\private\hook.exe')
        instructions                   = 'free-form private text'
        shell_environment_policy       = @{ set = @{ MOCK_SHA256S = 'deadbeef' } }
        'desktop.enabled-reasoning-efforts' = @('low', 'medium')
        cwd                            = 'C:\private\path'
        permissions                    = @{ 'filesystem' = 'restricted' }
    }
}
$vals = Get-CodexAppServerConfigValue $noisy
Assert-Equal 'mock-model-beta' $vals.model 'model whitelisted'
Assert-Equal 'high' $vals.modelReasoningEffort 'model_reasoning_effort whitelisted (camelCase key)'
Assert-Equal 'mock-provider' $vals.modelProvider 'model_provider whitelisted'
Assert-Equal 3 @($vals.Keys).Count 'exactly three keys, no extras added'

# The whole point of the allowlist: nothing else may ride along, not even under a
# different name. Serialized form is what would land in a log or a history record.
# (Checked on the JSON text, so path separators are searched as their literal
# inner words - ConvertTo-Json doubles backslashes.)
$blob = ConvertTo-Json -InputObject $vals -Depth 10
foreach ($forbidden in @('hook.exe', 'private', 'deadbeef', 'free-form', 'permissions',
                         'SHA256', 'enabled-reasoning-efforts', 'notify', 'instructions', 'cwd')) {
    Assert-False ($blob -match [regex]::Escape($forbidden)) "allowlist output does not leak [$forbidden]"
}

Start-TestGroup 'profile: config/read tolerates nulls and a bare config object'

$bare = Get-CodexAppServerConfigValue @{ model = 'mock-model-alpha'; model_reasoning_effort = $null }
Assert-Equal 'mock-model-alpha' $bare.model 'bare result (no .config wrapper) still read'
Assert-Null $bare.modelReasoningEffort 'explicit null stays null, not "null"'
Assert-Null $bare.modelProvider 'absent key stays null'
Assert-Null (Get-CodexAppServerConfigValue 'not-an-object').model 'non-object result degrades to nulls'
Assert-Null (Get-CodexAppServerConfigValue $null).model 'null result degrades to nulls'

# ---------------------------------------------------------------------------
# Pure projection: model/list entry, incl. the object-array reasoning efforts

Start-TestGroup 'profile: model/list entry projection (real wire shape)'

$entry = Get-CodexModelListEntry @{
    model = 'mock-model-alpha'; id = 'mock-model-alpha'; hidden = $false; isDefault = $true
    defaultReasoningEffort = 'low'
    supportedReasoningEfforts = @(
        @{ reasoningEffort = 'low'; description = 'd' }
        @{ reasoningEffort = 'medium'; description = 'd' }
    )
    displayName = 'Mock Alpha'; description = 'should be dropped'; inputModalities = @('text')
    serviceTiers = @('default'); upgrade = 'mock-model-beta'; upgradeInfo = @{ x = 1 }
}
Assert-NotNull $entry 'entry projected'
Assert-Equal 6 @($entry.Keys).Count -Message 'projection keeps only model/id/hidden/isDefault/defaultReasoningEffort/supportedReasoningEfforts'
Assert-Contains $entry.supportedReasoningEfforts 'low' 'object-array effort projected to its reasoningEffort string'
Assert-Contains $entry.supportedReasoningEfforts 'medium' 'second effort projected'
foreach ($e in @($entry.supportedReasoningEfforts)) {
    Assert-True ($e -is [string]) 'every projected effort is a plain string, never the {reasoningEffort,description} object'
}
Assert-True $entry.isDefault 'isDefault parsed'
Assert-False $entry.hidden 'hidden parsed'
Assert-Equal 'low' $entry.defaultReasoningEffort 'defaultReasoningEffort parsed'
$entryBlob = ConvertTo-Json -InputObject $entry -Depth 10
foreach ($dropped in @('displayName', 'should be dropped', 'inputModalities', 'serviceTiers', 'upgradeInfo')) {
    Assert-False ($entryBlob -match [regex]::Escape($dropped)) "catalog noise [$dropped] not persisted"
}

$stringEfforts = Get-CodexModelListEntry @{ id = 'legacy-id-only'; supportedReasoningEfforts = @('low', 'high') }
Assert-Equal 'legacy-id-only' $stringEfforts.model 'model falls back to id'
Assert-Contains $stringEfforts.supportedReasoningEfforts 'high' 'plain string array still accepted'
Assert-Null (Get-CodexModelListEntry @{ displayName = 'no model, no id' }) 'entry with neither model nor id rejected'
Assert-Null (Get-CodexModelListEntry 'not-an-object') 'non-object item rejected'

# ---------------------------------------------------------------------------
# Error classifier (CQK-043 extension point): auth is separated from the rest

Start-TestGroup 'client: error classification'

Assert-Equal 'AUTH_ERROR' (Get-CodexAppServerErrorKind -Code '-32000' -Message 'not authenticated: please run codex login') 'authentication -> AUTH_ERROR'
Assert-Equal 'AUTH_ERROR' (Get-CodexAppServerErrorKind -Code '' -Message 'Unauthorized access') 'unauthorized -> AUTH_ERROR'
Assert-Equal 'AUTH_ERROR' (Get-CodexAppServerErrorKind -Code '403' -Message 'forbidden') '403 code -> AUTH_ERROR'
Assert-Equal 'PROTOCOL_ERROR' (Get-CodexAppServerErrorKind -Code '-32601' -Message 'method not found') 'unknown method -> PROTOCOL_ERROR'
Assert-Equal 'PROTOCOL_ERROR' (Get-CodexAppServerErrorKind -Code '-32600' -Message 'invalid cursor: abc') 'bad cursor -> PROTOCOL_ERROR'
Assert-Equal 'NETWORK_ERROR' (Get-CodexAppServerErrorKind -Code '' -Message 'DNS lookup failed') 'standalone DNS term -> NETWORK_ERROR'
Assert-Equal 'NETWORK_ERROR' (Get-CodexAppServerErrorKind -Code '' -Message 'TLS handshake failed') 'standalone TLS term -> NETWORK_ERROR'
Assert-Equal 'PROTOCOL_ERROR' (Get-CodexAppServerErrorKind -Code '' -Message 'failed under C:\work\subtls-cache') 'tls substring is not a network error'
Assert-Equal 'PROTOCOL_ERROR' (Get-CodexAppServerErrorKind -Code '' -Message 'failed under C:\work\dnsrecords') 'dns substring is not a network error'

# ---------------------------------------------------------------------------
# End-to-end: config/read through the real session layer

Start-TestGroup 'e2e: config/read answers with only whitelisted values'

# Mode '' -> the mock falls back to its default 'normal' mode, which for these two
# methods is the "healthy CLI" fixture: a config blob with the three known keys
# buried in private noise, plus a full catalog.
$cfgOk = Invoke-MockConfigRead -Mode ''
Assert-True $cfgOk.ok 'config/read ok'
Assert-Equal 'mock-model-beta' $cfgOk.model 'effective model read'
Assert-Equal 'high' $cfgOk.modelReasoningEffort 'effective reasoning effort read'
Assert-Equal 'mock-provider' $cfgOk.modelProvider 'effective provider read'
Assert-Null $cfgOk.errorKind 'no error kind on success'
$cfgBlob = ConvertTo-Json -InputObject $cfgOk -Depth 10
foreach ($forbidden in @('hook.exe', 'C:\mock', 'deadbeef', 'MOCK_SHA256S', 'mock free-form', 'cwd', 'notify', 'enabled-reasoning-efforts')) {
    Assert-False ($cfgBlob -match [regex]::Escape($forbidden)) "e2e config/read result does not carry [$forbidden]"
}

$cfgEmpty = Invoke-MockConfigRead -Mode 'config-empty'
Assert-True $cfgEmpty.ok 'config-empty is still a valid answer (nothing configured)'
Assert-Null $cfgEmpty.model 'absent model -> null so the catalog default can win'
Assert-Null $cfgEmpty.modelReasoningEffort 'absent effort -> null'
Assert-Null $cfgEmpty.modelProvider 'null provider stays null'

$cfgErr = Invoke-MockConfigRead -Mode 'config-error'
Assert-False $cfgErr.ok 'config/read error surfaces as failure'
Assert-Equal 'AUTH_ERROR' $cfgErr.errorKind 'config/read auth error classified'
Assert-Null $cfgErr.model 'failed read returns no values'

# ---------------------------------------------------------------------------
# End-to-end: model/list, incl. pagination (T05) and the caps

Start-TestGroup 'e2e: model/list single page'

$cat = Invoke-MockModelList -Mode ''
Assert-True $cat.ok 'catalog fetched'
Assert-Equal 1 $cat.pages 'one page when the server has no cursor'
Assert-Equal 7 @($cat.models).Count 'all entries, hidden included (5 visible + retired + ...)'
Assert-Equal 'mock-model-alpha' $cat.defaultModel 'isDefault entry becomes the catalog default'
$alpha = Find-ModelEntry $cat.models 'mock-model-alpha'
Assert-NotNull $alpha 'alpha found'
Assert-Contains $alpha.supportedReasoningEfforts 'high' 'alpha supports high'
Assert-False ($alpha.supportedReasoningEfforts -contains 'xhigh') 'alpha does not support xhigh (per-model lists differ, so L3 is a real check)'
$delta = Find-ModelEntry $cat.models 'mock-model-delta'
Assert-Equal 1 @($delta.supportedReasoningEfforts).Count 'delta supports exactly one effort'
Assert-Contains $delta.supportedReasoningEfforts 'high' 'delta high'
$retired = Find-ModelEntry $cat.models 'mock-model-retired'
Assert-NotNull $retired 'hidden entry present because the client asks for hidden entries'
Assert-True $retired.hidden 'hidden flag carried so no caller can mistake it for advertised'

Start-TestGroup 'e2e (T05): model/list pagination - a page-2 model must not look invalid'

$paged = Invoke-MockModelList -Mode 'catalog-paged'
Assert-True $paged.ok 'paged catalog fetched'
Assert-Equal 4 $paged.pages 'server served 2 per page: 4 pages for 7 entries'
Assert-Equal 7 @($paged.models).Count 'every page collected'
$zeta = Find-ModelEntry $paged.models 'mock-model-zeta'
Assert-NotNull $zeta 'the last-page model was found (a first-page-only client would report it missing)'
Assert-True (Test-ModelNamed $paged.models 'mock-model-alpha') 'first-page model still present after paging'
Assert-Equal 'mock-model-alpha' $paged.defaultModel 'default model found across pages'
# The point of the assertion: validating page 2's model must NOT fail.
Assert-NotNull $zeta 'cross-page hit is a hit, not INVALID'

Start-TestGroup 'e2e: model/list caps fail closed instead of returning a partial catalog'

$cap = Invoke-MockModelList -Mode 'catalog-cap'
Assert-False $cap.ok 'runaway cursor is a failure'
Assert-Equal 'SCHEMA_UNKNOWN' $cap.errorKind 'cap reported as schema/unknown, not as "model missing"'
Assert-Equal $script:CQK_MODEL_LIST_MAX_PAGES $cap.pages 'stopped exactly at the page cap'
Assert-True ($cap.message -match 'failing closed') 'message says it failed closed'
Assert-True ($cap.message -match 'not fully read') 'message explains a missing model cannot be trusted'
Assert-Equal 0 @($cap.models).Count 'a partial catalog is not handed to the caller'

$bad = Invoke-MockModelList -Mode 'catalog-badschema'
Assert-False $bad.ok 'non-list data is a failure'
Assert-Equal 'SCHEMA_UNKNOWN' $bad.errorKind 'bad schema classified'

$cerr = Invoke-MockModelList -Mode 'catalog-error'
Assert-False $cerr.ok 'catalog error surfaces'
Assert-Equal 'AUTH_ERROR' $cerr.errorKind 'catalog auth error classified'

Start-TestGroup 'e2e: hidden-only catalog - includeHidden decides, empty fails closed'

$hidOn = Invoke-MockModelList -Mode 'catalog-hidden'
Assert-True $hidOn.ok 'default request sees hidden entries, so the catalog is not empty'
Assert-Equal 1 @($hidOn.models).Count 'only the hidden entry exists here'
Assert-True (Test-ModelNamed $hidOn.models 'mock-model-retired') 'hidden entry returned'

$hidOff = Invoke-MockModelList -Mode 'catalog-hidden' -IncludeHidden $false
Assert-False $hidOff.ok 'a visible-only request gets an empty catalog'
Assert-Equal 'SCHEMA_UNKNOWN' $hidOff.errorKind 'empty catalog fails closed rather than "nothing is valid"'
Assert-True ($hidOff.message -match 'empty catalog') 'message names the empty catalog'

Start-TestGroup 'e2e: timeouts and setup failures are bounded'

$t0 = [DateTime]::UtcNow
$to = Invoke-MockModelList -Mode 'catalog-timeout' -TimeoutSeconds 2
$elapsed = ([DateTime]::UtcNow - $t0).TotalSeconds
Assert-False $to.ok 'never-answering catalog fails'
Assert-Equal 'TIMEOUT' $to.errorKind 'timeout kind'
Assert-True ($elapsed -lt 15) "bounded by the query timeout (took $([int]$elapsed)s)"
Assert-True ($to.message -match 'timed out') 'timeout message'

$missing = Invoke-CodexModelList -Config (New-TestConfig @{ codex = @{ command = (Join-Path $env:TEMP ('no-such-codex-' + [guid]::NewGuid().ToString('N') + '.exe')) } })
Assert-False $missing.ok 'missing codex binary fails'
Assert-Equal 'SETUP_ERROR' $missing.errorKind 'SETUP_ERROR kind from the shared session layer'
Assert-Equal 0 @($missing.models).Count 'no catalog'
Assert-Equal 0 $missing.pages 'no pages attempted'

$missingCfg = Invoke-CodexConfigRead -Config (New-TestConfig @{ codex = @{ command = (Join-Path $env:TEMP ('no-such-codex-' + [guid]::NewGuid().ToString('N') + '.exe')) } })
Assert-False $missingCfg.ok 'missing codex binary fails config/read too'
Assert-Equal 'SETUP_ERROR' $missingCfg.errorKind 'same setup kind for both capabilities - one client, one rule'

Start-TestGroup 'privacy: no credential-looking text in any message'

foreach ($r in @($cfgErr, $cap, $bad, $cerr, $to, $missing)) {
    $m = "$($r.message)"
    Assert-False ($m -match 'sk-[A-Za-z0-9]{6,}') 'message carries no API-key-shaped text'
    Assert-False ($m -match '(?i)bearer\s+[A-Za-z0-9]') 'message carries no bearer token'
}

$result = Get-TestResult
Write-Host ""
Write-Host ("app-server-client: {0} checks, {1} failures" -f $result.checks, $result.failures)
if ($result.failures -gt 0) { exit 1 }
exit 0
