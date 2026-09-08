# Unified AutoAnchor claim store tests (design doc v2.0, CQK-023).
#
# The point of the ticket is that LOCAL_ONLY now has a DURABLE at-most-once
# artifact, so the tests centre on the crash window that used to double-bill:
#   1. the local record shape (8 keys, both backings identical)
#   2. exclusive create -> any pre-existing claim blocks, all four states
#   3. the crash-window regression through runner.ps1 (CLAIMED survives, the
#      next tick aborts, zero model calls)
#   4. COMPLETED is written before state.processedEventIds is persisted - if a
#      peer's claim lands in that ordering gap, this machine must still deny
#   5. fail-closed when the store itself is unreadable
#   6. finalize cannot resurrect an expired or terminal claim
#   7. retention sweeps terminal files and NEVER a CLAIMED one
#   8. two real processes racing one CreateNew -> exactly one winner
#   9. unified face routes to the right backing; both share the denial wording
#  10. distributed regression (same semantics, Git CAS backing)
# No real credentials; git only, against a local bare origin.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')
. (Join-Path $scriptDir 'logger.ps1')
. (Join-Path $scriptDir 'state-machine.ps1')
. (Join-Path $scriptDir 'auto-anchor.ps1')
. (Join-Path $scriptDir 'anchor-claim.ps1')

$pwsh = (Get-Process -Id $PID).Path
$runnerPath = Join-Path $scriptDir 'runner.ps1'
$mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'
$machine = @{ machineId = 'CLAIM-A'; label = 'Claim A' }

function Invoke-RunnerSub {
    param([string]$KeeperRoot, [string]$ConfigFile, [switch]$ForceAnchor)
    $subArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath, '-KeeperRoot', $KeeperRoot, '-ConfigFile', $ConfigFile)
    if ($ForceAnchor) { $subArgs += '-ForceAnchor' }
    $out = & $pwsh @subArgs 2>&1
    return @{ exitCode = $LASTEXITCODE; output = ($out | Out-String) }
}

function Get-LogEventNames {
    param([string]$KeeperRoot)
    $names = @()
    Get-ChildItem -LiteralPath (Join-Path $KeeperRoot 'runtime\logs') -Filter 'keeper-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $names += @(([System.IO.File]::ReadAllLines($_.FullName)) | ForEach-Object { (ConvertFrom-JsonSafe $_).event })
    }
    return $names
}

function Get-AnchorAbortReasons {
    # The denial text lands in the runner log's `error` field and in the local
    # history copy (history is sanitized, so only `error`/`anchor` survive).
    param([string]$KeeperRoot)
    $reasons = @()
    $dirs = @((Join-Path $KeeperRoot 'runtime\logs'), (Get-HistoryDir $KeeperRoot))
    foreach ($d in $dirs) {
        Get-ChildItem -LiteralPath $d -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($line in [System.IO.File]::ReadAllLines($_.FullName)) {
                $rec = ConvertFrom-JsonSafe $line
                if ($null -eq $rec) { continue }
                if ([string]$rec.event -ne 'ANCHOR_ABORTED') { continue }
                $reasons += [string]$rec.error
                if ($null -ne $rec.anchor) { $reasons += [string]$rec.anchor.reason }
            }
        }
    }
    return ($reasons | Where-Object { $_ })
}

function ConvertTo-TestInstant {
    # PS7's ConvertFrom-Json turns ISO-looking strings into DateTime, and [string]
    # of a DateTime is locale-dependent (observed on zh-CN hosts). Normalize
    # through ConvertTo-IsoString, then parse invariantly.
    param($Value)
    $dto = [DateTimeOffset]::MinValue
    $text = ConvertTo-IsoString $Value
    if ([DateTimeOffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$dto)) { return $dto }
    return $null
}

function Get-ReasonText {
    # Assertion helper: a denial reason as plain text (never $null, never an array).
    param($Result)
    return [string]$Result.reason
}

function New-LocalAutoAnchorConfig {
    # LOCAL_ONLY (no coordination repo) + the idle trigger. minimumGapMinutes is
    # deliberately larger than a test run: with anchors.lastAnchorAt cleared the
    # gap is not consulted, so the ONLY thing that can block the next tick is the
    # durable claim file - which is exactly the guarantee under test.
    param([string]$KeeperRoot, [int]$RetentionDays = 90)
    $cfgFile = Join-Path $KeeperRoot 'config.json'
    $cfg = New-TestConfig @{
        mode    = 'AutoAnchor'
        codex   = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 300; keepaliveIntervalMinutes = 0 } }
        github  = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
        logging = @{ retentionDays = $RetentionDays; includeMachineLabel = $false }
    }
    $null = Write-TestConfigFile $cfgFile $cfg
    return @{ config = $cfg; path = $cfgFile }
}

$ws = New-TestWorkspace
try {
    # =====================================================================
    Start-TestGroup 'claim: LOCAL_ONLY record shape - state, owner and a parseable result before exec'

    $rootA = Join-Path $ws 'shape'
    New-Item -ItemType Directory -Path $rootA -Force | Out-Null
    $evShape = Get-Sha256Hex 'claim-shape|1'
    $claim1 = Claim-AnchorClaim -KeeperRoot $rootA -EventId $evShape -Machine $machine -ClaimMinutes 20 -LocalOnly $true
    Assert-True $claim1.ok "local claim ok ($($claim1.reason))"
    $pathShape = Get-AnchorClaimPath -Root $rootA -EventId $evShape
    Assert-True (Test-Path -LiteralPath $pathShape) 'CLAIMED file exists next to the other runtime artifacts'

    # Read through .NET, not ConvertFrom-Json: PS7 turns ISO-looking strings into
    # DateTime and the shape assertions below would compare the wrong types.
    $recShape = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText($pathShape))
    Assert-True ($recShape -is [hashtable]) 'claim record parses as an object'
    Assert-Equal 1 $recShape.schema 'schemaVersion 1'
    Assert-Equal $evShape $recShape.eventId 'eventId recorded'
    Assert-Equal 'CLAIMED' $recShape.state 'state CLAIMED'
    Assert-Equal 'CLAIM-A' $recShape.ownerId 'ownerId is our machine id'
    Assert-Equal 'runtime\anchor-claims' $pathShape.Substring($rootA.Length + 1, 'runtime\anchor-claims'.Length) 'claims live under runtime/anchor-claims'
    $expShape = ConvertTo-TestInstant $recShape.claimExpiresAt
    Assert-NotNull $expShape 'claimExpiresAt is a parseable ISO instant'
    Assert-True ($expShape -gt (ConvertTo-TestInstant $recShape.claimedAt)) 'claim expiry is strictly after the claim'
    Assert-True ($null -eq $recShape.completedAt) 'no completedAt while still CLAIMED'

    # A reason string that is itself JSON must come back as ONE string. Anchor
    # reasons carry exec diagnostics, so this is the realistic shape; ConvertTo-Json
    # -Depth 12 used to expand it into an object.
    $evJsonish = Get-Sha256Hex 'claim-jsonish|1'
    $null = Claim-AnchorClaim -KeeperRoot $rootA -EventId $evJsonish -Machine $machine -ClaimMinutes 20 -LocalOnly $true
    $fJsonish = Get-AnchorClaimPath -Root $rootA -EventId $evJsonish
    $nested = '{"windows":{"primary":{"usedPercent":0}}}'
    $null = Finalize-LocalAnchorEvent -KeeperRoot $rootA -EventId $evJsonish -Machine $machine -State 'FAILED' -Result $nested
    $recJsonish = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText($fJsonish))
    Assert-True ($recJsonish.result -is [string]) 'a JSON-shaped result string stays a string'
    Assert-Equal $nested $recJsonish.result 'result round-trips verbatim'

    # =====================================================================
    Start-TestGroup 'claim: any pre-existing claim blocks the next attempt, all four states'

    foreach ($st in @('CLAIMED', 'COMPLETED', 'FAILED', 'EXPIRED')) {
        $ev = Get-Sha256Hex ("block|$st|1")
        $null = Claim-AnchorClaim -KeeperRoot $rootA -EventId $ev -Machine $machine -ClaimMinutes 20 -LocalOnly $true
        if ($st -ne 'CLAIMED') {
            $null = Finalize-LocalAnchorEvent -KeeperRoot $rootA -EventId $ev -Machine $machine -State $st -Result "seeded $st"
        }
        $again = Claim-AnchorClaim -Config (New-TestConfig @{}) -KeeperRoot $rootA -EventId $ev -Machine $machine -ClaimMinutes 20 -LocalOnly $true
        Assert-False $again.ok "$st blocks a second attempt"
        $why = Get-ReasonText $again
        Assert-True ($why -like "event already $st*") "$st denial names the state (got: $why)"
        Assert-True ($why -like '*no retry*') "$st denial says no retry"
        Assert-True ($why.StartsWith('event already ')) "$st denial is a claim denial, not a create failure"
        $recNow = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText((Get-AnchorClaimPath -Root $rootA -EventId $ev)))
        Assert-Equal $st $recNow.state "$st record not overwritten by the denied attempt"
    }

    # =====================================================================
    Start-TestGroup 'claim: crash window - a CLAIMED left by a dead run aborts the next tick with zero model calls'

    $rootB = Join-Path $ws 'crash'
    New-Item -ItemType Directory -Path $rootB -Force | Out-Null
    $cB = New-LocalAutoAnchorConfig -KeeperRoot $rootB
    $execArgsB = Join-Path $ws 'exec-args-crash.txt'
    $env:CQK_MOCK_MODE = 'idle'
    $env:CQK_MOCK_EXEC = 'ok'
    $env:CQK_MOCK_EXEC_ARGS_FILE = $execArgsB

    $rB1 = Invoke-RunnerSub -KeeperRoot $rootB -ConfigFile $cB.path
    Assert-Equal 0 $rB1.exitCode "baseline run ok ($($rB1.output))"
    Assert-False (Test-Path -LiteralPath (Get-AnchorClaimsDir $rootB)) 'baseline poll creates no claim (guard denies first)'
    Assert-False (Test-Path -LiteralPath $execArgsB) 'baseline poll never reaches the CLI'

    $rB2 = Invoke-RunnerSub -KeeperRoot $rootB -ConfigFile $cB.path
    Assert-Equal 0 $rB2.exitCode "second observation ok ($($rB2.output))"
    $evtsB2 = Get-LogEventNames $rootB
    Assert-Contains $evtsB2 'ANCHOR_LOCAL' 'idle run took the local claim path'
    Assert-Contains $evtsB2 'ANCHOR_EXECUTED' 'idle run anchored'
    # Take the eventId from the artifact the run actually wrote rather than
    # recomputing it: the idle slot is day-scoped, so recomputing across local
    # midnight would point at a different file.
    $filesB2 = @(Get-ChildItem -LiteralPath (Get-AnchorClaimsDir $rootB) -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-Equal 1 $filesB2.Count 'exactly one claim file per anchor'
    $claimPathB = $filesB2[0].FullName
    $recB2 = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText($claimPathB))
    Assert-Equal 'COMPLETED' $recB2.state 'verified anchor finalizes COMPLETED'
    Assert-True ($null -eq $recB2.result) 'a clean COMPLETED carries no failure reason'

    # Simulate the crash: a previous process wrote CLAIMED and died before finalizing.
    $claimPathB2 = Join-Path $ws 'crash-sim-COMPLETED.json'
    Move-Item -LiteralPath $claimPathB -Destination $claimPathB2 -Force
    Remove-Item -LiteralPath $execArgsB -Force -ErrorAction SilentlyContinue
    $stB = Read-JsonFile (Get-StatePath $rootB)
    $stB.anchors = @{ day = ''; count = 0; lastAnchorAt = $null }
    $stB.processedEventIds = @()
    Save-KeeperState -Root $rootB -State $stB
    $recCrash = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText($claimPathB2))
    $null = Ensure-Directory (Split-Path -Parent $claimPathB)
    Write-AnchorClaimRecordJson -Path $claimPathB -Record @{
        schema = 1; eventId = $recCrash.eventId; state = 'CLAIMED'; ownerId = 'DEAD-PID'
        claimedAt = $recCrash.claimedAt; claimExpiresAt = $recCrash.claimExpiresAt; completedAt = $null; result = 'simulated crash between exec and persist'
    }

    $rB3 = Invoke-RunnerSub -KeeperRoot $rootB -ConfigFile $cB.path
    Assert-Equal 0 $rB3.exitCode "post-crash run ok ($($rB3.output))"
    $evtsB3 = Get-LogEventNames $rootB
    Assert-Contains $evtsB3 'ANCHOR_ABORTED' 'the stale CLAIMED aborts the next tick'
    # The keeper log is append-only for the whole day, so the proof is a count, not
    # an absence: the baseline anchor run already left one of each of these.
    Assert-Equal 1 @($evtsB3 | Where-Object { $_ -eq 'ANCHOR_LOCAL' }).Count 'never entered the anchor path: nothing claimed'
    Assert-Equal 1 @($evtsB3 | Where-Object { $_ -eq 'ANCHOR_EXECUTED' }).Count 'no second anchor after a crash'
    Assert-False (Test-Path -LiteralPath $execArgsB) 'zero model calls - the duplicate billing is what this prevents'
    $reasonsB3 = @(Get-AnchorAbortReasons $rootB)
    Assert-True (@($reasonsB3 | Where-Object { $_ -match 'already CLAIMED' }).Count -ge 1) "denial names CLAIMED (got: $($reasonsB3 -join ' | '))"
    Assert-True (@($reasonsB3 | Where-Object { $_ -match 'DEAD-PID' }).Count -ge 1) 'denial names the crashed owner'
    $stB3 = Read-JsonFile (Get-StatePath $rootB)
    Assert-Equal 0 $stB3.anchors.count 'anchors counter untouched by the aborted attempt'
    $recB3 = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText($claimPathB))
    Assert-Equal 'CLAIMED' $recB3.state 'the aborted attempt does not rewrite the stale claim'
    Assert-Equal 'DEAD-PID' $recB3.ownerId 'stale owner preserved for the operator'

    # Retention must not clean this up either: it is the blocker, not litter.
    $null = Invoke-AnchorClaimRetention -KeeperRoot $rootB -RetentionDays 1
    Assert-True (Test-Path -LiteralPath $claimPathB) 'retention keeps the CLAIMED blocker'

    # =====================================================================
    Start-TestGroup 'claim: completion ordering - a peer claim landing between exec and state save is still denied'

    $rootC = Join-Path $ws 'ordering'
    New-Item -ItemType Directory -Path $rootC -Force | Out-Null
    $cC = New-LocalAutoAnchorConfig -KeeperRoot $rootC
    $env:CQK_MOCK_MODE = 'idle'
    $rC1 = Invoke-RunnerSub -KeeperRoot $rootC -ConfigFile $cC.path
    Assert-Equal 0 $rC1.exitCode "ordering baseline ok ($($rC1.output))"
    $rC2 = Invoke-RunnerSub -KeeperRoot $rootC -ConfigFile $cC.path
    Assert-Equal 0 $rC2.exitCode "ordering anchor run ok ($($rC2.output))"
    $filesC = @(Get-ChildItem -LiteralPath (Get-AnchorClaimsDir $rootC) -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-Equal 1 $filesC.Count 'the ordering run wrote exactly one claim'
    $pathC2 = $filesC[0].FullName
    # Split-Path has no -LeafPath on either shell; the extension-free leaf is
    # exactly the event id the store wrote.
    $evC2 = [System.IO.Path]::GetFileNameWithoutExtension($pathC2)
    $recC2 = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText($pathC2))
    Assert-Equal 'COMPLETED' $recC2.state 'COMPLETED is durable'
    Assert-Equal $evC2 $recC2.eventId 'the idle trigger id is the claim key'
    # The regression: the runner used to persist processedEventIds only AFTER the
    # model call returned, so a concurrent process could start its own claim in
    # that gap. Now COMPLETED is on disk first - so the durable record, not the
    # state file, is what a racing second writer hits.
    $stC = Read-JsonFile (Get-StatePath $rootC)
    Assert-True (@($stC.processedEventIds) -contains $evC2) 'state still marks the event processed (fast path)'
    $completedAtC = ConvertTo-TestInstant $recC2.completedAt
    $lastReadAtC = ConvertTo-TestInstant $stC.lastReadAt
    Assert-True ($null -ne $completedAtC -and $null -ne $lastReadAtC -and $completedAtC -le $lastReadAtC) `
        "terminal claim is written no later than the state save (claim $recC2.completedAt vs state $stC.lastReadAt)"
    $cC2 = Claim-AnchorClaim -KeeperRoot $rootC -EventId $evC2 -Machine @{ machineId = 'PEER-B'; label = 'Peer B' } -ClaimMinutes 20 -LocalOnly $true
    Assert-False $cC2.ok 'a fresh claim attempt on the completed event is denied'
    Assert-True ((Get-ReasonText $cC2) -like 'event already COMPLETED*') "denial names COMPLETED (got: $(Get-ReasonText $cC2))"

    # =====================================================================
    Start-TestGroup 'claim: unreadable store fails closed instead of looking empty'

    $rootD = Join-Path $ws 'unreadable'
    New-Item -ItemType Directory -Path $rootD -Force | Out-Null
    $evD = Get-Sha256Hex 'unreadable|1'
    $pathD = Get-AnchorClaimPath -Root $rootD -EventId $evD
    $null = Ensure-Directory $pathD
    $deniedD = Claim-AnchorClaim -KeeperRoot $rootD -EventId $evD -Machine $machine -ClaimMinutes 20 -LocalOnly $true
    $whyD = Get-ReasonText $deniedD
    Assert-False $deniedD.ok 'a claim path that is a directory denies'
    Assert-True ($whyD -eq 'claim store unreadable; fail closed') "denial is the fail-closed reason (got: $whyD)"
    Assert-False (Test-Path -LiteralPath (Join-Path $pathD "$evD.json")) 'nothing created under it'

    $evE = Get-Sha256Hex 'corrupt|1'
    $pathE = Get-AnchorClaimPath -Root $rootD -EventId $evE
    $null = Ensure-Directory (Split-Path -Parent $pathE)
    [System.IO.File]::WriteAllText($pathE, 'not json at all {{{', (New-Object System.Text.UTF8Encoding($false)))
    $deniedE = Claim-AnchorClaim -KeeperRoot $rootD -EventId $evE -Machine $machine -ClaimMinutes 20 -LocalOnly $true
    $whyE = Get-ReasonText $deniedE
    Assert-False $deniedE.ok 'an unparseable record denies (never treated as absent)'
    Assert-True ($whyE -eq 'claim store unreadable; fail closed') "corrupt record is fail-closed too (got: $whyE)"
    Assert-True (Test-Path -LiteralPath $pathE) 'the corrupt artifact is left for the operator, not silently replaced'
    $existsE = Test-AnchorClaimExists -KeeperRoot $rootD -EventId $evE -LocalOnly $true
    Assert-False $existsE.ok 'Exists reports no claim'
    Assert-False $existsE.reachable 'Exists reports the store unreachable'

    # =====================================================================
    Start-TestGroup 'claim: finalize never resurrects an expired or terminal claim'

    $evF = Get-Sha256Hex 'no-resurrect|1'
    $null = Claim-AnchorClaim -KeeperRoot $rootD -EventId $evF -Machine $machine -ClaimMinutes 20 -LocalOnly $true
    $exp = Mark-AnchorClaimExpired -KeeperRoot $rootD -EventId $evF -Machine $machine -Result 'lease revalidation failed: simulated' -LocalOnly $true
    Assert-True $exp.ok 'CLAIMED can be stamped EXPIRED'
    $recF = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText((Get-AnchorClaimPath -Root $rootD -EventId $evF)))
    Assert-Equal 'EXPIRED' $recF.state 'state EXPIRED'
    Assert-True ($null -eq $recF.completedAt) 'EXPIRED has no completedAt (it is not a finished call)'
    Assert-Equal 'CLAIM-A' $recF.ownerId 'EXPIRED keeps the original owner'
    Assert-True ($recF.result -like 'lease revalidation failed*') "EXPIRED keeps the result reason (got: $($recF.result))"
    $late = Complete-AnchorClaim -KeeperRoot $rootD -EventId $evF -Machine $machine -Result 'late success' -LocalOnly $true
    $whyLate = Get-ReasonText $late
    Assert-False $late.ok 'a late COMPLETED cannot overwrite EXPIRED'
    Assert-True ($whyLate -eq 'claim already EXPIRED') "refusal names the current state (got: $whyLate)"
    $recF2 = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText((Get-AnchorClaimPath -Root $rootD -EventId $evF)))
    Assert-Equal 'EXPIRED' $recF2.state 'record still EXPIRED'
    $againF = Claim-AnchorClaim -KeeperRoot $rootD -EventId $evF -Machine $machine -ClaimMinutes 20 -LocalOnly $true
    Assert-False $againF.ok 'EXPIRED still blocks a retry'
    $nothing = Fail-AnchorClaim -KeeperRoot $rootD -EventId (Get-Sha256Hex 'never-claimed|1') -Machine $machine -Result 'x' -LocalOnly $true
    $whyNone = Get-ReasonText $nothing
    Assert-False $nothing.ok 'finalizing an unclaimed event fails'
    Assert-True ($whyNone -eq 'no claim to finalize') "reason: nothing to finalize (got: $whyNone)"

    # =====================================================================
    Start-TestGroup 'claim: retention sweeps terminal files and never a CLAIMED one'

    $rootG = Join-Path $ws 'retention'
    New-Item -ItemType Directory -Path $rootG -Force | Out-Null
    $oldStamp = (Get-Date).AddDays(-100)
    function Set-OldClaim {
        param([string]$EventId, [string]$State)
        $p = Get-AnchorClaimPath -Root $rootG -EventId $EventId
        Write-AnchorClaimRecordJson -Path $p -Record @{
            schema = 1; eventId = $EventId; state = $State; ownerId = 'CLAIM-A'
            claimedAt = $oldStamp.ToString('yyyy-MM-ddTHH:mm:sszzz')
            claimExpiresAt = $oldStamp.AddMinutes(20).ToString('yyyy-MM-ddTHH:mm:sszzz')
            completedAt = $(if ($State -eq 'CLAIMED') { $null } else { $oldStamp.ToString('yyyy-MM-ddTHH:mm:sszzz') })
            result = $null
        }
        (Get-Item -LiteralPath $p).LastWriteTime = $oldStamp
        return $p
    }
    $pDone = Set-OldClaim -EventId (Get-Sha256Hex 'ret|completed|1') -State 'COMPLETED'
    $pFail = Set-OldClaim -EventId (Get-Sha256Hex 'ret|failed|1') -State 'FAILED'
    $pLive = Set-OldClaim -EventId (Get-Sha256Hex 'ret|claimed|1') -State 'CLAIMED'
    $pJunk = Get-AnchorClaimPath -Root $rootG -EventId (Get-Sha256Hex 'ret|junk|1')
    # Real garbage bytes, not a CLAIMED record: that path is already covered by
    # $pLive. Here the point is that retention cannot PARSE the state, so it must
    # not delete blind.
    [System.IO.File]::WriteAllText($pJunk, '{not json at all', (New-Object System.Text.UTF8Encoding($false)))
    (Get-Item -LiteralPath $pJunk).LastWriteTime = $oldStamp

    Assert-Equal 0 (Invoke-AnchorClaimRetention -KeeperRoot $rootG -RetentionDays 0) 'retentionDays 0 disables cleanup'
    Assert-Equal 0 (Invoke-AnchorClaimRetention -KeeperRoot $rootG -RetentionDays 365) 'nothing older than a year'
    Assert-True (Test-Path -LiteralPath $pLive) 'a stale CLAIMED survives a 90-day sweep'
    $swept = Invoke-AnchorClaimRetention -KeeperRoot $rootG -RetentionDays 90
    Assert-True ($swept -ge 2) "terminal claims swept (count=$swept)"
    Assert-False (Test-Path -LiteralPath $pDone) 'old COMPLETED removed'
    Assert-False (Test-Path -LiteralPath $pFail) 'old FAILED removed'
    Assert-True (Test-Path -LiteralPath $pLive) 'old CLAIMED survives'
    Assert-True (Test-Path -LiteralPath $pJunk) 'an unparseable/stateless record survives rather than being deleted blind'
    Assert-Equal 0 (Invoke-AnchorClaimRetention -KeeperRoot (Join-Path $ws 'no-such-root') -RetentionDays 1) 'missing claims dir is a no-op'

    # Runner integration: the sweep is wired into the completion path and must
    # not break the run when there is nothing to do.
    $rG = Invoke-RunnerSub -KeeperRoot $rootG -ConfigFile (New-LocalAutoAnchorConfig -KeeperRoot $rootG).path
    Assert-Equal 0 $rG.exitCode "runner ok with a claims dir present ($($rG.output))"
    Assert-False ((Get-LogEventNames $rootG) -contains 'RETENTION_FAILED') 'claim retention does not error the run'
    Assert-True (Test-Path -LiteralPath $pLive) 'runner-driven retention also spares the CLAIMED file'

    # =====================================================================
    Start-TestGroup 'concurrency: two processes race one CreateNew - exactly one winner'

    $rootH = Join-Path $ws 'race'
    New-Item -ItemType Directory -Path $rootH -Force | Out-Null
    $evH = Get-Sha256Hex 'race|1'
    $raceDir = Join-Path $ws 'racers'
    $null = Ensure-Directory $raceDir
    $resultsDir = Join-Path $raceDir 'results'
    $null = Ensure-Directory $resultsDir
    $barrier = Join-Path $raceDir 'barrier'
    $raceScript = @'
param([string]$ScriptDir, [string]$KeeperRoot, [string]$EventId, [string]$Barrier, [string]$ResultsDir, [string]$MachineId)
$ErrorActionPreference = 'Stop'
. (Join-Path $ScriptDir 'anchor-claim.ps1')
$mine = Join-Path $ResultsDir ($MachineId + '.ready')
[System.IO.File]::WriteAllText($mine, 'ready')
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $Barrier)) { Start-Sleep -Milliseconds 20 }
$res = Claim-AnchorClaim -KeeperRoot $KeeperRoot -EventId $EventId -Machine @{ machineId = $MachineId; label = $MachineId } -ClaimMinutes 30 -LocalOnly $true
[System.IO.File]::WriteAllText((Join-Path $ResultsDir ($MachineId + '.json')), (@{ machineId = $MachineId; ok = [bool]$res.ok; reason = [string]$res.reason } | ConvertTo-Json -Compress))
exit 0
'@
    $raceFile = Join-Path $raceDir 'race.ps1'
    [System.IO.File]::WriteAllText($raceFile, $raceScript, (New-Object System.Text.UTF8Encoding($false)))

    $racers = @()
    foreach ($m in @('RACER-A', 'RACER-B', 'RACER-C', 'RACER-D')) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $pwsh
        $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ScriptDir "{1}" -KeeperRoot "{2}" -EventId "{3}" -Barrier "{4}" -ResultsDir "{5}" -MachineId "{6}"' -f `
            $raceFile, $scriptDir, $rootH, $evH, $barrier, $resultsDir, $m)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        # ProcessStartInfo has no Start() method on either shell - the static
        # Process::Start(Psi) overload is the launch call.
        $racers += [System.Diagnostics.Process]::Start($psi)
    }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and @(Get-ChildItem -LiteralPath $resultsDir -Filter '*.ready' -File).Count -lt 4) { Start-Sleep -Milliseconds 50 }
    [System.IO.File]::WriteAllText($barrier, 'go')
    foreach ($p in $racers) { $p.WaitForExit() ; $p.Dispose() }

    $verdicts = @()
    Get-ChildItem -LiteralPath $resultsDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $verdicts += ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText($_.FullName))
    }
    Assert-Equal 4 @($verdicts).Count 'all four racers reported'
    $okRacers = @($verdicts | Where-Object { $_.ok })
    $noRacers = @($verdicts | Where-Object { -not $_.ok })
    Assert-Equal 1 @($okRacers).Count "exactly one racer wins the exclusive create (ok=$(($verdicts | ForEach-Object { $_.ok }) -join ','))"
    Assert-Equal 3 @($noRacers).Count 'three racers are denied'
    foreach ($loser in $noRacers) {
        # Either reading is a denial; neither may ever be a silent success, and
        # neither may report the file as created.
        Assert-True ($loser.reason -match 'already CLAIMED|claim create failed') "loser reason is a denial ($($loser.reason))"
    }
    $claimFilesH = @(Get-ChildItem -LiteralPath (Get-AnchorClaimsDir $rootH) -Filter '*.json' -File)
    Assert-Equal 1 $claimFilesH.Count 'one CLAIMED artifact for four racers'
    $recH = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText($claimFilesH[0].FullName))
    Assert-Equal 'CLAIMED' $recH.state 'the survivor is CLAIMED'
    Assert-Equal $okRacers[0].MachineId $recH.ownerId 'no torn record: the file owner is the winning process'

    # =====================================================================
    Start-TestGroup 'claim: unified face routes by backing, both say it in the same words'

    $coordRoot = $null
    $cfgDist = $null
    $repos = $null
    try { $repos = New-TestOriginAndClone -Workspace $ws } catch { $repos = $null }
    if ($repos) {
        $coordRoot = $repos.clone
        # The push gate reads the binding from the SAME keeper root the verbs get,
        # so initialize before claiming or every push fails closed.
        $init = Initialize-LogRepo -RepoPath $coordRoot -KeeperRoot $rootA
        if (-not $init.ok) { $coordRoot = $null }
    }
    if (-not $coordRoot) {
        # Fallback for the offline path: drive the distributed branch directly.
        $rootI = Join-Path $ws 'dist-direct'
        New-Item -ItemType Directory -Path $rootI -Force | Out-Null
        $cfgI = New-TestConfig @{ github = @{ coordination = @{ enabled = $true; repoPath = (Join-Path $ws 'no-such-repo'); branch = 'cqk/coordination' } } }
        $r = Claim-AnchorClaim -Config $cfgI -KeeperRoot $rootI -EventId (Get-Sha256Hex 'unrouted|1') -Machine $machine -ClaimMinutes 20 -LocalOnly $false
        $whyR = Get-ReasonText $r
        Assert-False $r.ok 'distributed routing denies without a usable repo'
        Assert-True ($whyR -like '*fail closed') "distributed routing fails closed without a usable repo (got: $whyR)"
    } else {
        $cfgDist = New-TestConfig @{ github = @{ coordination = @{ enabled = $true; repoPath = $coordRoot; branch = 'cqk/coordination' } } }
        $evJ = Get-Sha256Hex 'unified|1'
        $dClaim = Claim-AnchorClaim -Config $cfgDist -KeeperRoot $rootA -EventId $evJ -Machine $machine -ClaimMinutes 20 -LocalOnly $false
        Assert-True $dClaim.ok "distributed claim over Git CAS ok ($($dClaim.reason))"
        # Push-RepoBlobs writes the commit straight to the branch through a temp
        # index and never touches the worktree, so remote state must be read back
        # from origin - not from files under the clone.
        $blobJ = Get-RemoteBranchBlob -RepoPath $coordRoot -Branch 'cqk/coordination' -PathInRepo (Get-AnchorEventCoordPath $evJ)
        Assert-True ($blobJ.ok -and $blobJ.content) 'the claim is pushed to the coordination branch'
        # The two backings have INDEPENDENT namespaces: runtime/anchor-claims never
        # sees coordination/events. That is safe only because the election puts a
        # machine in exactly one backing, never both - asserted here so a future
        # change to that rule breaks a test instead of double-billing a user.
        $lClaim = Claim-AnchorClaim -KeeperRoot $rootA -EventId $evJ -Machine $machine -ClaimMinutes 20 -LocalOnly $true
        Assert-True $lClaim.ok 'local namespace is separate: the same id claims locally too'
        $dAgain = Claim-AnchorClaim -Config $cfgDist -KeeperRoot $rootA -EventId $evJ -Machine @{ machineId = 'PEER-B'; label = 'b' } -ClaimMinutes 20 -LocalOnly $false
        Assert-False $dAgain.ok 'distributed store denies a second claim'
        $lAgain = Claim-AnchorClaim -KeeperRoot $rootA -EventId $evJ -Machine @{ machineId = 'PEER-B'; label = 'b' } -ClaimMinutes 20 -LocalOnly $true
        Assert-False $lAgain.ok 'local store denies its own claim independently'
        # One wording for both backings, so no renderer has to know which denied.
        $whyD = Get-ReasonText $dAgain
        $whyL = Get-ReasonText $lAgain
        Assert-True ($whyD -eq 'event already CLAIMED (by CLAIM-A); no retry') "distributed denial wording (got: $whyD)"
        Assert-True ($whyL -eq 'event already CLAIMED (by CLAIM-A); no retry') "local denial is worded identically (got: $whyL)"
        $dExists = Test-AnchorClaimExists -Config $cfgDist -KeeperRoot $rootA -EventId $evJ -LocalOnly $false
        $lExists = Test-AnchorClaimExists -KeeperRoot $rootA -EventId $evJ -LocalOnly $true
        Assert-True $dExists.ok 'distributed Exists sees the claim'
        Assert-True $lExists.ok 'local Exists sees the local claim'
        Assert-Equal $dExists.record.state $lExists.record.state 'both records report the same state field'
        $dDone = Complete-AnchorClaim -Config $cfgDist -KeeperRoot $rootA -EventId $evJ -Machine $machine -Result 'ok' -LocalOnly $false
        Assert-True $dDone.ok "distributed COMPLETED push ok ($($dDone.reason))"
        $recJ = Get-DistributedAnchorEventState -Config $cfgDist -KeeperRoot $rootA -EventId $evJ
        Assert-Equal 'COMPLETED' $recJ.record.state 'distributed terminal state readable'
        # Assert-False takes [bool] and PowerShell cannot coerce $null/'' to it, so
        # the cleared expiry is checked as null - which is what both backings write.
        Assert-Null $recJ.record.claimExpiresAt 'claimExpiresAt cleared on completion'
    }

    # =====================================================================
    Start-TestGroup 'claim: distributed regression - exclusive create, denial text and terminal write'

    if (-not $coordRoot) {
        # No git available at all: assert the fail-closed shape of every verb.
        $rootK = Join-Path $ws 'dist-nogit'
        New-Item -ItemType Directory -Path $rootK -Force | Out-Null
        $cfgK = New-TestConfig @{ github = @{ coordination = @{ enabled = $true; repoPath = (Join-Path $ws 'no-such-repo-2'); branch = 'cqk/coordination' } } }
        $evK = Get-Sha256Hex 'nogit|1'
        $k1 = Claim-AnchorClaim -Config $cfgK -KeeperRoot $rootK -EventId $evK -Machine $machine -ClaimMinutes 20 -LocalOnly $false
        $whyK = Get-ReasonText $k1
        Assert-False $k1.ok 'unreachable remote denies the claim'
        Assert-True ($whyK -like '*fail closed') "unreachable remote is fail-closed (got: $whyK)"
        Assert-False (Test-Path -LiteralPath (Get-AnchorClaimPath -Root $rootK -EventId $evK)) 'distributed mode writes no local artifact'
        $k2 = Test-AnchorClaimExists -Config $cfgK -KeeperRoot $rootK -EventId $evK -LocalOnly $false
        Assert-False $k2.reachable 'Exists reports the remote unreachable rather than absent'
    } else {
        $evL = Get-Sha256Hex 'dist-crash|1'
        $l1 = Claim-AnchorClaim -Config $cfgDist -KeeperRoot $rootA -EventId $evL -Machine $machine -ClaimMinutes 20 -LocalOnly $false
        Assert-True $l1.ok 'first distributed claim wins'
        $l2 = Claim-AnchorClaim -Config $cfgDist -KeeperRoot $rootA -EventId $evL -Machine @{ machineId = 'PEER-C'; label = 'c' } -ClaimMinutes 20 -LocalOnly $false
        Assert-False $l2.ok 'peer denied while CLAIMED'
        $whyL2 = Get-ReasonText $l2
        Assert-True ($whyL2 -eq 'event already CLAIMED (by CLAIM-A); no retry') "denial names the remote owner (got: $whyL2)"
        # Tamper the binding marker -> the completion push fails -> CLAIMED stays.
        $markerPath = Join-Path $coordRoot '.codex-quota-keeper-repository.json'
        $origMarker = [System.IO.File]::ReadAllText($markerPath)
        [System.IO.File]::WriteAllText($markerPath, '{"schema":1,"repoId":"tampered","createdFor":"codex-quota-keeper"}', (New-Object System.Text.UTF8Encoding($false)))
        $lFail = Complete-AnchorClaim -Config $cfgDist -KeeperRoot $rootA -EventId $evL -Machine $machine -Result 'ok' -LocalOnly $false
        Assert-False $lFail.ok 'completion push fails under a broken binding'
        [System.IO.File]::WriteAllText($markerPath, $origMarker, (New-Object System.Text.UTF8Encoding($false)))
        $lAfter = Get-DistributedAnchorEventState -Config $cfgDist -KeeperRoot $rootA -EventId $evL
        Assert-Equal 'CLAIMED' $lAfter.record.state 'a failed terminal write leaves CLAIMED (never retried)'
        $lRecKeys = @($lAfter.record.Keys | Sort-Object)
        $lExpected = @('claimExpiresAt', 'completedAt', 'eventId', 'ownerId', 'result', 'schema', 'claimedAt', 'state') | Sort-Object
        Assert-Equal ($lExpected -join ',') ($lRecKeys -join ',') 'distributed record carries the same eight keys as the local one'
    }
} finally {
    Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\CQK_MOCK_EXEC -ErrorAction SilentlyContinue
    Remove-Item Env:\CQK_MOCK_EXEC_ARGS_FILE -ErrorAction SilentlyContinue
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "anchor-claim.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
