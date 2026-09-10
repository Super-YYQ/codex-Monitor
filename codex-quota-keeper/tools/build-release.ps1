# Codex Quota Keeper - release packager (CQK-035).
#
# Builds the distributable ZIP straight out of Git so the artifact is defined by
# a commit rather than by whatever happens to be in the working tree, then writes
# a SHA256SUMS file next to it.
#
# Why `git archive` and not Compress-Archive over the working directory:
#  - the working tree is where config.json, runtime/ and history/ live. Those are
#    gitignored for a reason - shipping one would ship a machine identity and a
#    live credential-bearing config. `git archive HEAD -- <prefix>` can only see
#    tracked files, so "never package local state" is structural, not a filter
#    somebody has to keep correct.
#  - blob bytes are LF-normalised and entry timestamps come from the commit, so
#    the same commit zips to the same SHA256 on any machine. A working-tree zip
#    would vary with core.autocrlf.
#  - Compress-Archive embeds wall-clock mtimes, so its hash is not reproducible.
#
# Nothing is published by this script: it only produces files under OutDir and
# prints the `gh release create` command for a human to run. Tagging and releasing
# stay deliberate acts (see docs/release-engineering.md).
#
# Usage:
#   pwsh -NoProfile -File codex-quota-keeper/tools/build-release.ps1
#   pwsh -NoProfile -File codex-quota-keeper/tools/build-release.ps1 -Version 0.9.1-beta -DirtyOk
#   powershell -NoProfile -File codex-quota-keeper/tools/build-release.ps1 -VerifyOnly
#
# The body is a set of functions with the CLI behind an InvocationName guard, so
# tests/build-release.test.ps1 can drive a whole release against a throwaway git
# repo. A packager whose safety gates only run at the prompt cannot be tested.

[CmdletBinding()]
param(
    # Release version. Must match the version the shipped code reports at runtime,
    # which is $CQK_VERSION in scripts/common.ps1 - a ZIP named v1.2.3 whose
    # status.cmd prints 0.9.0 is the kind of thing that only bites after release.
    [string]$Version = '',
    # Where the ZIP and SHA256SUMS.txt are written. Default: tools/dist (ignored).
    [string]$OutDir = '',
    # Tag/commit to package. Default: HEAD.
    [string]$Ref = 'HEAD',
    # Skip the clean-working-tree gate. For dry runs only; a release cut from a
    # dirty tree cannot be reproduced by anyone else.
    [switch]$DirtyOk,
    # Re-hash an existing artifact and compare it against SHA256SUMS.txt without
    # rebuilding anything.
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
# PS 5.1 ships ZipFile in a separate assembly (7 has it in the shared
# Microsoft.PowerShell.Archive dependency chain); Add-Type is a no-op when the
# type is already loadable, so this is the one call that makes the entry
# inspection below run on both runtimes.
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
if (-not ('System.IO.Compression.ZipFile' -as [type])) {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
}

$script:ReleasePrefix = 'codex-quota-keeper'

function Get-RepoRoot {
    # This file lives at <root>/codex-quota-keeper/tools/, three levels down.
    # Get-Item .FullName rather than Resolve-Path .Path: from an 8.3 temp path the
    # two disagree with what Get-ChildItem and git report (the CQK-033 bug), and a
    # release script that mixes path forms is only ever discovered at build time.
    $dir = Split-Path -Parent $PSCommandPath
    return (Get-Item -LiteralPath (Join-Path $dir '..\..')).FullName
}

function Invoke-Git {
    # -C so the caller never has to Push-Location (and never leaks a location
    # change into the rest of the script on failure).
    param([string]$RepoRoot, [string[]]$GitArgs)
    # PS 7.3+ turns a native command's stderr line into an ErrorRecord under
    # $ErrorActionPreference='Stop', and git writes plenty of harmless prose to
    # stderr - so the merge has to happen with 'Continue' in force, and the
    # exit code checked afterwards. 'Args' is deliberately not the parameter
    # name: it would shadow the $args automatic variable.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $RepoRoot @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    $text = @($out | ForEach-Object { "$_" })
    if ($code -ne 0) {
        throw "git $($GitArgs -join ' ') failed (exit $code): $([string]::Join(' | ', $text))"
    }
    # Leading comma keeps this an array: `git rev-parse HEAD` emits one line, and
    # a bare `return $array` unrolls a single-element array to String, which would
    # make `(Invoke-Git ...)[0]` the first *character* of the sha.
    return , $text
}

function Get-FileSha256 {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $hash = [System.Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
    }
}

function Get-ForbiddenArtifactEntry {
    <#
    .Synopsis
    Which artifact entries must never ship.
    .Description
    The patterns are anchored on the packaged prefix so an unrelated top-level path
    cannot collide with them, and the file-extension rule deliberately is not: a
    private key can sit anywhere. Everything the gate is supposed to catch is
    already gitignored, so a hit means .gitignore broke or somebody force-added.
    #>
    param([string]$Prefix, [string[]]$Entries)
    return @($Entries | Where-Object {
        $_ -match "(^|/)$Prefix/(runtime|runtimes|history)/" -or
        $_ -match "(^|/)$Prefix/config\.json$" -or
        $_ -match '\.(env|pem|key|pfx)$' -or
        $_ -match '(^|/)\.git/'
    })
}

function Get-MissingRequiredEntry {
    # The four paths a user needs to install anything. A prefix filter that
    # silently matched nothing would archive an empty tree and still exit 0.
    param([string]$Prefix, [string[]]$Entries)
    return @(foreach ($required in @("$Prefix/scripts/runner.ps1", "$Prefix/install.cmd", "$Prefix/config.example.jsonc", "$Prefix/README.md")) {
        if ($Entries -notcontains $required) { $required }
    })
}

function Read-Sha256Sums {
    # Parse (and be lenient about) the GNU `sha256sum` two-space / star-binary
    # line format, so a checksum file produced elsewhere still verifies.
    param([string]$Path)
    $map = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') { continue }
        $map[[string]$Matches[2].Trim()] = ([string]$Matches[1]).ToLowerInvariant()
    }
    return $map
}

function Remove-FailedArtifact {
    # An artifact that no SHA256SUMS.txt describes is worse than no artifact: it can
    # still be attached to a release by somebody who trusts the filename. Everything
    # that fails after the ZIP exists goes through here.
    param([string]$Path, [string]$Reason)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Write-Host "artifact removed - $Reason" -ForegroundColor Red
}

function Get-ReleaseVersion {
    # Single source of truth for the shipped version string: read it out of the
    # commit being packaged, not out of the working tree. A ZIP called v1.0 whose
    # status.cmd prints 0.9.0 is a support conversation waiting to happen.
    param([string]$RepoRoot, [string]$Commit, [string]$Prefix)
    # Double-quoted regex so the single quotes around the literal survive without
    # having to double them (a single-quoted here-regex is how this first broke).
    $common = Invoke-Git $RepoRoot @('show', "${Commit}:$Prefix/scripts/common.ps1")
    $verLine = @($common | Where-Object { $_ -match "CQK_VERSION\s*=\s*'([^']+)'" } | Select-Object -First 1)
    if ($verLine.Count -eq 0) { throw "could not read `$CQK_VERSION from ${Commit}:$Prefix/scripts/common.ps1" }
    return [regex]::Match([string]$verLine[0], "'([^']+)'").Groups[1].Value
}

function Test-Sha256Sums {
    <#
    .Returns
    @{ ok = <bool>; lines = @('OK   name  hash' / 'FAIL ...') } - never throws, so
    the CLI tail decides how to fail and the test can assert on the structure.
    #>
    param([string]$OutDir)
    $sumsPath = Join-Path $OutDir 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $sumsPath)) {
        return @{ ok = $false; lines = @("no SHA256SUMS.txt in $OutDir") }
    }
    $expected = Read-Sha256Sums $sumsPath
    if ($expected.Count -eq 0) {
        return @{ ok = $false; lines = @("$sumsPath has no parsable lines") }
    }
    $lines = @(); $fail = 0
    foreach ($name in $expected.Keys) {
        $p = Join-Path $OutDir $name
        if (-not (Test-Path -LiteralPath $p)) {
            $lines += "FAIL $name`n     file is missing from $OutDir"
            $fail++
            continue
        }
        $actual = Get-FileSha256 $p
        if ($actual -eq $expected[$name]) { $lines += "OK   $name  $actual" }
        else {
            $lines += "FAIL $name`n     expected $($expected[$name])`n     actual   $actual"
            $fail++
        }
    }
    return @{ ok = ($fail -eq 0); lines = $lines }
}

function Invoke-BuildRelease {
    <#
    .Returns
    @{ zip; zipName; sha256; commit; version; entries }
    .Throws
    on any refused precondition: dirty tree, bad version, secret hit, forbidden
    entry, missing required entry, checksum that does not round-trip.
    #>
    param(
        [string]$RepoRoot,
        [string]$Version = '',
        [string]$OutDir = '',
        [string]$Ref = 'HEAD',
        [switch]$DirtyOk,
        # Empty means "the packaged project", i.e. $script:ReleasePrefix. Resolved
        # in the body rather than as a parameter default: a default expression is
        # evaluated in the caller's scope once this file is dot-sourced, and a
        # packager that silently archives the wrong prefix produces a clean-looking
        # empty ZIP. Tests override it to build a throwaway repository.
        [string]$Prefix = ''
    )
    if (-not $Prefix) { $Prefix = $script:ReleasePrefix }
    if (-not $OutDir) { $OutDir = Join-Path $RepoRoot "$Prefix\tools\dist" }

    Invoke-Git $RepoRoot @('rev-parse', '--git-dir') | Out-Null

    # The secret gate is wired before anything that needs a commit: a checkout
    # without the scanner (or without a single commit yet) is refused for the reason
    # that matters, not with an unrelated git error from further downstream.
    $scanner = Join-Path $RepoRoot "$Prefix\tests\secret-scan.ps1"
    if (-not (Test-Path -LiteralPath $scanner)) {
        throw "expected $scanner to exist; refusing to build without the secret gate"
    }

    # Resolve the ref to a full commit sha first: everything downstream is keyed on
    # the sha, so `HEAD` moving between the file listing and the archive cannot
    # produce a ZIP whose manifest is from one commit and whose bytes from another.
    $commit = (Invoke-Git $RepoRoot @('rev-parse', $Ref))[0]
    if ($commit -notmatch '^[0-9a-f]{40}$') { throw "ref '$Ref' did not resolve to a commit sha" }
    if (-not $Version) { $Version = Get-ReleaseVersion -RepoRoot $RepoRoot -Commit $commit -Prefix $Prefix }
    if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') {
        throw "version '$Version' is not a sane semver-ish tag suffix (e.g. 0.9.0-beta)"
    }

    if (-not $DirtyOk) {
        # Only files under the packaged prefix matter: an unrelated dirty doc must
        # not block a release, and a dirty script must.
        # Two statements, not one piped expression: Invoke-Git returns a wrapped
        # array, and piping it straight into @(... | Where-Object) nests it - the
        # single line then counts as one item and stringifies as System.Object[]
        # in the message below, hiding which file is dirty.
        $dirty = Invoke-Git $RepoRoot @('status', '--porcelain', '--', $Prefix)
        $dirty = @($dirty | Where-Object { $_ -ne '' })
        if ($dirty.Count -gt 0) {
            throw "working tree under '$Prefix/' is not clean ($($dirty.Count) path(s)) - the artifact would not be reproducible from the commit it names. Commit or stash: $($dirty -join ' | '). Pass -DirtyOk only for a throwaway dry run."
        }
    }

    # ---- secret gate (CQK-033 -> CQK-035 link) --------------------------------
    # The scanner is the repository-wide one; run it on the checkout before anything
    # is archived so a credential cannot ride into a public artifact. Dot-sourced
    # and called as a function rather than `&`ed as a script: the script's own CI
    # tail would `exit` the process, and a packager that kills its own shell on a
    # clean run is not a packager.
    . $scanner
    $scan = Invoke-SecretScan -Root $RepoRoot
    if (@($scan.issues).Count -gt 0) {
        foreach ($i in $scan.issues) { Write-Host "SECRET HIT: $i" -ForegroundColor Red }
        throw "secret scan failed ($(@($scan.issues).Count) issue(s) across $($scan.files) files) - refusing to build a release artifact"
    }

    # ---- build ----------------------------------------------------------------
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $zipName = "${Prefix}-v${Version}.zip"
    $zipPath = Join-Path $OutDir $zipName
    # Overwrite-able on purpose: rebuilding the same commit must be a no-op, and a
    # stale leftover from a different commit is caught by the entry checks below.
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    # core.autocrlf=false + core.eol=lf: archive the blobs byte-for-byte as
    # committed, independent of the packager's checkout settings.
    Invoke-Git $RepoRoot @('-c', 'core.autocrlf=false', 'archive', '--format=zip', "--output=$zipPath", $commit, '--', $Prefix) | Out-Null
    if (-not (Test-Path -LiteralPath $zipPath)) { throw "git archive reported success but $zipName is missing" }

    # What went in, read back out of the ZIP rather than from an assumed file list.
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try { $entries = @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }

    $forbidden = Get-ForbiddenArtifactEntry -Prefix $Prefix -Entries $entries
    if ($forbidden.Count -gt 0) {
        Remove-FailedArtifact $zipPath 'local state or key material inside the artifact'
        throw "refusing to publish an artifact containing local state or key material: $($forbidden -join ' | ')"
    }
    $missing = Get-MissingRequiredEntry -Prefix $Prefix -Entries $entries
    if ($missing.Count -gt 0) {
        Remove-FailedArtifact $zipPath "$($missing[0]) is not in the artifact"
        throw "artifact is missing required entries: $($missing -join ' | ') - the packaged prefix is wrong"
    }

    $sha = Get-FileSha256 $zipPath
    $sumsPath = Join-Path $OutDir 'SHA256SUMS.txt'
    # Two-space text mode (the sha256sum convention), LF-terminated: `sha256sum -c`
    # must work from WSL or Linux, not only from this script.
    [System.IO.File]::WriteAllText($sumsPath, "$sha  $zipName`n", (New-Object System.Text.UTF8Encoding($false)))

    # Self-check: re-read what we just wrote, so a truncated write or a hash typo in
    # this file's own format cannot pass quietly.
    $round = Read-Sha256Sums $sumsPath
    if ($round[$zipName] -ne $sha) {
        Remove-FailedArtifact $zipPath 'SHA256SUMS.txt did not round-trip'
        throw "SHA256SUMS.txt did not round-trip (wrote $sha, read $($round[$zipName]))"
    }

    return @{
        zip     = $zipPath
        zipName = $zipName
        sha256  = $sha
        commit  = $commit
        version = $Version
        entries = $entries
    }
}

# ---- CLI ---------------------------------------------------------------------
# The guard doubles as the library marker: dot-sourcing this file for tests or for
# another script defines the functions and stops, while `& file.ps1` (and the
# script's own `exit`) only happens from the command line.
if ($MyInvocation.InvocationName -ne '.') {
    $repoRoot = Get-RepoRoot
    try {
        if ($VerifyOnly) {
            $target = if ($OutDir) { $OutDir } else { Join-Path $repoRoot "codex-quota-keeper\tools\dist" }
            $check = Test-Sha256Sums -OutDir $target
            foreach ($l in $check.lines) {
                if ($l.StartsWith('OK')) { Write-Host $l -ForegroundColor Green } else { Write-Host $l -ForegroundColor Red }
            }
            if (-not $check.ok) { exit 1 }
            exit 0
        }
        $built = Invoke-BuildRelease -RepoRoot $repoRoot -Version $Version -OutDir $OutDir -Ref $Ref -DirtyOk:$DirtyOk
    } catch {
        Write-Host "BUILD REFUSED: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    Write-Host "artifact : $($built.zip)"
    Write-Host "entries  : $(@($built.entries).Count) file(s), prefix $script:ReleasePrefix/"
    Write-Host "commit   : $($built.commit)"
    Write-Host "version  : $($built.version)"
    Write-Host "sha256   : $($built.sha256)"
    Write-Host ''
    Write-Host 'Next step (a human runs this; nothing is published here):' -ForegroundColor Cyan
    Write-Host "  gh release create v$($built.version) '$($built.zip)' --verify-tag ``" -ForegroundColor Cyan
    Write-Host "    --title 'Codex Quota Keeper v$($built.version)' --notes-file <release notes>" -ForegroundColor Cyan
    exit 0
}
