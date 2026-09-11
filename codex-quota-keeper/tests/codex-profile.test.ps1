# Tests for codex-profile.ps1 (CQK-038): the Execution Profile resolver.
#
# Half pure, half end-to-end, for the same reason the client tests are:
#   - Get-ExecutionProfileSelection is I/O-free, so the §6.2 priority rules and the
#     L2/L3 verdicts (T02/T03/T04/T06) are pinned without spawning anything.
#   - The resolver itself runs against the mock app-server, which is the only way
#     to prove the properties that live in the session: config/read + model/list
#     over ONE child process, the paginated catalog reaching the verdict (T05),
#     bounded failure paths, and the §23 cache whitelist.
# No model name here is real (mock-model-*): this repository must not carry a model
# whitelist, fixtures included (doc v3.0 §22), and the shapes mirror what the live
# CLI 0.153.4 actually sends (docs/findings.md).

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'app-server-client.ps1')
. (Join-Path $scriptDir 'codex-profile.ps1')

$mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'

function New-ProfileConfig {
    param([string]$Model = '', [string]$Effort = '', [int]$TimeoutSeconds = 10, [string]$Proxy = '')
    return New-TestConfig @{ codex = @{ command = $mockPath; queryTimeoutSeconds = $TimeoutSeconds; proxy = $Proxy
        autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60
                        model = $Model; reasoningEffort = $Effort } } }
}

function Invoke-ProfileResolve {
    param([string]$Mode, [string]$Model = '', [string]$Effort = '', [int]$TimeoutSeconds = 10)
    $env:CQK_MOCK_MODE = $Mode
    try {
        return Resolve-ExecutionProfile -Config (New-ProfileConfig -Model $Model -Effort $Effort -TimeoutSeconds $TimeoutSeconds)
    } finally {
        Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
    }
}

# Synthetic read results for the pure tests: exactly the shape the client returns.
function New-MockConfigRead {
    param([string]$Model = '', [string]$Effort = '', [string]$Provider = '')
    return @{ ok = $true; model = $Model; modelReasoningEffort = $Effort; modelProvider = $Provider; errorKind = $null; message = $null }
}

function New-MockModelEntry {
    param([string]$Model, [string[]]$Efforts = @(), [string]$DefaultEffort = '', [bool]$Hidden = $false, [bool]$IsDefault = $false)
    return @{ model = $Model; id = $Model; hidden = $Hidden; isDefault = $IsDefault
              defaultReasoningEffort = $DefaultEffort; supportedReasoningEfforts = @($Efforts) }
}

function New-MockCatalog {
    param($Models, [string]$DefaultModel = '')
    return @{ ok = $true; models = @($Models); defaultModel = $DefaultModel; pages = 1; errorKind = $null; message = $null }
}

function New-SessionCounterPath {
    return (Join-Path $env:TEMP ('cqk-sessions-' + [guid]::NewGuid().ToString('N') + '.log'))
}

function Get-SessionCount {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-Content -LiteralPath $Path | Where-Object { $_ -match 'session' }).Count
}

# --- the synthetic catalog used by the pure groups --------------------------
$script:MockCatalog = @(
    (New-MockModelEntry -Model 'mock-model-alpha' -Efforts @('low', 'medium', 'high') -DefaultEffort 'low' -IsDefault $true),
    (New-MockModelEntry -Model 'mock-model-beta' -Efforts @('low', 'medium', 'high', 'xhigh') -DefaultEffort 'medium'),
    (New-MockModelEntry -Model 'mock-model-delta' -Efforts @('high') -DefaultEffort 'high'),
    (New-MockModelEntry -Model 'mock-model-retired' -Efforts @('low') -DefaultEffort 'low' -Hidden $true)
)

# ---------------------------------------------------------------------------
# T01 (layer boundary): shape stays L1's job, the resolver never re-checks it

Start-TestGroup 'profile: L1 shape stays with the config layer'

# The resolver works on values that already passed Test-ConfigShape; a value with a
# space never reaches it. Pinned here so the two layers cannot quietly swap jobs.
$shapeIssues = Test-ConfigShape (New-TestConfig @{ mode = 'AutoAnchor'
    codex = @{ command = 'auto'; queryTimeoutSeconds = 20; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'
                                                                        maxPerDay = 6; minimumGapMinutes = 60
                                                                        model = 'gpt-5.6 luna' } } })
$joined = ($shapeIssues -join ' ~ ')
Assert-True ($joined -match 'codex.autoAnchor.model') 'T01: a model with a space is rejected by the config layer'
Assert-False ($joined -match 'catalog|CLI') 'T01: and it is rejected without any catalog read (L1 is offline)'

# ---------------------------------------------------------------------------
# §6.2 priority: model and reasoning effort

Start-TestGroup 'profile (§6.2): model priority explicit > codex-config > catalog-default'

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead -Model 'cfg-model') `
    -Catalog (New-MockCatalog -Models $script:MockCatalog -DefaultModel 'mock-model-alpha') `
    -ConfiguredModel 'mock-model-beta' -ConfiguredEffort ''
Assert-Equal 'mock-model-beta' $sel.effectiveModel 'explicit model wins'
Assert-Equal 'explicit' $sel.modelSource 'and is reported as explicit'

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead -Model 'mock-model-beta') `
    -Catalog (New-MockCatalog -Models $script:MockCatalog -DefaultModel 'mock-model-alpha') `
    -ConfiguredModel '' -ConfiguredEffort ''
Assert-Equal 'mock-model-beta' $sel.effectiveModel 'blank explicit falls back to the CLI config'
Assert-Equal 'codex-config' $sel.modelSource 'source says where it came from'

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead) `
    -Catalog (New-MockCatalog -Models $script:MockCatalog -DefaultModel 'mock-model-alpha') `
    -ConfiguredModel '' -ConfiguredEffort ''
Assert-Equal 'mock-model-alpha' $sel.effectiveModel 'nothing configured anywhere -> catalog default'
Assert-Equal 'catalog-default' $sel.modelSource 'source says catalog default'

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead) `
    -Catalog (New-MockCatalog -Models $script:MockCatalog -DefaultModel '') `
    -ConfiguredModel '' -ConfiguredEffort ''
Assert-Equal 'INVALID' $sel.validation 'no resolvable model is never VALID'
Assert-True ($sel.validationReason -match 'no model could be resolved') 'reason names the resolution failure'
Assert-Equal 'PROFILE_INVALID' $sel.errorKind 'kind is the profile-level one'

Start-TestGroup 'profile (§6.2): reasoning effort priority explicit > codex-config > model-default'

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead -Model 'mock-model-beta' -Effort 'high') `
    -Catalog (New-MockCatalog -Models $script:MockCatalog -DefaultModel 'mock-model-alpha') `
    -ConfiguredModel 'mock-model-beta' -ConfiguredEffort 'medium'
Assert-Equal 'medium' $sel.effectiveReasoningEffort 'explicit effort wins'
Assert-Equal 'explicit' $sel.reasoningEffortSource 'and is reported as explicit'

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead -Model 'mock-model-beta' -Effort 'high') `
    -Catalog (New-MockCatalog -Models $script:MockCatalog -DefaultModel 'mock-model-alpha') `
    -ConfiguredModel 'mock-model-beta' -ConfiguredEffort ''
Assert-Equal 'high' $sel.effectiveReasoningEffort 'blank explicit falls back to the CLI config'
Assert-Equal 'codex-config' $sel.reasoningEffortSource 'effort source reported'

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead -Model 'mock-model-beta') `
    -Catalog (New-MockCatalog -Models $script:MockCatalog -DefaultModel 'mock-model-alpha') `
    -ConfiguredModel 'mock-model-beta' -ConfiguredEffort ''
Assert-Equal 'medium' $sel.effectiveReasoningEffort 'nothing configured -> the model own default'
Assert-Equal 'model-default' $sel.reasoningEffortSource 'effort source is model-default'

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead -Model 'mock-model-delta') `
    -Catalog (New-MockCatalog -Models $script:MockCatalog -DefaultModel 'mock-model-alpha') `
    -ConfiguredModel 'mock-model-delta' -ConfiguredEffort ''
Assert-Equal 'high' $sel.effectiveReasoningEffort 'a model can default to a non-low effort'
Assert-Equal 'VALID' $sel.validation 'and its own default is of course supported'

# ---------------------------------------------------------------------------
# L2 / L3 semantics, without any process

Start-TestGroup 'profile (§5.1 L2): absent vs retired are both INVALID, but not the same reason'

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead) `
    -Catalog (New-MockCatalog -Models $script:MockCatalog -DefaultModel 'mock-model-alpha') `
    -ConfiguredModel 'syntactically-valid-but-does-not-exist' -ConfiguredEffort ''
Assert-Equal 'INVALID' $sel.validation 'T02: a well-formed model that is absent is INVALID'
Assert-Equal 'PROFILE_INVALID' $sel.errorKind 'T02: reported as PROFILE_INVALID'
Assert-True ($sel.validationReason -match 'not in this Codex CLI') 'T02: reason says the catalog does not know it'
Assert-Equal 'syntactically-valid-but-does-not-exist' $sel.effectiveModel 'the rejected model is still reported (audit)'
Assert-Equal 'explicit' $sel.modelSource 'and so is its source'
$absentReason = $sel.validationReason

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead) `
    -Catalog (New-MockCatalog -Models $script:MockCatalog -DefaultModel 'mock-model-alpha') `
    -ConfiguredModel 'mock-model-retired' -ConfiguredEffort ''
Assert-Equal 'INVALID' $sel.validation 'T06: a retired model is INVALID'
Assert-True ($sel.validationReason -match 'hidden|retired') 'T06: the reason says it is retired, not unknown'
Assert-True ($absentReason -ne $sel.validationReason) 'a retired model and a typo do not read the same'
Assert-Contains $sel.supportedReasoningEfforts 'low' 'the catalog entry is still reported for the audit'

Start-TestGroup 'profile (§5.1 L3): effort must be in the target model''s own list'

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead) `
    -Catalog (New-MockCatalog -Models $script:MockCatalog -DefaultModel 'mock-model-alpha') `
    -ConfiguredModel 'mock-model-alpha' -ConfiguredEffort 'xhigh'
Assert-Equal 'INVALID' $sel.validation 'T03: an unsupported effort is INVALID'
Assert-True ($sel.validationReason -match 'xhigh') 'T03: the reason names the effort'
Assert-True ($sel.validationReason -match 'low/medium/high') 'T03: and lists what the model does support'
Assert-Equal 'explicit' $sel.reasoningEffortSource 'the rejected effort keeps its source'

$sel = Get-ExecutionProfileSelection -ConfigRead (New-MockConfigRead) `
    -Catalog (New-MockCatalog -Models @((New-MockModelEntry -Model 'mock-model-silent')) -DefaultModel 'mock-model-silent') `
    -ConfiguredModel '' -ConfiguredEffort 'high'
Assert-Equal 'UNAVAILABLE' $sel.validation 'an entry with no capability list cannot prove anything'
Assert-Equal 'SCHEMA_UNKNOWN' $sel.errorKind 'and that is a schema problem, not a user typo'
Assert-True ($sel.validationReason -match 'no supportedReasoningEfforts') 'reason names the missing capability data'

# ---------------------------------------------------------------------------
# End-to-end through the mock app-server

Start-TestGroup 'e2e (T04): nothing configured resolves from config/read + catalog'

$p = Invoke-ProfileResolve -Mode ''
Assert-Equal 'VALID' $p.validation 'T04: the live profile validates'
Assert-Equal 'mock-model-beta' $p.effectiveModel 'T04: effectiveModel comes from config/read'
Assert-Equal 'codex-config' $p.modelSource 'T04: source is codex-config'
Assert-Equal 'high' $p.effectiveReasoningEffort 'T04: effectiveReasoningEffort comes from config/read'
Assert-Equal 'codex-config' $p.reasoningEffortSource 'T04: effort source is codex-config'
Assert-Equal 'mock-provider' $p.modelProvider 'T04: provider from the same read'
Assert-Equal '' $p.configuredModel 'configured* echo what the config said (nothing)'
Assert-Equal '' $p.configuredReasoningEffort 'both configured values are empty'
Assert-Equal $null $p.errorKind 'a VALID profile carries no error kind'
Assert-False $p.retryable 'and is not marked retryable'
Assert-True ($p.validatedAt -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d') 'validatedAt is an ISO timestamp'
Assert-Contains $p.supportedReasoningEfforts 'xhigh' 'the capabilities of the EFFECTIVE model are reported'

$p = Invoke-ProfileResolve -Mode 'config-empty'
Assert-Equal 'VALID' $p.validation 'T04: an empty CLI config still resolves'
Assert-Equal 'mock-model-alpha' $p.effectiveModel 'T04: falls through to the catalog default'
Assert-Equal 'catalog-default' $p.modelSource 'T04: source is catalog-default'
Assert-Equal 'low' $p.effectiveReasoningEffort 'T04: the model default effort is used'
Assert-Equal 'model-default' $p.reasoningEffortSource 'T04: source is model-default'

Start-TestGroup 'e2e: explicit values win and are echoed into the audit'

$p = Invoke-ProfileResolve -Mode '' -Model 'mock-model-delta' -Effort 'high'
Assert-Equal 'VALID' $p.validation 'explicit model + supported effort validates'
Assert-Equal 'mock-model-delta' $p.effectiveModel 'effective model is the explicit one'
Assert-Equal 'explicit' $p.modelSource 'model source explicit'
Assert-Equal 'mock-model-delta' $p.configuredModel 'configuredModel echoes config.json'
Assert-Equal 'high' $p.effectiveReasoningEffort 'effective effort is the explicit one'
Assert-Equal 'explicit' $p.reasoningEffortSource 'effort source explicit'
Assert-Equal 'high' $p.configuredReasoningEffort 'configuredReasoningEffort echoes config.json'
Assert-Equal 1 (@($p.supportedReasoningEfforts).Count) 'delta supports exactly one effort'
Assert-Equal 'mock-provider' $p.modelProvider 'provider still comes from the live read'

Start-TestGroup 'e2e (T02/T03/T06): the three semantic rejections survive the live path'

$p = Invoke-ProfileResolve -Mode '' -Model 'syntactically-valid-but-does-not-exist'
Assert-Equal 'INVALID' $p.validation 'T02: absent model -> INVALID'
Assert-Equal 'PROFILE_INVALID' $p.errorKind 'T02: kind'
Assert-False $p.retryable 'T02: not retryable - the next poll would answer the same'
Assert-Equal 'syntactically-valid-but-does-not-exist' $p.effectiveModel 'T02: the audit still shows what was asked for'

$p = Invoke-ProfileResolve -Mode '' -Model 'mock-model-alpha' -Effort 'xhigh'
Assert-Equal 'INVALID' $p.validation 'T03: unsupported effort -> INVALID'
Assert-True ($p.validationReason -match 'not supported') 'T03: reason'

$p = Invoke-ProfileResolve -Mode '' -Model 'mock-model-retired'
Assert-Equal 'INVALID' $p.validation 'T06: a model the CLI stopped offering -> INVALID (retired)'
Assert-True ($p.validationReason -match 'hidden|retired') 'T06: reason names retirement'

Start-TestGroup 'e2e (T05): a model on page 2 must not look invalid'

$p = Invoke-ProfileResolve -Mode 'catalog-paged' -Model 'mock-model-zeta' -Effort 'medium'
Assert-Equal 'VALID' $p.validation 'T05: cross-page model validates'
Assert-Equal 'mock-model-zeta' $p.effectiveModel 'T05: effective model is the page-2 entry'
Assert-Contains $p.supportedReasoningEfforts 'medium' 'T05: its capabilities came from the same page'
$p = Invoke-ProfileResolve -Mode 'catalog-paged' -Model 'mock-model-alpha'
Assert-Equal 'VALID' $p.validation 'T05: a page-1 model still validates when the catalog paginates'

Start-TestGroup 'e2e: read failures are UNAVAILABLE, never a silent VALID'

$p = Invoke-ProfileResolve -Mode 'catalog-error'
Assert-Equal 'UNAVAILABLE' $p.validation 'a rejected catalog read is UNAVAILABLE'
Assert-Equal 'AUTH_ERROR' $p.errorKind 'the client error kind is passed through'
Assert-False $p.retryable 'auth problems are not retryable'
Assert-Equal '' $p.effectiveModel 'nothing was resolved, and the profile says so'
Assert-Equal 0 (@($p.supportedReasoningEfforts).Count) 'and no capabilities were claimed from a read that failed'

$p = Invoke-ProfileResolve -Mode 'config-error'
Assert-Equal 'UNAVAILABLE' $p.validation 'an unreadable config is UNAVAILABLE'
Assert-Equal 'AUTH_ERROR' $p.errorKind 'config/read auth failure classified'

$t0 = [DateTime]::UtcNow
$p = Invoke-ProfileResolve -Mode 'catalog-timeout' -Model 'mock-model-beta' -Effort 'high' -TimeoutSeconds 2
$elapsed = ([DateTime]::UtcNow - $t0).TotalSeconds
Assert-Equal 'UNAVAILABLE' $p.validation 'a never-answering catalog is UNAVAILABLE'
Assert-Equal 'TIMEOUT' $p.errorKind 'timeout kind'
Assert-True $p.retryable 'a timeout IS retryable (REPO policy: transient)'
Assert-True ($elapsed -lt 15) "bounded by the query timeout (took $([int]$elapsed)s)"
Assert-Equal 'mock-model-beta' $p.configuredModel 'configured values are reported even when the read failed'
Assert-Equal 'high' $p.configuredReasoningEffort 'both configured values survive the failed read (they come from config, not the wire)'
Assert-True ("$($p.validationReason)" -match 'timed out') 'the reason carries the sanitized client message'

Start-TestGroup 'e2e: one resolution is one session (same Codex environment)'

$counter = New-SessionCounterPath
try {
    $env:CQK_MOCK_SESSIONS_FILE = $counter
    $p = Invoke-ProfileResolve -Mode ''
    $afterFirst = Get-SessionCount $counter
    $null = Invoke-ProfileResolve -Mode 'config-empty'
    $afterSecond = Get-SessionCount $counter
} finally {
    Remove-Item Env:\CQK_MOCK_SESSIONS_FILE -ErrorAction SilentlyContinue
}
Assert-Equal 1 $afterFirst 'one resolution opened exactly one child process'
Assert-Equal 'mock-model-beta' $p.effectiveModel 'the profile still came from the CLI config'
Assert-Contains $p.supportedReasoningEfforts 'xhigh' 'and the catalog read happened in that same session'
Assert-True ($afterSecond -eq 2) "a second resolution opens a second session and no more (counter: $afterFirst -> $afterSecond)"
Remove-Item -LiteralPath $counter -Force -ErrorAction SilentlyContinue

Start-TestGroup 'privacy: the profile never carries config noise'

$p = Invoke-ProfileResolve -Mode ''
$blob = ConvertTo-Json -InputObject $p -Depth 10
foreach ($forbidden in @('hook.exe', 'mock free-form', 'deadbeef', 'MOCK_SHA256S', 'enabled-reasoning-efforts', 'notify', 'instructions')) {
    Assert-False ($blob -match [regex]::Escape($forbidden)) "live profile does not leak [$forbidden]"
}
Assert-False ($blob -match '(?i)bearer\s+[A-Za-z0-9]') 'live profile carries no bearer token'

# ---------------------------------------------------------------------------
# Cache + budgets

Start-TestGroup 'cache: runtime/execution-profile.json is a whitelist, not a dump'

$ws = New-TestWorkspace
try {
    $missing = Read-ExecutionProfileCache -KeeperRoot $ws
    Assert-False $missing.ok 'nothing cached yet reads as not-ok, not as an empty profile'
    Assert-Equal (Join-Path $ws 'runtime\execution-profile.json') $missing.path 'the cache path is the documented one'

    $prof = Invoke-ProfileResolve -Mode '' -Model 'mock-model-delta' -Effort 'high'
    $w = Write-ExecutionProfileCache -KeeperRoot $ws -Profile $prof
    Assert-True $w.ok 'cache written'
    Assert-True (Test-Path -LiteralPath $w.path) 'cache file exists'
    $text = [System.IO.File]::ReadAllText($w.path)
    # Match the JSON key form ("key":), not a bare substring: 'models' is a
    # substring of 'modelSource' under a case-insensitive -match, and the point
    # of this test is exactly which KEYS are present.
    foreach ($k in @('effectiveModel', 'effectiveReasoningEffort', 'modelProvider', 'modelSource', 'reasoningEffortSource', 'validation', 'validatedAt')) {
        Assert-True ($text -match ('"' + [regex]::Escape($k) + '"\s*:')) "cache carries [$k]"
    }
    foreach ($k in @('supportedReasoningEfforts', 'configuredModel', 'configuredReasoningEffort', 'validationReason', 'errorKind', 'retryable', 'models')) {
        Assert-False ($text -match ('"' + [regex]::Escape($k) + '"\s*:')) "cache does not carry [$k]"
    }
    $back = Read-ExecutionProfileCache -KeeperRoot $ws
    Assert-True $back.ok 'cache reads back'
    Assert-Equal 'mock-model-delta' $back.value.effectiveModel 'effective model round-trips'
    Assert-Equal 'VALID' $back.value.validation 'verdict round-trips'
    Assert-Equal 'explicit' $back.value.modelSource 'source round-trips'

    # A poisoned profile must not be able to smuggle anything in: the writer
    # projects into the whitelist instead of trusting its input. The token is
    # built by concatenation because the repository secret scanner
    # (tests/secret-scan.ps1) matches sk-[A-Za-z0-9_-]{20,} - a literal here
    # would itself be a scan finding, the same rule secret-scan.test.ps1 follows.
    $poisonToken = 'sk-' + 'should-never' + '-be-written'
    $poison = @{ effectiveModel = 'mock-model-delta'; validation = 'VALID'; validatedAt = '2026-09-11T10:00:00+08:00'
                 token = $poisonToken; rawConfig = @{ notify = @('C:\private\hook.exe') }
                 catalog = @(@{ model = 'mock-model-alpha' }) }
    $w2 = Write-ExecutionProfileCache -KeeperRoot $ws -Profile $poison
    $text2 = [System.IO.File]::ReadAllText($w2.path)
    foreach ($forbidden in @($poisonToken, 'rawConfig', 'private', 'catalog')) {
        Assert-False ($text2 -match [regex]::Escape($forbidden)) "poisoned profile cannot write [$forbidden]"
    }

    # An unreadable cache file degrades to "no cache" instead of throwing.
    [System.IO.File]::WriteAllText($w.path, '{ not json at all')
    $broken = Read-ExecutionProfileCache -KeeperRoot $ws
    Assert-False $broken.ok 'a corrupt cache reads as not-ok'
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'budget: the profile path has its own bounded ceiling'

$budget = Get-CodexProfileBudgetSeconds (New-ProfileConfig -TimeoutSeconds 20)
Assert-Equal 160 $budget.seconds '20s timeout x 8 waits'
Assert-Equal 8 $budget.waitsCeiling 'the ceiling is initialize + config/read + the page cap'
Assert-Equal ($script:CQK_PROFILE_WAITS_CEILING) (2 + $script:CQK_MODEL_LIST_MAX_PAGES) `
    'the ceiling and the client page cap cannot drift apart'
Assert-Equal 8 $script:CQK_PROFILE_WAITS_CEILING 'pinned: one session, one config read, six pages'
$budget = Get-CodexProfileBudgetSeconds (New-ProfileConfig -TimeoutSeconds 5)
Assert-Equal 40 $budget.seconds 'a smaller timeout scales the same way'

# The absent proxy fallback is a design decision (§6.2), so it is pinned: a
# configured proxy must NOT double this ceiling the way it does for the quota read.
$plain = Get-CodexProfileBudgetSeconds (New-ProfileConfig -TimeoutSeconds 20)
$proxied = Get-CodexProfileBudgetSeconds (New-ProfileConfig -TimeoutSeconds 20 -Proxy 'http://proxy.invalid:7890')
Assert-Equal $plain.seconds $proxied.seconds 'a proxy does not add a fallback attempt to the profile budget'
# Not written as `Assert-Equal 2 (cmd …).attempts`: a member access after a
# parenthesised argument binds to the ARGUMENT, not to the result.
$quotaBudget = Get-CodexAttemptBudgetSeconds (New-ProfileConfig -TimeoutSeconds 20 -Proxy 'http://proxy.invalid:7890')
Assert-Equal 2 $quotaBudget.attempts `
    'sanity: the quota read DOES budget two attempts under the same proxy, so the equality above is a decision and not a coincidence'

$result = Get-TestResult
Write-Host ""
Write-Host ("codex-profile: {0} checks, {1} failures" -f $result.checks, $result.failures)
if ($result.failures -gt 0) { exit 1 }
exit 0
