# Unit tests for common.ps1: config load/validation, machine identity, backoff,
# sanitization, hashing, atomic JSON writes, local runner lock.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
. (Join-Path (Split-Path -Parent $testsDir) 'scripts\common.ps1')
. (Join-Path (Split-Path -Parent $testsDir) 'scripts\auto-anchor.ps1')

Start-TestGroup 'config: defaults are conservative'

$defaults = Get-DefaultConfig
Assert-Equal 'MonitorOnly' $defaults.mode 'default mode is MonitorOnly'
Assert-Equal 2 $defaults.schemaVersion 'v2 config schema'
Assert-False ([bool]$defaults.codex.autoAnchor.enabled) 'autoAnchor default off'
Assert-Equal 60 $defaults.poll.intervalMinutes 'default poll 60 min'
Assert-Equal 5 $defaults.poll.minimumIntervalMinutes 'min poll floor 5 min'
Assert-False ([bool]$defaults.logging.includeMachineLabel) 'machineLabel privacy default off'
Assert-False ([bool]$defaults.github.coordination.enabled) 'coordination default off (local-only)'
Assert-False ([bool]$defaults.github.historySync.enabled) 'historySync default off'
Assert-Equal 'cqk/coordination' $defaults.github.coordination.branch 'coordination branch name'
Assert-Equal 'cqk/history' $defaults.github.historySync.branch 'history branch name'
Assert-True ([bool]$defaults.task.startWithWindows) 'startWithWindows default true'
Assert-Equal 300 $defaults.codex.autoAnchor.minimumGapMinutes 'minimumGap default 300 (5h quiet after a call)'
Assert-Equal 300 $defaults.codex.autoAnchor.keepaliveIntervalMinutes 'keepalive default 300 (idle backstop, one 5h window)'
Assert-False ([bool]$defaults.codex.autoAnchor.anchorOnApply) 'anchorOnApply default off (opt-in immediate trigger)'
Assert-Equal '' $defaults.codex.autoAnchor.model 'anchor model default empty (CLI config.toml default applies)'
Assert-Equal '' $defaults.codex.autoAnchor.reasoningEffort 'anchor reasoningEffort default empty (CLI config.toml default applies)'

Start-TestGroup 'config: Load-Config merges defaults and validates'

$ws = New-TestWorkspace
try {
    $cfgFile = Join-Path $ws 'config.json'
    $cfg = New-TestConfig @{ github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } } }
    [void](Write-TestConfigFile $cfgFile $cfg)
    $loaded = Load-Config $cfgFile
    Assert-Equal 0 @($loaded.issues).Count 'valid config has no issues'
    Assert-Equal 'MonitorOnly' $loaded.config.mode 'mode preserved'
    Assert-Equal 'Test PC' $loaded.config.leader.label 'test label preserved'

    Start-TestGroup 'config: poll interval below minimum is rejected'

    $bad = New-TestConfig @{ poll = @{ intervalMinutes = 1; minimumIntervalMinutes = 1 } }
    [void](Write-TestConfigFile $cfgFile $bad)
    $loaded2 = Load-Config $cfgFile
    Assert-True (@($loaded2.issues).Count -ge 1) 'poll below 5-min floor rejected'

    Start-TestGroup 'config: lease TTL / poll relational validation (CQK-021)'

    $defIssues = @(Test-ConfigShape (Get-DefaultConfig))
    Assert-Equal 0 $defIssues.Count 'shipped defaults satisfy the lease/poll relation'
    Assert-Equal 180 (Get-DefaultConfig).leader.leaseTtlMinutes 'default lease TTL 180 (≈3x default poll 60)'

    # Doc §4.1 flapping example: poll=60 with TTL=45 expires between two polls.
    $noCoord = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
    $flap = New-TestConfig @{ poll = @{ intervalMinutes = 60; minimumIntervalMinutes = 5 }; leader = @{ leaseTtlMinutes = 45 }; github = $noCoord }
    $flapIssues = @(Test-ConfigShape $flap)
    Assert-True ($flapIssues.Count -ge 1) 'poll=60 with TTL=45 rejected'
    Assert-True (($flapIssues -join '; ') -match 'leaseTtlMinutes') 'rejection names leader.leaseTtlMinutes'
    Assert-True (($flapIssues -join '; ') -match '120') 'rejection states the required minimum'

    # Boundary: TTL exactly 2*poll passes.
    $edge = New-TestConfig @{ poll = @{ intervalMinutes = 60; minimumIntervalMinutes = 5 }; leader = @{ leaseTtlMinutes = 120 }; github = $noCoord }
    Assert-Equal 0 @(Test-ConfigShape $edge).Count 'TTL = 2*poll accepted (boundary)'

    # Grace branch dominates when grace is large: poll=60 TTL=120 grace=70 needs >= 135.
    $wide = New-TestConfig @{ poll = @{ intervalMinutes = 60; minimumIntervalMinutes = 5 }; leader = @{ leaseTtlMinutes = 120; graceMinutes = 70 }; github = $noCoord }
    Assert-True (@(Test-ConfigShape $wide).Count -ge 1) 'large grace raises the required TTL (poll+grace+jitter branch)'
    $wideOk = New-TestConfig @{ poll = @{ intervalMinutes = 60; minimumIntervalMinutes = 5 }; leader = @{ leaseTtlMinutes = 135; graceMinutes = 70 }; github = $noCoord }
    Assert-Equal 0 @(Test-ConfigShape $wideOk).Count 'TTL = poll+grace+jitter accepted (boundary)'

    # Helper default TTL=45 must stay valid for the default test poll=15.
    Assert-Equal 0 @(Test-ConfigShape (New-TestConfig @{ github = $noCoord })).Count 'test-helper default config satisfies the relation'

    Start-TestGroup 'config: queryTimeoutSeconds upper bound and task time limit relation (CQK-031)'

    # The timeout is per JSON-RPC wait, so it multiplies: 2 waits per attempt, 2
    # attempts once a proxy is configured, and AutoAnchor pays the read twice (poll
    # + verify) on top of the exec. A hard ceiling keeps that product bounded.
    # Test poll stays at the helper default 15 min so the CQK-021 lease rule (TTL 45)
    # remains satisfied while only the timeout/poll relation is under test.
    Assert-Equal 180 $script:CQK_MAX_QUERY_TIMEOUT_SECONDS 'queryTimeoutSeconds ceiling is 180 s'
    $noCoordCqk = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
    $tMax = New-TestConfig @{ github = $noCoordCqk; codex = @{ queryTimeoutSeconds = 180 } }
    Assert-Equal 0 @(Test-ConfigShape $tMax).Count 'ceiling value itself accepted (boundary)'
    $tOver = New-TestConfig @{ github = $noCoordCqk; codex = @{ queryTimeoutSeconds = 181 } }
    $tOverIssues = @(Test-ConfigShape $tOver)
    Assert-True ($tOverIssues.Count -ge 1) 'queryTimeoutSeconds above the ceiling rejected'
    Assert-True (($tOverIssues -join '; ') -match 'queryTimeoutSeconds') 'rejection names the key'
    Assert-True (($tOverIssues -join '; ') -match '180') 'rejection states the ceiling'

    # Attempt budget: 2 waits x timeout, doubled by the proxy fallback path.
    $bPlain = Get-CodexAttemptBudgetSeconds (New-TestConfig @{ codex = @{ queryTimeoutSeconds = 20; proxy = '' } })
    Assert-Equal 40 $bPlain.seconds 'no proxy: 2 waits x 20 s'
    Assert-Equal 1 $bPlain.attempts 'no proxy: single attempt'
    Assert-Equal 2 $bPlain.waitsPerAttempt 'two JSON-RPC waits per attempt'
    $bProxy = Get-CodexAttemptBudgetSeconds (New-TestConfig @{ codex = @{ queryTimeoutSeconds = 20; proxy = 'http://proxy.invalid:7890' } })
    Assert-Equal 80 $bProxy.seconds 'proxy: the direct fallback doubles the budget'
    Assert-Equal 2 $bProxy.attempts 'proxy: two attempts (CQK-020 never a third)'

    # Anchor exec budget mirrors auto-anchor.ps1 Max(60, timeout*3).
    Assert-Equal 60 (Get-AnchorExecBudgetSeconds (New-TestConfig @{ codex = @{ queryTimeoutSeconds = 20 } })) 'anchor exec floor 60 s'
    Assert-Equal 300 (Get-AnchorExecBudgetSeconds (New-TestConfig @{ codex = @{ queryTimeoutSeconds = 100 } })) 'anchor exec scales with the timeout'

    # Tick budget composition: read, plus exec + verify when anchoring is armed,
    # plus the git budget only when a remote is configured.
    $tickMonitor = Get-CodexTickBudgetSeconds (New-TestConfig @{ mode = 'MonitorOnly'; github = $noCoordCqk; codex = @{ queryTimeoutSeconds = 20 } })
    Assert-Equal 40 $tickMonitor 'MonitorOnly local-only: the poll read alone'
    $tickAa = Get-CodexTickBudgetSeconds (New-TestConfig @{
        mode   = 'AutoAnchor'
        github = $noCoordCqk
        codex  = @{ queryTimeoutSeconds = 20; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0 } }
    })
    Assert-Equal 140 $tickAa 'armed AutoAnchor: read + exec + verify read'
    $tickAaOff = Get-CodexTickBudgetSeconds (New-TestConfig @{
        mode   = 'AutoAnchor'
        github = $noCoordCqk
        codex  = @{ queryTimeoutSeconds = 20; autoAnchor = @{ enabled = $false } }
    })
    Assert-Equal 40 $tickAaOff 'mode=AutoAnchor but autoAnchor disabled: no exec budget'
    $tickSync = Get-CodexTickBudgetSeconds (New-TestConfig @{
        mode   = 'MonitorOnly'
        github = @{ coordination = @{ enabled = $true; repoPath = 'R:\repo' }; historySync = @{ enabled = $false } }
        codex  = @{ queryTimeoutSeconds = 20 }
    })
    Assert-Equal (40 + $script:CQK_GIT_SYNC_BUDGET_SECONDS) $tickSync 'coordination adds the git budget'

    # Derived ExecutionTimeLimit: 10-minute floor, budget, then the poll clamp.
    $limDefault = Get-KeeperTaskExecutionTimeLimit (Get-DefaultConfig)
    Assert-Equal 10 $limDefault.minutes 'shipped defaults get the 10-minute floor'
    Assert-False $limDefault.cappedByPoll 'defaults are not poll-clamped'
    Assert-Equal 10 ([int]$limDefault.timeSpan.TotalMinutes) 'timeSpan matches minutes'
    Assert-Equal 40 $limDefault.budgetSeconds 'default tick budget is one unprefixed read'
    $limProxy = Get-KeeperTaskExecutionTimeLimit (New-TestConfig @{ poll = @{ intervalMinutes = 60 }; github = $noCoordCqk; codex = @{ queryTimeoutSeconds = 180; proxy = 'http://proxy.invalid:7890' } })
    Assert-Equal 720 $limProxy.budgetSeconds 'max timeout x 2 waits x 2 attempts'
    Assert-Equal 12 $limProxy.minutes 'a 12-minute budget raises the limit above the floor'
    Assert-False $limProxy.cappedByPoll 'a 60-minute poll has room'
    # poll=13 with a 720 s budget is legal (12 <= 13) but leaves less than the
    # 2-minute margin, so the clamp wins: limit 11, cappedByPoll true.
    $limCapped = Get-KeeperTaskExecutionTimeLimit (New-TestConfig @{ poll = @{ intervalMinutes = 13 }; github = $noCoordCqk; codex = @{ queryTimeoutSeconds = 180; proxy = 'http://proxy.invalid:7890' } })
    Assert-Equal 0 @(Test-ConfigShape (New-TestConfig @{ poll = @{ intervalMinutes = 13 }; github = $noCoordCqk; codex = @{ queryTimeoutSeconds = 180; proxy = 'http://proxy.invalid:7890' } })).Count 'the clamped config is itself valid (clamp is a warning, not a hard fail)'
    Assert-Equal 11 $limCapped.minutes 'limit clamped to poll - 2 min'
    Assert-True $limCapped.cappedByPoll 'clamp is reported'
    $limShortPoll = Get-KeeperTaskExecutionTimeLimit (New-TestConfig @{ poll = @{ intervalMinutes = 5 }; github = $noCoordCqk; codex = @{ queryTimeoutSeconds = 20 } })
    Assert-Equal 10 $limShortPoll.minutes 'poll shorter than the floor keeps the floor (never a sub-floor limit)'
    Assert-False $limShortPoll.cappedByPoll 'floor branch is not reported as a clamp'

    # The relational half: a config whose worst case exceeds the poll is invalid,
    # and the message names the knob to turn.
    $tight = New-TestConfig @{ poll = @{ intervalMinutes = 10; minimumIntervalMinutes = 5 }; github = $noCoordCqk; codex = @{ queryTimeoutSeconds = 180; proxy = 'http://proxy.invalid:7890' } }
    $tightIssues = @(Test-ConfigShape $tight)
    Assert-True ($tightIssues.Count -ge 1) 'worst-case run longer than the poll rejected'
    Assert-True (($tightIssues -join '; ') -match 'poll\.intervalMinutes') 'rejection names the poll interval'
    Assert-True (($tightIssues -join '; ') -match 'queryTimeoutSeconds') 'rejection names the timeout knob'
    # Boundary: budget exactly filling the poll passes (720 s = 12 min).
    $edgePoll = New-TestConfig @{ poll = @{ intervalMinutes = 12; minimumIntervalMinutes = 5 }; github = $noCoordCqk; codex = @{ queryTimeoutSeconds = 180; proxy = 'http://proxy.invalid:7890' } }
    Assert-Equal 0 @(Test-ConfigShape $edgePoll).Count 'budget exactly filling the poll accepted (boundary)'
    $edgePollOver = New-TestConfig @{ poll = @{ intervalMinutes = 11; minimumIntervalMinutes = 5 }; github = $noCoordCqk; codex = @{ queryTimeoutSeconds = 180; proxy = 'http://proxy.invalid:7890' } }
    Assert-True (@(Test-ConfigShape $edgePollOver).Count -ge 1) 'budget one minute over the poll rejected'
    # AutoAnchor arming raises the requirement: read + exec + verify + git.
    $aaTight = New-TestConfig @{
        mode   = 'AutoAnchor'
        poll   = @{ intervalMinutes = 15; minimumIntervalMinutes = 5 }
        github = @{ coordination = @{ enabled = $true; repoPath = 'R:\repo' }; historySync = @{ enabled = $false } }
        codex  = @{ queryTimeoutSeconds = 100; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0 } }
    }
    Assert-True (@(Test-ConfigShape $aaTight).Count -ge 1) 'anchoring + sync overruns the default 15-min test poll'
    $aaOk = New-TestConfig @{
        mode   = 'AutoAnchor'
        poll   = @{ intervalMinutes = 60; minimumIntervalMinutes = 5 }
        leader = @{ leaseTtlMinutes = 180 }
        github = @{ coordination = @{ enabled = $true; repoPath = 'R:\repo' }; historySync = @{ enabled = $false } }
        codex  = @{ queryTimeoutSeconds = 100; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0 } }
    }
    Assert-Equal 0 @(Test-ConfigShape $aaOk).Count 'the same config with a 60-minute poll is valid'
    Assert-Equal 940 (Get-CodexTickBudgetSeconds $aaOk) 'anchored + synced worst case: 200 read + 300 exec + 200 verify + 240 git'

    Start-TestGroup 'config: autoAnchor.enabled=true requires mode=AutoAnchor'

    $bad2 = New-TestConfig @{ codex = @{ autoAnchor = @{ enabled = $true } } }
    [void](Write-TestConfigFile $cfgFile $bad2)
    $loaded3 = Load-Config $cfgFile
    Assert-True (@($loaded3.issues).Count -ge 1) 'autoAnchor without AutoAnchor mode rejected'

    Start-TestGroup 'config: keepalive interval validation'

    $kaOk = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 240 } }
    }
    [void](Write-TestConfigFile $cfgFile $kaOk)
    $lkaOk = Load-Config $cfgFile
    Assert-Equal 0 @($lkaOk.issues).Count 'keepalive >= minimumGap accepted'
    Assert-Equal 240 (Get-AutoAnchorConfig $lkaOk.config).keepaliveIntervalMinutes 'keepalive interval parsed'

    $kaBelow = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 30 } }
    }
    [void](Write-TestConfigFile $cfgFile $kaBelow)
    $lkaBelow = Load-Config $cfgFile
    Assert-True (@($lkaBelow.issues).Count -ge 1) 'keepalive below minimumGap rejected'

    $kaOff = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0 } }
    }
    [void](Write-TestConfigFile $cfgFile $kaOff)
    $lkaOff = Load-Config $cfgFile
    Assert-Equal 0 @($lkaOff.issues).Count 'keepalive=0 (off) accepted'

    Start-TestGroup 'config: daily schedule validation (timer mode)'

    $schOk = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 300; keepaliveIntervalMinutes = 0; schedule = @('09:30', '21:00') } }
    }
    [void](Write-TestConfigFile $cfgFile $schOk)
    $lschOk = Load-Config $cfgFile
    Assert-Equal 0 @($lschOk.issues).Count 'schedule of zero-padded HH:mm accepted'
    Assert-Equal 2 @( (Get-AutoAnchorConfig $lschOk.config).schedule ).Count 'schedule slots parsed'
    Assert-Equal '21:00' @( (Get-AutoAnchorConfig $lschOk.config).schedule )[1] 'slot order preserved'

    $schDup = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 300; keepaliveIntervalMinutes = 0; schedule = @('09:30', '09:30', '21:00') } }
    }
    [void](Write-TestConfigFile $cfgFile $schDup)
    $lschDup = Load-Config $cfgFile
    Assert-Equal 0 @($lschDup.issues).Count 'duplicate slots accepted'
    Assert-Equal 2 @( (Get-AutoAnchorConfig $lschDup.config).schedule ).Count 'duplicate slots deduplicated'

    $schBadFmt = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 300; keepaliveIntervalMinutes = 0; schedule = @('9:30') } }
    }
    [void](Write-TestConfigFile $cfgFile $schBadFmt)
    $lschBad = Load-Config $cfgFile
    Assert-True (@($lschBad.issues).Count -ge 1) 'slot without zero padding rejected'

    $schBadHour = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 300; keepaliveIntervalMinutes = 0; schedule = @('25:00') } }
    }
    [void](Write-TestConfigFile $cfgFile $schBadHour)
    $lschBad2 = Load-Config $cfgFile
    Assert-True (@($lschBad2.issues).Count -ge 1) 'slot hour out of range rejected'

    $schMany = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 2; minimumGapMinutes = 300; keepaliveIntervalMinutes = 0; schedule = @('09:00', '12:00', '18:00') } }
    }
    [void](Write-TestConfigFile $cfgFile $schMany)
    $lschMany = Load-Config $cfgFile
    Assert-True (@($lschMany.issues).Count -ge 1) 'more slots than maxPerDay rejected'

    Start-TestGroup 'config: anchor model / reasoning effort validation'

    $modelOk = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0; model = 'gpt-5-codex'; reasoningEffort = 'low' } }
    }
    [void](Write-TestConfigFile $cfgFile $modelOk)
    $lmOk = Load-Config $cfgFile
    Assert-Equal 0 @($lmOk.issues).Count 'anchor model + reasoningEffort accepted'
    $aaParsed = Get-AutoAnchorConfig $lmOk.config
    Assert-Equal 'gpt-5-codex' $aaParsed.model 'model parsed'
    Assert-Equal 'low' $aaParsed.reasoningEffort 'reasoningEffort parsed'

    $modelEmpty = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0; model = ''; reasoningEffort = '' } }
    }
    [void](Write-TestConfigFile $cfgFile $modelEmpty)
    $lmEmpty = Load-Config $cfgFile
    Assert-Equal 0 @($lmEmpty.issues).Count 'empty model/effort accepted (defaults apply)'

    $modelBad = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0; model = 'gpt 5 codex'; reasoningEffort = 'low' } }
    }
    [void](Write-TestConfigFile $cfgFile $modelBad)
    $lmBad = Load-Config $cfgFile
    Assert-True (@($lmBad.issues).Count -ge 1) 'model with whitespace rejected'

    $effortBad = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0; model = 'gpt-5-codex'; reasoningEffort = 'super high' } }
    }
    [void](Write-TestConfigFile $cfgFile $effortBad)
    $leBad = Load-Config $cfgFile
    Assert-True (@($leBad.issues).Count -ge 1) 'reasoningEffort with whitespace rejected'

    $effortShell = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = ''; }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0; reasoningEffort = 'low&calc' } }
    }
    [void](Write-TestConfigFile $cfgFile $effortShell)
    $leShell = Load-Config $cfgFile
    Assert-True (@($leShell.issues).Count -ge 1) 'reasoningEffort with shell metacharacters rejected'

    $effortUpper = New-TestConfig @{
        mode   = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0; reasoningEffort = 'Medium' } }
    }
    [void](Write-TestConfigFile $cfgFile $effortUpper)
    $leUpper = Load-Config $cfgFile
    Assert-True (@($leUpper.issues).Count -ge 1) 'reasoningEffort uppercase rejected (CLI takes lowercase tokens)'

    Start-TestGroup 'config: coordination enabled without repoPath rejected'

    $bad3 = New-TestConfig @{ github = @{ coordination = @{ enabled = $true; repoPath = '' } } }
    [void](Write-TestConfigFile $cfgFile $bad3)
    $loaded4 = Load-Config $cfgFile
    Assert-True (@($loaded4.issues).Count -ge 1) 'missing repoPath rejected'

    Start-TestGroup 'config: proxy URL validation'

    $noProxy = New-TestConfig @{
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ proxy = '' }
    }
    [void](Write-TestConfigFile $cfgFile $noProxy)
    $lNone = Load-Config $cfgFile
    Assert-Equal 0 @($lNone.issues).Count 'proxy-off config valid'
    Assert-Equal 0 @((Get-CodexProxyEnvironment $lNone.config).Keys).Count 'no proxy env when proxy is off'

    $goodProxy = New-TestConfig @{
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ proxy = 'http://127.0.0.1:7890' }
    }
    [void](Write-TestConfigFile $cfgFile $goodProxy)
    $lp = Load-Config $cfgFile
    Assert-Equal 0 @($lp.issues).Count 'http proxy URL accepted'
    Assert-Equal 'http://127.0.0.1:7890' (Get-ProxyConfig $lp.config).url 'proxy url preserved'
    $pOn = Get-CodexProxyEnvironment $lp.config
    Assert-Equal 'http://127.0.0.1:7890' $pOn['HTTPS_PROXY'] 'HTTPS_PROXY set'
    Assert-Equal 'http://127.0.0.1:7890' $pOn['ALL_PROXY'] 'ALL_PROXY set'
    Assert-Equal 3 @($pOn.Keys).Count 'exactly three proxy env keys'

    $socksProxy = New-TestConfig @{
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ proxy = 'socks5://127.0.0.1:7891' }
    }
    [void](Write-TestConfigFile $cfgFile $socksProxy)
    $ls5 = Load-Config $cfgFile
    Assert-Equal 0 @($ls5.issues).Count 'socks5 proxy URL accepted'
    $ps5 = Get-CodexProxyEnvironment $ls5.config
    Assert-Equal 'socks5://127.0.0.1:7891' $ps5['ALL_PROXY'] 'socks5 ALL_PROXY set'

    $socksHProxy = New-TestConfig @{
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ proxy = 'socks5h://127.0.0.1:7891' }
    }
    [void](Write-TestConfigFile $cfgFile $socksHProxy)
    $ls5h = Load-Config $cfgFile
    Assert-Equal 0 @($ls5h.issues).Count 'socks5h proxy URL accepted'

    $badProxy = New-TestConfig @{ codex = @{ proxy = 'not a url' } }
    [void](Write-TestConfigFile $cfgFile $badProxy)
    $lpb = Load-Config $cfgFile
    Assert-True (@($lpb.issues).Count -ge 1) 'malformed proxy URL rejected'

    $ftpProxy = New-TestConfig @{ codex = @{ proxy = 'ftp://example.com:21' } }
    [void](Write-TestConfigFile $cfgFile $ftpProxy)
    $lpf = Load-Config $cfgFile
    Assert-True (@($lpf.issues).Count -ge 1) 'non-http(s) proxy scheme rejected'

    Start-TestGroup 'config: JSONC comments accepted (config.example.jsonc template)'

    $jsonc = @'
{
  // 行注释：被注释的键不会覆盖默认值
  "schemaVersion": 2, /* 块注释 */
  "mode": "MonitorOnly",
  "poll": {
    // "intervalMinutes": 1,        // 注释掉的非法值应被忽略，使用默认 60
    "intervalMinutes": 45,        // 行尾注释
    "minimumIntervalMinutes": 5
  },
  "github": {
    "coordination": { "enabled": false /* 多机可取消注释改 true */ },
    "historySync": { "enabled": false }
  },
  "codex": {
    "proxy": "http://127.0.0.1:7890",
    "autoAnchor": { "prompt": "say \"OK\" // keep this" }
  }
}
'@
    [System.IO.File]::WriteAllText($cfgFile, $jsonc, (New-Object System.Text.UTF8Encoding($false)))
    $ljc = Load-Config $cfgFile
    Assert-Equal 0 @($ljc.issues).Count 'JSONC config valid'
    Assert-Equal 45 $ljc.config.poll.intervalMinutes 'uncommented override applied'
    Assert-Equal 'http://127.0.0.1:7890' $ljc.config.codex.proxy '// inside string (URL) preserved'
    Assert-Equal 'say "OK" // keep this' (Get-AutoAnchorConfig $ljc.config).prompt 'escaped quote and // inside string preserved'
    Assert-False ([bool]$ljc.config.github.coordination.enabled) 'disabled coordination stays off'

    $jsoncMin = @'
{
  // 只有注释的最小模板：所有字段应回落到内置默认值
  "schemaVersion": 2,
  "mode": "MonitorOnly",
  "poll": {
    // "intervalMinutes": 1,
  },
  "leader": {
    /* "label": "X" */
  },
  "github": { "coordination": {}, "historySync": {} }
}
'@
    [System.IO.File]::WriteAllText($cfgFile, $jsoncMin, (New-Object System.Text.UTF8Encoding($false)))
    $ljcMin = Load-Config $cfgFile
    Assert-Equal 0 @($ljcMin.issues).Count 'minimal JSONC config valid'
    Assert-Equal 60 $ljcMin.config.poll.intervalMinutes 'commented-out value leaves default intact'
    Assert-Equal 'Home PC' $ljcMin.config.leader.label 'commented-out label leaves default intact'

    Start-TestGroup 'config: legacy v1 keys map onto v2 schema'

    $legacyJson = @'
{
  "schemaVersion": 1,
  "mode": "MonitorOnly",
  "pollIntervalMinutes": 30,
  "minimumPollIntervalMinutes": 10,
  "leader": { "enabled": true, "leaseTtlMinutes": 90, "graceMinutes": 5, "label": "Legacy PC" },
  "codex": { "command": "auto", "queryTimeoutSeconds": 20, "autoAnchor": false, "anchorPrompt": "p", "maxAnchorsPerDay": 4, "minimumAnchorGapMinutes": 30 },
  "github": { "enabled": true, "repoPath": "D:/logrepo", "coordinationBranch": "coordination", "historyBranch": "history", "syncEventsOnly": true, "push": true },
  "logging": { "retentionDays": 30, "includeMachineLabel": true },
  "task": { "name": "LegacyTask", "startWithWindows": true, "runIfNetworkAvailable": true, "wakeToRun": false }
}
'@
    [System.IO.File]::WriteAllText($cfgFile, $legacyJson, (New-Object System.Text.UTF8Encoding($false)))
    $legacy = Load-Config $cfgFile
    Assert-Equal 0 @($legacy.issues).Count 'legacy config valid after mapping'
    Assert-Equal 30 $legacy.config.poll.intervalMinutes 'pollIntervalMinutes mapped'
    Assert-Equal 10 $legacy.config.poll.minimumIntervalMinutes 'minimumPollIntervalMinutes mapped'
    Assert-True ([bool]$legacy.config.github.coordination.enabled) 'github.enabled -> coordination.enabled'
    Assert-Equal 'D:/logrepo' $legacy.config.github.coordination.repoPath 'repoPath mapped'
    Assert-Equal 'coordination' $legacy.config.github.coordination.branch 'coordinationBranch mapped'
    Assert-Equal 'history' $legacy.config.github.historySync.branch 'historyBranch mapped'
    Assert-False ([bool]$legacy.config.codex.autoAnchor.enabled) 'legacy autoAnchor=false mapped'
    Assert-Equal 4 $legacy.config.codex.autoAnchor.maxPerDay 'maxAnchorsPerDay mapped'
    Assert-Equal 2 $legacy.config.schemaVersion 'schema upgraded to 2'

    Start-TestGroup 'config: invalid JSON / missing file handled'

    [System.IO.File]::WriteAllText($cfgFile, '{ not json', (New-Object System.Text.UTF8Encoding($false)))
    $loaded5 = Load-Config $cfgFile
    Assert-True (@($loaded5.issues).Count -ge 1) 'invalid JSON reported'
    $loaded6 = Load-Config (Join-Path $ws 'nope.json')
    Assert-True (@($loaded6.issues).Count -ge 1) 'missing config reported'
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'machine identity: stable random id, label update'

$ws = New-TestWorkspace
try {
    $m1 = Get-MachineIdentity -Root $ws -Label 'Home PC'
    $m2 = Get-MachineIdentity -Root $ws -Label 'Home PC'
    Assert-Equal $m1.machineId $m2.machineId 'machineId stable across calls'
    $parsed = [guid]::Empty
    Assert-True ([guid]::TryParse([string]$m1.machineId, [ref]$parsed)) 'machineId is a GUID'
    $m3 = Get-MachineIdentity -Root $ws -Label 'Office PC'
    Assert-Equal $m1.machineId $m3.machineId 'id survives label change'
    Assert-Equal 'Office PC' $m3.label 'label updated on request'
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'backoff: set/expiry/clear'

$ws = New-TestWorkspace
try {
    Assert-False (Test-InBackoff $ws) 'no backoff initially'
    Set-Backoff -Root $ws -Minutes 60 -Reason '429'
    Assert-True (Test-InBackoff $ws) 'backoff active after set'
    $state = Get-BackoffState $ws
    Assert-Equal '429' $state.reason 'backoff reason recorded'
    Clear-Backoff $ws
    Assert-False (Test-InBackoff $ws) 'backoff cleared'
    Set-Backoff -Root $ws -Minutes (-1) -Reason 'past'
    Assert-False (Test-InBackoff $ws) 'expired backoff treated as inactive'
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'sanitization: credentials never reach output'

$leaky = 'token=abc12345 refresh_token: "xyz-98765432" Authorization: Bearer sk-proj-abcdef123456 cookie=sessionid=zzz; keep-this'
$clean = Hide-SensitiveText $leaky
Assert-False ($clean -match 'abc12345') 'token value removed'
Assert-False ($clean -match 'xyz-98765432') 'refresh token removed'
Assert-False ($clean -match 'sk-proj-abcdef') 'openai key removed'
Assert-True ($clean -match 'keep-this') 'benign content preserved'

$rec = Sanitize-Record @{
    ts = 't'; event = 'E'; machineId = 'm'; windows = @(); error = 'token=abc12345';
    prompt = 'MUST NOT LEAK'; authJson = 'MUST NOT LEAK'; session = 'MUST NOT LEAK'
}
Assert-Null $rec.prompt 'non-allowlisted key dropped'
Assert-Null $rec.authJson 'authJson dropped from history records'
Assert-False ("$($rec.error)" -match 'abc12345') 'error text sanitized'

Start-TestGroup 'sha256: deterministic hex digest'

$h1 = Get-Sha256Hex '300|1788062400|reset'
$h2 = Get-Sha256Hex '300|1788062400|reset'
$h3 = Get-Sha256Hex '300|1788062401|reset'
Assert-Equal $h1 $h2 'same input same hash'
Assert-True ($h1 -match '^[0-9a-f]{64}$') 'sha256 hex format'
Assert-True ($h1 -ne $h3) 'different input different hash'

Start-TestGroup 'json: atomic write + roundtrip + jsonl'

$ws = New-TestWorkspace
try {
    $obj = @{ a = 1; nested = @{ list = @(1, 2, 3) } }
    $p = Join-Path $ws 'sub\state.json'
    Write-JsonFileAtomic $p $obj
    $back = Read-JsonFile $p
    Assert-Equal 1 $back.a 'atomic write roundtrip'
    Assert-Equal 3 @($back.nested.list).Count 'nested structure preserved'

    $jl = Join-Path $ws 'logs\runner.jsonl'
    Write-JsonLine $jl @{ event = 'A' }
    Write-JsonLine $jl @{ event = 'B' }
    $lines = [System.IO.File]::ReadAllLines($jl)
    Assert-Equal 2 @($lines).Count 'two jsonl lines'
    Assert-Equal 'B' (ConvertFrom-JsonSafe $lines[1]).event 'jsonl line parses'

    $noTmpLeft = Get-ChildItem -LiteralPath $ws -Filter '*.tmp-*' -Recurse -Force
    Assert-Equal 0 @($noTmpLeft).Count 'no temp files left behind'
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'runner lock: second acquisition blocked, released on exit'

$ws = New-TestWorkspace
try {
    $lock1 = Enter-RunnerLock $ws
    Assert-True $lock1.acquired 'first lock acquired'
    $lock2 = Enter-RunnerLock $ws
    Assert-False $lock2.acquired 'second lock denied while held'
    Exit-RunnerLock $ws
    $lock3 = Enter-RunnerLock $ws
    Assert-True $lock3.acquired 'lock re-acquired after release'
    Exit-RunnerLock $ws

    Start-TestGroup 'runner lock: stale lock file from dead pid is broken'

    $lockPath = Join-Path (Get-LockDir $ws) 'runner.lock'
    Write-JsonFileAtomic $lockPath @{ pid = 99999999; startedAt = '2000-01-01T00:00:00+00:00' }
    $lock4 = Enter-RunnerLock $ws
    Assert-True $lock4.acquired 'stale lock file broken and replaced'
    Exit-RunnerLock $ws
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'time: iso timestamps and epoch roundtrip'

$now = Get-Date
$iso = Get-IsoTimestamp
Assert-True ($iso -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$') 'iso format with offset'
$epoch = ConvertTo-EpochSeconds $now
$round = ConvertFrom-EpochSeconds $epoch
Assert-True ([Math]::Abs(($round - $now).TotalSeconds) -lt 2) 'epoch roundtrip within 2s'

Start-TestGroup 'launcher: Resolve-ExecutableLaunchSpec (CQK-004)'

$testsDir2 = Split-Path -Parent $MyInvocation.MyCommand.Path
$spec = Resolve-ExecutableLaunchSpec -Executable 'C:\Tools\codex.exe' -ArgumentList @('app-server')
Assert-Equal 'C:\Tools\codex.exe' $spec.exe 'exe runs directly'
Assert-Equal 'app-server' $spec.args[0] 'exe args preserved'

$spec = Resolve-ExecutableLaunchSpec -Executable 'C:\Tools\mock.ps1' -ArgumentList @('app-server')
Assert-True ("$($spec.exe)" -match 'pwsh|powershell') 'ps1 runs through powershell'
Assert-True ($spec.args -contains '-NoProfile') 'ps1 launched with -NoProfile'
Assert-True ($spec.args -contains 'C:\Tools\mock.ps1') 'ps1 script path in args'

$spec = Resolve-ExecutableLaunchSpec -Executable 'C:\Tools\codex.cmd' -ArgumentList @('app-server')
Assert-True ("$($spec.exe)" -match 'cmd\.exe$') 'cmd wrapped in ComSpec'
Assert-Equal '/d /s /c ""C:\Tools\codex.cmd" "app-server"""' "$($spec.rawArgs)" 'cmd raw command line double-quoted for /s'

Start-TestGroup 'anchor exec: Get-AnchorExecCommand model/effort passthrough'

# Direct unit test of the exec argument builder: model and reasoningEffort must
# land as '-m <model>' / '-c model_reasoning_effort=<effort>' when configured,
# and be entirely absent when left empty (current behavior unchanged).
$anchorSpecOff = Get-AnchorExecCommand -CodexPath 'C:\Tools\codex.cmd' -Prompt 'Reply exactly OK.'
$offRaw = "$($anchorSpecOff.rawArgs)"
Assert-True ($offRaw -match 'exec') 'plain anchor still runs exec'
Assert-False ($offRaw -match '-m ') 'no -m flag when model unset'
Assert-False ($offRaw -match 'model_reasoning_effort') 'no effort override when reasoningEffort unset'

$anchorSpecFull = Get-AnchorExecCommand -CodexPath 'C:\Tools\codex.cmd' -Prompt 'Reply exactly OK.' -Model 'gpt-5-codex' -ReasoningEffort 'low'
$fullRaw = "$($anchorSpecFull.rawArgs)"
Assert-True ($fullRaw -match '"-m" "gpt-5-codex"') 'model passed as -m argument'
Assert-True ($fullRaw -match 'model_reasoning_effort=low') 'effort passed as -c model_reasoning_effort=low'
# flag order: model/effort overrides go before the prompt so the prompt stays
# the last positional argument
$promptIdx = $fullRaw.IndexOf('Reply exactly OK.')
$mIdx = $fullRaw.IndexOf('"-m"')
Assert-True ($mIdx -lt $promptIdx) 'model flag precedes the prompt argument'

$anchorSpecEffortOnly = Get-AnchorExecCommand -CodexPath 'C:\Tools\codex.cmd' -Prompt 'Reply exactly OK.' -ReasoningEffort 'minimal'
$effortOnlyRaw = "$($anchorSpecEffortOnly.rawArgs)"
Assert-False ($effortOnlyRaw -match '-m ') 'no -m when only effort configured'
Assert-True ($effortOnlyRaw -match 'model_reasoning_effort=minimal') 'effort-only override applied'

$spec = Resolve-ExecutableLaunchSpec -Executable 'pwsh' -ArgumentList @('-NoProfile')
Assert-NotNull $spec 'PATH-resolved executable'
Assert-True ("$($spec.exe)" -match 'pwsh') 'PATH resolution recursed to exe'

Assert-Null (Resolve-ExecutableLaunchSpec -Executable 'no-such-exe-xyz-abc') 'unknown command returns null'

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "common.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
