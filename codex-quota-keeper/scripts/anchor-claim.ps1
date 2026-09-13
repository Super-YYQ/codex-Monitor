# Codex Quota Keeper - unified AutoAnchor claim store (CQK-023).
#
# One claim semantics, two durable backings:
#
#   DISTRIBUTED (github.coordination.enabled)  coordination/events/<eventId>.json
#       on the coordination branch. The exclusive write is a Git CAS push, so a
#       rejected push means a peer claimed first.
#   LOCAL_ONLY  (single machine, no coordination repo)  runtime/anchor-claims/<eventId>.json
#       The exclusive write is File.CreateMode=CreateNew, the local mirror of the
#       CAS: two racing processes cannot both create the same file.
#
# Both backings expose Claim / Complete / Fail / Exists over the SAME record
# shape and the SAME rule: any pre-existing claim (CLAIMED / COMPLETED / FAILED /
# EXPIRED) blocks execution, because an uncertain outcome must never be retried.
#
# LOCAL_ONLY used to have no artifact at all - at-most-once rested on the runner
# mutex plus state.processedEventIds, which the runner only persists AFTER the
# model call. A crash between `codex exec` and Save-KeeperState therefore
# re-anchored on the next tick and billed the user twice. The durable CLAIMED
# file created before exec closes that window: state.processedEventIds stays as
# an in-memory fast path, but it is no longer the persistence layer.
#
# Retention sweeps COMPLETED / FAILED / EXPIRED only. A CLAIMED file is the
# uncertain-outcome blocker and must never be aged out automatically.

$script:CqkAnchorClaimDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkAnchorClaimDir 'common.ps1')
}
if (-not (Get-Command Test-GitAvailable -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkAnchorClaimDir 'github-sync.ps1')
}

function Get-AnchorClaimResultValue {
    # A [string] parameter cannot carry $null: PowerShell coerces it to '' at the
    # call boundary, and the serializer would then write "" where the record means
    # JSON null. A clean COMPLETED has no result at all, and both backings must say
    # so identically - the local and coordination records are meant to be comparable.
    param([string]$Result)
    if ([string]::IsNullOrWhiteSpace($Result)) { return $null }
    return $Result
}

function New-AnchorClaimRecord {
    # The store-neutral claim shape. Identical in both backings so renderers,
    # status panels and tests can never tell them apart by field names.
    param(
        [string]$EventId,
        [string]$State,
        [string]$OwnerId,
        [int]$ClaimMinutes = 0,
        [string]$Result = $null
    )
    $now = Get-Date
    return @{
        schema         = 1
        eventId        = $EventId
        state          = $State
        ownerId        = $OwnerId
        claimedAt      = $now.ToString('yyyy-MM-ddTHH:mm:sszzz')
        claimExpiresAt = $(if ($ClaimMinutes -gt 0) { $now.AddMinutes($ClaimMinutes).ToString('yyyy-MM-ddTHH:mm:sszzz') } else { $null })
        completedAt    = $(if ($State -in @('COMPLETED', 'FAILED')) { $now.ToString('yyyy-MM-ddTHH:mm:sszzz') } else { $null })
        result         = (Get-AnchorClaimResultValue $Result)
    }
}

function ConvertTo-AnchorClaimRecordJson {
    # Shallow serializer: exactly the eight keys of New-AnchorClaimRecord, in that
    # order. ConvertTo-Json's deep pipeline is a footgun here - the `result` string
    # may itself be a JSON document (an anchor reason carries exec diagnostics),
    # and a deeper pass has been observed to re-parse and expand it into an object.
    #
    # -Depth 1 is the shallowest legal value: PS5.1 validates the range as >= 1 and
    # throws on 0 (verified: 5.1.19041), while a scalar at depth 1 is still emitted
    # as one JSON string, so a JSON-shaped `result` stays a string on both shells.
    param([hashtable]$Record)
    $parts = @()
    foreach ($key in @('schema', 'eventId', 'state', 'ownerId', 'claimedAt', 'claimExpiresAt', 'completedAt', 'result')) {
        $value = $Record[$key]
        # PS5.1 renders a $null scalar as the empty string; serialize nulls directly
        # so the record is valid JSON on both shells.
        $json = $(if ($null -eq $value) { 'null' } else { ConvertTo-Json -InputObject $value -Depth 1 })
        $parts += ('"' + $key + '":' + $json)
    }
    return '{' + ($parts -join ',') + '}'
}

function Write-AnchorClaimRecordJson {
    param([string]$Path, [hashtable]$Record)
    Ensure-Directory (Split-Path -Parent $Path) | Out-Null
    [System.IO.File]::WriteAllText($Path, (ConvertTo-AnchorClaimRecordJson $Record) + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false)))
}

function Read-AnchorClaimRecord {
    # Read one claim file into @{ read; empty; record } - the three states the
    # caller has to tell apart:
    #   read=false  access denied (dir / ACL / volume)  -> caller fails closed
    #   empty=true  present but no bytes (0 or whitespace) -> an in-flight
    #                                                             peer create
    #   record      a parsed hashtable, else $null
    #
    # Deliberately NOT Read-JsonFile. It swallows every exception into $null, so
    # a transient sharing violation is indistinguishable from a corrupt record
    # and the caller reports a healthy peer claim as 'claim store unreadable'.
    # And [IO.File]::ReadAllText is not usable here either: it opens with
    # FileShare.Read, which denies the Write access of a winner that still holds
    # the file open, so it throws exactly when a claim is being created. Opening
    # with FileShare.ReadWrite lets the read through so the caller can judge the
    # CONTENT instead of mistaking an in-flight peer claim for a broken store.
    #
    # Access errors are reported as read=false, not thrown: the retry loop in
    # Read-LocalAnchorClaim must be able to try again without an exception
    # jumping past it to the outer catch.
    param([string]$Path)
    $res = @{ read = $false; empty = $true; record = $null }
    $fs = $null
    $reader = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)), $true)
        $text = $reader.ReadToEnd()
        $res.read = $true
        $res.empty = [string]::IsNullOrWhiteSpace($text)
        if (-not $res.empty) { $res.record = ConvertFrom-JsonSafe $text }
    } catch {
        $res.read = $false
    } finally {
        # Disposing the reader disposes the stream; only cover the early throw.
        if ($reader) { $reader.Dispose() } elseif ($fs) { $fs.Dispose() }
    }
    return $res
}

function Read-LocalAnchorClaim {
    # Returns the store-standard shape: @{ reachable; exists; record }.
    # `reachable` is false only when the store cannot be trusted at all - the
    # claims path is a directory, or the record is non-empty but never parses
    # (corrupt on purpose, truncated by hand, or a winner that died mid-write).
    # That is the local mirror of "remote unavailable", which callers fail closed
    # on rather than assuming "no claim". An EMPTY file is NOT that: see below.
    param([string]$KeeperRoot, [string]$EventId)
    $out = @{ reachable = $true; exists = $false; record = $null }
    $path = Get-AnchorClaimPath -Root $KeeperRoot -EventId $EventId
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            # A present-but-unreadable file is never "absent".
            if (Test-Path -LiteralPath $path -PathType Container) { $out.reachable = $false }
            return $out
        }
        # A peer can win the exclusive create a moment before this read, and its
        # create-then-write is not one atomic disk event: the file may be
        # observed empty, half-written, or briefly locked. Retry so the normal
        # case resolves to the real record, and report it as soon as it parses.
        for ($try = 0; $try -lt 10; $try++) {
            $read = Read-AnchorClaimRecord $path
            if ($read.record -is [hashtable]) {
                $out.exists = $true
                $out.record = $read.record
                return $out
            }
            Start-Sleep -Milliseconds 100
        }
        # The budget ran out without a parsed record. Two very different states
        # remain, separated by whether ANY bytes landed:
        #   Empty file (0 bytes / whitespace only): some process won CreateNew and
        #     has written nothing yet. CreateNew is the exclusive step, so the
        #     file's existence already IS the claim regardless of content - it is
        #     not a broken store. Report it as a live CLAIMED with an unknown
        #     owner. Even a winner that died here stays denied, which is the
        #     correct fail-closed outcome for an at-most-once guard (the eventId
        #     is per-day, so it costs at most today's one anchor, and the empty
        #     artifact is left for the operator).
        #   Non-empty but unparseable: torn or hand-edited content that will never
        #     resolve. Fail closed as 'claim store unreadable'.
        if ($read.read -and $read.empty) {
            $out.exists = $true
            $out.record = @{ state = 'CLAIMED'; ownerId = '' }
            return $out
        }
        $out.reachable = $false
    } catch {
        $out.reachable = $false
    }
    return $out
}

# ---------------------------------------------------------------------------
# LOCAL_ONLY store: Claim / Complete / Fail / Exists

function Claim-LocalAnchorEvent {
    # Atomic exclusive create of the CLAIMED file BEFORE any model call.
    # CreateNew is the whole point: Write-JsonFileAtomic uses Move -Force, i.e.
    # overwrite semantics, which would let a racing process replace a live claim.
    param(
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Machine,
        [int]$ClaimMinutes
    )
    $existing = Read-LocalAnchorClaim -KeeperRoot $KeeperRoot -EventId $EventId
    if (-not $existing.reachable) { return @{ ok = $false; reason = 'claim store unreadable; fail closed' } }
    if ($existing.exists) {
        return @{ ok = $false; exists = $true; reason = "event already $([string]$existing.record.state) (by $([string]$existing.record.ownerId)); no retry" }
    }
    $path = Get-AnchorClaimPath -Root $KeeperRoot -EventId $EventId
    $record = New-AnchorClaimRecord -EventId $EventId -State 'CLAIMED' `
        -OwnerId ([string]$Machine.machineId) -ClaimMinutes $ClaimMinutes
    try {
        Ensure-Directory (Split-Path -Parent $path) | Out-Null
        # FileShare.Read, not the default: File.Open(mode, access) keeps
        # FileShare.None, so while the winner is between create and flush NO peer
        # can open the file at all - every loser reads 'unreadable' instead of
        # 'already CLAIMED'. Sharing a read handle does not weaken the lock:
        # FileMode.CreateNew is the exclusive step (it throws on an existing
        # file whatever the share mode says), and peers still cannot open for
        # write. They can only observe the claim forming.
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try {
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(
                (ConvertTo-AnchorClaimRecordJson $record) + [Environment]::NewLine)
            $fs.Write($bytes, 0, $bytes.Length)
        } finally { $fs.Dispose() }
    } catch [System.IO.IOException] {
        # CreateNew throws IOException exactly when the file appeared between the
        # existence check and the create: the other writer holds the claim.
        $after = Read-LocalAnchorClaim -KeeperRoot $KeeperRoot -EventId $EventId
        if ($after.exists) {
            return @{ ok = $false; exists = $true; reason = "event already $([string]$after.record.state) (by $([string]$after.record.ownerId)); no retry" }
        }
        return @{ ok = $false; reason = "claim create failed: $($_.Exception.Message)" }
    } catch {
        return @{ ok = $false; reason = "claim create failed: $($_.Exception.Message)" }
    }
    return @{ ok = $true; reason = $null }
}

function Complete-LocalAnchorEvent {
    param([string]$KeeperRoot, [string]$EventId, [hashtable]$Machine, [string]$Result = $null)
    return Finalize-LocalAnchorEvent -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine -State 'COMPLETED' -Result $Result
}

function Fail-LocalAnchorEvent {
    param([string]$KeeperRoot, [string]$EventId, [hashtable]$Machine, [string]$Result = $null)
    return Finalize-LocalAnchorEvent -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine -State 'FAILED' -Result $Result
}

function Finalize-LocalAnchorEvent {
    # Transitions THIS machine's CLAIMED file to a terminal state. It never
    # creates and never rewrites a peer's claim, so it is not a second write path
    # around the exclusive create above.
    param(
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Machine,
        [ValidateSet('COMPLETED', 'FAILED', 'EXPIRED')][string]$State,
        [string]$Result = $null
    )
    $existing = Read-LocalAnchorClaim -KeeperRoot $KeeperRoot -EventId $EventId
    if (-not $existing.exists) { return @{ ok = $false; reason = 'no claim to finalize' } }
    if ([string]$existing.record.state -ne 'CLAIMED') { return @{ ok = $false; reason = "claim already $([string]$existing.record.state)" } }
    $record = @{
        schema         = 1
        eventId        = $EventId
        state          = $State
        ownerId        = [string]$existing.record.ownerId
        claimedAt      = ConvertTo-IsoString $existing.record.claimedAt
        claimExpiresAt = $(if ($State -eq 'EXPIRED') { Get-IsoTimestamp } else { ConvertTo-IsoString $existing.record.claimExpiresAt })
        completedAt    = $(if ($State -eq 'EXPIRED') { $null } else { Get-IsoTimestamp })
        result         = (Get-AnchorClaimResultValue $Result)
    }
    try {
        Write-AnchorClaimRecordJson -Path (Get-AnchorClaimPath -Root $KeeperRoot -EventId $EventId) -Record $record
    } catch {
        # Staying CLAIMED is the correct outcome: an uncertain write must keep
        # blocking retries, exactly like a failed COMPLETED push in distributed
        # mode. Report it, never silently drop it.
        return @{ ok = $false; reason = "finalize write failed: $($_.Exception.Message)" }
    }
    return @{ ok = $true; reason = $null }
}

function Test-LocalAnchorClaimExists {
    param([string]$KeeperRoot, [string]$EventId)
    $cur = Read-LocalAnchorClaim -KeeperRoot $KeeperRoot -EventId $EventId
    $reason = $null
    if ($cur.exists) { $reason = "event already $([string]$cur.record.state) (by $([string]$cur.record.ownerId)); no retry" }
    return @{ ok = $cur.exists; reachable = [bool]$cur.reachable; record = $cur.record; reason = $reason }
}

# ---------------------------------------------------------------------------
# DISTRIBUTED store: coordination/events/<eventId>.json via Git CAS.
# Moved here from auto-anchor.ps1 unchanged in behaviour; auto-anchor.ps1 keeps
# thin wrappers so tests/concurrency.test.ps1 keeps its existing call sites.

function Get-AnchorEventCoordPath {
    param([string]$EventId)
    return 'coordination/events/' + $EventId + '.json'
}

function Get-DistributedAnchorEventState {
    # Reads coordination/events/<eventId>.json (read-only).
    param([hashtable]$Config, [string]$KeeperRoot, [string]$EventId)
    $out = @{ reachable = $false; exists = $false; record = $null; commit = $null; reason = $null }
    if (-not (Test-CoordinationEnabled $Config)) { $out.reason = 'disabled'; return $out }
    if (-not (Test-GitAvailable)) { $out.reason = 'git-unavailable'; return $out }
    $coord = Get-CoordinationConfig $Config
    $blob = Get-RemoteBranchBlob -RepoPath ([System.IO.Path]::GetFullPath($coord.repoPath)) -Branch $coord.branch `
        -PathInRepo (Get-AnchorEventCoordPath $EventId)
    if (-not $blob.ok) { $out.reason = 'unreachable'; return $out }
    $out.reachable = $true
    $out.commit = $blob.commit
    if ($blob.reason -eq 'ok' -and $blob.content) {
        $rec = ConvertFrom-JsonSafe $blob.content
        if ($rec -is [hashtable]) { $out.exists = $true; $out.record = $rec }
    }
    return $out
}

function Push-DistributedAnchorEventState {
    # CAS-writes the anchor event record (CLAIMED / COMPLETED / FAILED / EXPIRED).
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Record,
        [hashtable]$Machine
    )
    $coord = Get-CoordinationConfig $Config
    $repoPath = [System.IO.Path]::GetFullPath($coord.repoPath)
    $binding = Test-LogRepoBinding -RepoPath $repoPath -KeeperRoot $KeeperRoot -Branch $coord.branch
    if ($binding) { return @{ ok = $false; reason = "binding: $binding" } }
    $blob = Get-RemoteBranchBlob -RepoPath $repoPath -Branch $coord.branch -PathInRepo (Get-AnchorEventCoordPath $EventId)
    if (-not $blob.ok) { return @{ ok = $false; reason = 'unreachable' } }
    $parent = $null
    if ($blob.commit) { $parent = $blob.commit }
    $push = Push-RepoBlobs -RepoPath $repoPath -Branch $coord.branch `
        -Blobs @{ (Get-AnchorEventCoordPath $EventId) = (ConvertTo-Json -InputObject $Record -Depth 6) } `
        -ParentCommit $parent -CommitMessage "anchor: $($Record.state) $EventId" `
        -MachineId ([string]$Machine.machineId)
    return @{ ok = $push.ok; reason = $push.reason }
}

function Claim-DistributedAnchorEvent {
    # Distributed at-most-once side-effect claim (audit plan v1.0 section 5, CQK-013):
    # the event file is CREATED via CAS push while it does not exist. A rejected
    # push means another machine claimed first. Any existing event file
    # (CLAIMED / COMPLETED / FAILED / EXPIRED) blocks execution: an uncertain
    # outcome must never be retried.
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Machine,
        [int]$ClaimMinutes
    )
    $state = Get-DistributedAnchorEventState -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId
    if (-not $state.reachable) { return @{ ok = $false; reason = "remote unavailable ($($state.reason)); fail closed" } }
    if ($state.exists) {
        $st = [string]$state.record.state
        return @{ ok = $false; exists = $true; reason = "event already $st (by $($state.record.ownerId)); no retry" }
    }
    $record = New-AnchorClaimRecord -EventId $EventId -State 'CLAIMED' `
        -OwnerId ([string]$Machine.machineId) -ClaimMinutes $ClaimMinutes
    $push = Push-DistributedAnchorEventState -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId -Record $record -Machine $Machine
    if (-not $push.ok) { return @{ ok = $false; reason = "claim push rejected ($($push.reason)); claim outcome not confirmed" } }
    return @{ ok = $true; reason = $null }
}

function Finalize-DistributedAnchorEvent {
    # Terminal transition written back over our own CLAIMED record (CQK-013).
    # A failed push leaves the event CLAIMED, which blocks every machine -
    # uncertain outcome is never retried.
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Machine,
        [ValidateSet('COMPLETED', 'FAILED', 'EXPIRED')][string]$State,
        [string]$Result = $null,
        [string]$ClaimedAt = '',
        [string]$CompletedAt = ''
    )
    $now = Get-IsoTimestamp
    $record = @{
        schema         = 1
        eventId        = $EventId
        state          = $State
        ownerId        = [string]$Machine.machineId
        claimedAt      = $(if ($ClaimedAt) { $ClaimedAt } else { $now })
        claimExpiresAt = $(if ($State -eq 'EXPIRED') { $now } else { $null })
        completedAt    = $(if ($State -eq 'EXPIRED') { $null } else { $(if ($CompletedAt) { $CompletedAt } else { $now }) })
        result         = (Get-AnchorClaimResultValue $Result)
    }
    return Push-DistributedAnchorEventState -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId -Record $record -Machine $Machine
}

function Complete-DistributedAnchorEvent {
    param([hashtable]$Config, [string]$KeeperRoot, [string]$EventId, [hashtable]$Machine, [string]$Result = $null, [string]$ClaimedAt = '', [string]$CompletedAt = '')
    return Finalize-DistributedAnchorEvent -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine `
        -State 'COMPLETED' -Result $Result -ClaimedAt $ClaimedAt -CompletedAt $CompletedAt
}

function Fail-DistributedAnchorEvent {
    param([hashtable]$Config, [string]$KeeperRoot, [string]$EventId, [hashtable]$Machine, [string]$Result = $null, [string]$ClaimedAt = '', [string]$CompletedAt = '')
    return Finalize-DistributedAnchorEvent -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine `
        -State 'FAILED' -Result $Result -ClaimedAt $ClaimedAt -CompletedAt $CompletedAt
}

function Test-DistributedAnchorClaimExists {
    param([hashtable]$Config, [string]$KeeperRoot, [string]$EventId)
    $cur = Get-DistributedAnchorEventState -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId
    $reason = $null
    if ($cur.exists) { $reason = "event already $([string]$cur.record.state) (by $($cur.record.ownerId)); no retry" }
    return @{ ok = [bool]$cur.exists; reachable = [bool]$cur.reachable; record = $cur.record; reason = $reason }
}

# ---------------------------------------------------------------------------
# The unified face used by Invoke-AutoAnchorIfNeeded. $LocalOnly is the store
# selector - exactly one branch per verb, so a new backing only has to land here.

function Claim-AnchorClaim {
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Machine,
        [int]$ClaimMinutes,
        [bool]$LocalOnly = $false
    )
    if ($LocalOnly) { return Claim-LocalAnchorEvent -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine -ClaimMinutes $ClaimMinutes }
    return Claim-DistributedAnchorEvent -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine -ClaimMinutes $ClaimMinutes
}

function Complete-AnchorClaim {
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Machine,
        [string]$Result = $null,
        [string]$ClaimedAt = '',
        [string]$CompletedAt = '',
        [bool]$LocalOnly = $false
    )
    if ($LocalOnly) { return Complete-LocalAnchorEvent -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine -Result $Result }
    return Complete-DistributedAnchorEvent -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine `
        -Result $Result -ClaimedAt $ClaimedAt -CompletedAt $CompletedAt
}

function Fail-AnchorClaim {
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Machine,
        [string]$Result = $null,
        [string]$ClaimedAt = '',
        [string]$CompletedAt = '',
        [bool]$LocalOnly = $false
    )
    if ($LocalOnly) { return Fail-LocalAnchorEvent -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine -Result $Result }
    return Fail-DistributedAnchorEvent -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine `
        -Result $Result -ClaimedAt $ClaimedAt -CompletedAt $CompletedAt
}

function Test-AnchorClaimExists {
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [bool]$LocalOnly = $false
    )
    if ($LocalOnly) { return Test-LocalAnchorClaimExists -KeeperRoot $KeeperRoot -EventId $EventId }
    return Test-DistributedAnchorClaimExists -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId
}

function Mark-AnchorClaimExpired {
    # CQK-014's "we claimed but must not execute" path: an uncertain outcome is
    # stamped EXPIRED so no machine - including this one - retries it.
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string]$EventId,
        [hashtable]$Machine,
        [string]$Result = $null,
        [bool]$LocalOnly = $false
    )
    if ($LocalOnly) { return Finalize-LocalAnchorEvent -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine -State 'EXPIRED' -Result $Result }
    return Finalize-DistributedAnchorEvent -Config $Config -KeeperRoot $KeeperRoot -EventId $EventId -Machine $Machine -State 'EXPIRED' -Result $Result
}

function Invoke-AnchorClaimRetention {
    # Sweeps TERMINAL local claims older than RetentionDays.
    #
    # The file mtime is used rather than completedAt because an old record is
    # exactly the case where completedAt may not parse (PS7 turns it into a
    # DateTime, a hand-edited file may hold anything). CLAIMED is never a
    # candidate: it is the uncertain-outcome blocker, and aging it out would
    # reopen the duplicate-model-call hole this whole store exists to close.
    param([string]$KeeperRoot, [int]$RetentionDays)
    $removed = 0
    if ($RetentionDays -le 0) { return $removed }
    $dir = Get-AnchorClaimsDir $KeeperRoot
    if (-not (Test-Path -LiteralPath $dir)) { return $removed }
    $cutoff = (Get-Date).AddDays(-1 * $RetentionDays)
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        if ($f.LastWriteTime -ge $cutoff) { continue }
        $rec = Read-JsonFile $f.FullName
        if ($null -eq $rec -or [string]$rec.state -eq 'CLAIMED') { continue }
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        $removed += 1
    }
    return $removed
}
