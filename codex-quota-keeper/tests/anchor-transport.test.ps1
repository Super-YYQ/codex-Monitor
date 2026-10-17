# Replay a failed proxy quota read followed by a successful fallback. The one
# physical model invocation must use that working route, without a model retry.
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scripts = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scripts 'auto-anchor.ps1')
$hostExe = (Get-Process -Id $PID).Path
$mock = Join-Path $testsDir 'fixtures\mock-appserver.ps1'

function New-TransportConfig {
    return New-TestConfig @{
        mode = 'AutoAnchor'
        codex = @{ command = $mock; queryTimeoutSeconds = 5; proxy = 'http://127.0.0.1:19999'; autoAnchor = @{
            enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 1
            anchorOnExpiry = @('primary'); schedule = @(); model = 'mock-model-alpha'; reasoningEffort = 'low'
        } }
        github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false; push = $false } }
    }
}
function Get-TransportAudits([string]$Root) {
    return @(Get-ChildItem -LiteralPath (Join-Path $Root 'history') -Filter '*.jsonl' | ForEach-Object {
        Get-Content -LiteralPath $_.FullName | ForEach-Object { ConvertFrom-JsonSafe $_ }
    } | Where-Object { $_.event -in @('ANCHOR_EXECUTED', 'ANCHOR_ABORTED') })
}

$ws = New-TestWorkspace
try {
    $env:CQK_MOCK_MODE = 'expiry-primary'
    $env:CQK_MOCK_EXEC = 'ok'
    $env:CQK_MOCK_PROXY_URL = 'http://127.0.0.1:19999'
    $env:CQK_MOCK_FAIL_WITH_PROXY = '1'
    $env:CQK_MOCK_EXEC_ARGS_FILE = Join-Path $ws 'exec.txt'
    $cfg = New-TransportConfig
    $configFile = Join-Path $ws 'config.json'
    $null = Write-TestConfigFile $configFile $cfg
    $configHash = (Get-FileHash -LiteralPath $configFile).Hash

    Start-TestGroup 'runner: successful fallback selects the sole model-call route'
    $output = & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'runner.ps1') -KeeperRoot $ws -ConfigFile $configFile -NoSync -NoTaskChanges 2>&1
    Assert-Equal 0 $LASTEXITCODE "runner completes ($($output -join ' '))"
    $state = Load-KeeperState $ws
    Assert-Equal 1 $state.anchors.attemptCount 'one allowance reserved'
    Assert-Equal 1 $state.anchors.successCount 'working fallback also reaches the model invocation'
    Assert-Equal 0 $state.anchors.failedCount 'failed proxy is not reapplied to exec'
    $audits = @(Get-TransportAudits $ws)
    Assert-Equal 1 $audits.Count 'one physical invocation audit'
    Assert-Equal 'ANCHOR_EXECUTED' $audits[0].event 'fallback invocation succeeds'
    Assert-Equal 'fallback' $audits[0].anchor.execRoute 'the selected route is audited without proxy credentials'
    $count = if (Test-Path -LiteralPath $env:CQK_MOCK_EXEC_ARGS_FILE) { @(Get-Content -LiteralPath $env:CQK_MOCK_EXEC_ARGS_FILE).Count } else { 0 }
    Assert-Equal 1 $count 'exactly one physical exec reaches the mock'
    $null = & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'runner.ps1') -KeeperRoot $ws -ConfigFile $configFile -NoSync -NoTaskChanges 2>&1
    $count = if (Test-Path -LiteralPath $env:CQK_MOCK_EXEC_ARGS_FILE) { @(Get-Content -LiteralPath $env:CQK_MOCK_EXEC_ARGS_FILE).Count } else { 0 }
    Assert-Equal 1 $count 'a later poll cannot repeat the claimed trigger'
    Assert-Equal $configHash (Get-FileHash -LiteralPath $configFile).Hash 'route choice does not rewrite config'

    Start-TestGroup 'runner: a working configured proxy is retained'
    Remove-Item Env:\CQK_MOCK_FAIL_WITH_PROXY
    $proxyRoot = Join-Path $ws 'proxy-ok'
    Ensure-Directory $proxyRoot | Out-Null
    $proxyConfig = Join-Path $proxyRoot 'config.json'
    $null = Write-TestConfigFile $proxyConfig $cfg
    $null = & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'runner.ps1') -KeeperRoot $proxyRoot -ConfigFile $proxyConfig -NoSync -NoTaskChanges 2>&1
    $proxyAudit = @(Get-TransportAudits $proxyRoot)[0]
    Assert-Equal 'ANCHOR_EXECUTED' $proxyAudit.event 'configured route succeeds'
    Assert-Equal 'proxy' $proxyAudit.anchor.execRoute 'successful proxy is retained'

    Start-TestGroup 'real process: retain stderr captured before a timeout'
    $child = Join-Path $ws 'timeout-child.ps1'
    [IO.File]::WriteAllText($child, "[Console]::Error.WriteLine('offline transport diagnostic'); [Console]::Error.Flush(); Start-Sleep -Seconds 15")
    $timed = Invoke-External -FilePath $hostExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$child) -TimeoutSeconds 2
    Assert-True $timed.timedOut 'real child reaches the deadline'
    Assert-True ($timed.stderr -match 'offline transport diagnostic') 'captured transport detail survives process termination'

    Start-TestGroup 'anchor: exec failures retain their own kind after quota verification'
    function Get-AnchorProfileGate {
        param($Config)
        $script:ProfileProxy = $Config.codex.proxy
        return @{ allowed = $true; codexPath = $mock; profile = @{ validation = 'VALID'; effectiveModel = 'mock-model-alpha'; effectiveReasoningEffort = 'low' } }
    }
    $script:MinimumLifecycleSeconds = 0
    $script:PhysicalExecCalls = 0
    function Invoke-External {
        param($Environment, $TimeoutSeconds)
        $script:PhysicalExecCalls++
        $script:PassedExecTimeout = $TimeoutSeconds
        $script:ExecProxy = $Environment.HTTPS_PROXY
        if ($TimeoutSeconds -lt $script:MinimumLifecycleSeconds) { return @{ ok=$false; started=$true; exitCode=-1; timedOut=$true; stderr='process timed out during startup/response/shutdown lifecycle' } }
        return $script:ExecResult
    }
    function Invoke-CodexRateLimitsRead { return $script:VerifyResult }
    $cases = @(
        @{ name = 'timeout-read-ok'; exec = @{ ok=$false; started=$true; exitCode=-1; timedOut=$true; stderr='process timed out' }; verify=@{ ok=$true; windows=@() }; kind='TIMEOUT'; reason='timed out' },
        @{ name = 'network-read-ok'; exec = @{ ok=$false; started=$true; exitCode=1; timedOut=$false; stderr=('error sending request; Bearer ' + 'offline-fixture') }; verify=@{ ok=$true; windows=@() }; kind='NETWORK_ERROR'; reason='error sending request' },
        @{ name = 'long-stderr'; exec = @{ ok=$false; started=$true; exitCode=1; timedOut=$false; stderr=(('startup detail ' * 300) + 'error sending request') }; verify=@{ ok=$true; windows=@() }; kind='NETWORK_ERROR'; reason='error sending request' },
        @{ name = 'both-fail'; exec = @{ ok=$false; started=$true; exitCode=-1; timedOut=$true; stderr='process timed out' }; verify=@{ ok=$false; errorKind='NETWORK_ERROR'; message='offline verification failure' }; kind='TIMEOUT'; reason='timed out' },
        @{ name = 'verify-only'; exec = @{ ok=$true; started=$true; exitCode=0; timedOut=$false; stderr='' }; verify=@{ ok=$false; errorKind='NETWORK_ERROR'; message='offline verification failure' }; kind='NETWORK_ERROR'; reason='post-anchor verification failed' }
    )
    foreach ($case in $cases) {
        $script:ExecResult = $case.exec
        $script:VerifyResult = $case.verify
        $root = Join-Path $ws $case.name
        $s = New-KeeperState
        $s.stale = $false
        $out = Invoke-AutoAnchorIfNeeded -Config $cfg -KeeperRoot $root -State $s -Events @() -IsLeader $true -Machine @{ machineId='offline-test' } -Election @{ localOnly=$true } -ForceAnchor $true
        $abort = @($out.events | Where-Object event -eq 'ANCHOR_ABORTED')[0]
        Assert-Equal $case.kind $abort.anchor.errorKind "$($case.name): failing phase supplies the kind"
        Assert-True ($abort.reason -match $case.reason) "$($case.name): actionable failure survives"
        Assert-Equal 1 $s.anchors.attemptCount "$($case.name): uncertain invocation is charged once"
        Assert-Equal 1 $s.anchors.failedCount "$($case.name): failure is not mistaken for success"
        Assert-False ($abort.reason -match 'offline-fixture') "$($case.name): credentials are redacted"
    }

    Start-TestGroup 'anchor route selection preserves caller config and profile identity'
    $script:ExecResult = @{ ok=$true; started=$true; exitCode=0; timedOut=$false; stderr='' }
    $script:VerifyResult = @{ ok=$true; windows=@() }
    foreach ($route in @('fallback', 'used', 'missing', 'direct')) {
        $routeCfg = New-TransportConfig
        if ($route -eq 'direct') { $routeCfg.codex.proxy = '' }
        $originalProxy = $routeCfg.codex.proxy
        $read = if ($route -eq 'missing') { $null } else { @{ ok=$true; proxy=$route } }
        $s = New-KeeperState; $s.stale = $false
        $out = Invoke-AutoAnchorIfNeeded -Config $routeCfg -KeeperRoot (Join-Path $ws "route-$route") -State $s -Events @() -IsLeader $true -Machine @{ machineId='offline-test' } -Election @{ localOnly=$true } -ForceAnchor $true -QuotaRead $read
        $expectedProxy = if ($route -in @('fallback','direct')) { '' } else { $originalProxy }
        Assert-Equal $expectedProxy ([string]$script:ProfileProxy) "$route profile uses the selected environment"
        Assert-Equal $expectedProxy ([string]$script:ExecProxy) "$route exec uses the same environment"
        Assert-Equal $originalProxy $routeCfg.codex.proxy "$route does not mutate caller config"
    }

    Start-TestGroup 'model command budget includes startup and shutdown, not only the reply'
    $script:MinimumLifecycleSeconds = 90
    $script:ExecResult = @{ ok=$true; started=$true; exitCode=0; timedOut=$false; stderr='' }
    $script:VerifyResult = @{ ok=$true; windows=@() }
    $s = New-KeeperState; $s.stale = $false
    $slowRoot = Join-Path $ws 'slow-command-lifecycle'
    $out = Invoke-AutoAnchorIfNeeded -Config $cfg -KeeperRoot $slowRoot -State $s -Events @() -IsLeader $true -Machine @{ machineId='offline-test' } -Election @{ localOnly=$true } -ForceAnchor $true
    Assert-True $out.anchored 'a valid 90s CLI lifecycle is allowed to finish'
    Assert-Equal 1 $s.anchors.successCount 'the complete command is a successful anchor'
    Assert-Equal (Get-AnchorExecBudgetSeconds $cfg) $script:PassedExecTimeout 'execution and scheduled-task budget use one source'
    Assert-True ($script:PassedExecTimeout -ge $script:MinimumLifecycleSeconds) 'startup and shutdown overhead have headroom'
    $calls = $script:PhysicalExecCalls
    $null = Invoke-AutoAnchorIfNeeded -Config $cfg -KeeperRoot $slowRoot -State $s -Events @() -IsLeader $true -Machine @{ machineId='offline-test' } -Election @{ localOnly=$true } -ForceAnchor $true
    Assert-Equal $calls $script:PhysicalExecCalls 'a completed lifecycle is never retried'
    Assert-Equal 1 $s.anchors.attemptCount 'a longer deadline still reserves one daily attempt'
} finally {
    foreach ($name in @('CQK_MOCK_MODE','CQK_MOCK_EXEC','CQK_MOCK_EXEC_ARGS_FILE','CQK_MOCK_PROXY_URL','CQK_MOCK_FAIL_WITH_PROXY')) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
    Remove-TestWorkspace $ws
}
$result = Get-TestResult
Write-Host "$($result.checks) checks, $($result.failures) failures."
exit $(if ($result.failures) { 1 } else { 0 })
