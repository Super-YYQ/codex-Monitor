# Codex Quota Keeper - repository secret scanner (CQK-033).
#
# Scans every non-binary file under the repository root against the credential
# patterns in Get-SecretScanPattern. No path is excluded from the scan.
#
# Why this exists as a script rather than an inline workflow blob: the previous
# CI rule was `Where-Object { $_.FullName -notmatch '\\tests\\' }` - a one-line
# change that quietly removed ~20 test files and every golden snapshot from the
# scan, and nothing in the repo could notice. A scan that silently scans nothing
# is worse than no scan, so this file is (a) runnable locally and (b) asserted by
# tests/secret-scan.test.ps1.
#
# Usage (CI):  pwsh -NoProfile -File codex-quota-keeper/tests/secret-scan.ps1
# Usage (dev): pwsh -NoProfile -File codex-quota-keeper/tests/secret-scan.ps1 -Root .

param(
    # Repository root. Defaults to this script's ../.. (the checkout root).
    [string]$Root = '',
    # Relative paths (forward slashes) that MUST be discovered by the file walk.
    # Guards against a scanner that passes by finding nothing.
    [string[]]$MustScan = @('codex-quota-keeper/scripts/common.ps1', 'codex-quota-keeper/tests/github-sync.test.ps1')
)

$ErrorActionPreference = 'Stop'

function Get-SecretScanPattern {
    # Credential shapes that must never appear in the repository. Single source
    # of truth: the CI job and the tests both read this list, so a pattern added
    # here is enforced immediately and cannot drift.
    return @(
        'sk-[A-Za-z0-9_\-]{20,}',
        'ghp_[A-Za-z0-9]{20,}',
        'gh[ousr]_[A-Za-z0-9]{20,}',
        'github_pat_[A-Za-z0-9_]{20,}',
        '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----',
        # (?i) inline rather than relying on -match's default case-insensitivity:
        # this list is also handed to [regex] elsewhere, and on PowerShell 7 -match
        # stays case-insensitive but the intent should not depend on it.
        '(?i)(api[_-]?key|secret|password)\s*[=:]\s*[''"][^''"\s]{12,}'
    )
}

function Get-FakeCredentialLiteral {
    # The exact synthetic strings the sanitization fixtures need in order to prove
    # redaction works. Each is matched out of a file's text before the patterns
    # run, so the fixture files are still scanned for everything else - a real
    # credential dropped inside a test still fails the scan.
    return @(
        'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456',  # github-sync.test.ps1 (CQK-012)
        'gho_ZYXWVUTSRQPONMLKJIHGFEDCBA98765',   # github-sync.test.ps1 (CQK-012)
        'github_pat_XXXXXXXXXXXXXXXXXXXX_1234',  # github-sync.test.ps1 (CQK-012)
        'sk-fake-0123456789abcdef'               # golden-fixtures.ps1 (multi-pc-error)
    )
}

function Get-FakeCredentialFixturePath {
    # The only files allowed to carry those literals (plus this script, which has
    # to name them). Deliberately whole paths, not a directory or a glob: letting
    # a new file hold a fake token has to be a deliberate edit visible in review.
    return @(
        'codex-quota-keeper/tests/github-sync.test.ps1',
        'codex-quota-keeper/tests/golden-fixtures.ps1'
    )
}

function Get-ScannedFile {
    # Enumerates files under $Root the way CI does: everything except the .git
    # object store and known binary types. -Force so a credential hidden in a
    # dotfile is still read (.gitignore is scanned). .git is dropped afterwards by
    # relative path - its objects are zlib-compressed, so pattern-matching them
    # proves nothing either way.
    param([string]$Root)
    # Get-Item .FullName, not Resolve-Path .Path: Resolve-Path preserves the
    # 8.3 short form of a temp path (C:\Users\ADMINI~1) while Get-ChildItem
    # reports the long form, so subtracting its length produced a truncated
    # garbage prefix instead of a repo-relative path. Same call on both
    # runtimes, and it normalises the case where $Root itself is short-form.
    $base = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\', '/')
    # -ErrorAction SilentlyContinue: one unreadable path (a lock file, a broken
    # reparse point) must not abort the whole scan. What the walk loses is still
    # caught by $MustScan, and a file it *finds* but cannot read is reported as an
    # issue by Invoke-SecretScan, so nothing disappears quietly.
    $walk = @(Get-ChildItem -LiteralPath $base -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -notin '.docx', '.png', '.jpg', '.jpeg', '.gif', '.ico', '.zip', '.pdf' } |
        ForEach-Object {
            # Repo-relative with forward slashes: stable across runners and
            # directly comparable against the allowlists above. If a path ever
            # disagrees with $base in form, keep the absolute one rather than
            # emit a mangled prefix - a mismatched allowlist then fails loudly
            # through $MustScan instead of silently scanning nothing.
            $full = $_.FullName
            $rel = if ($full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $full.Substring($base.Length + 1).Replace('\', '/')
            } else {
                $full.Replace('\', '/')
            }
            [pscustomobject]@{ path = $rel; full = $full }
        })
    return , @($walk | Where-Object { $_.path -notmatch '(^|/)\.git(/|$)' })
}

function Invoke-SecretScan {
    <#
    .Returns
    @{ files = <int>; issues = <string[]> } - never throws, never prints, so the
    caller (CI step or test) decides how to fail. The three lists are parameters
    with defaults taken from the Get-* functions above, which keeps production
    behaviour single-sourced while letting tests build a controlled mini-repo.
    #>
    param(
        [string]$Root,
        [string[]]$MustScan = @(),
        [string[]]$Patterns = (Get-SecretScanPattern),
        [string[]]$FakeLiterals = (Get-FakeCredentialLiteral),
        [string[]]$FixturePaths = (Get-FakeCredentialFixturePath)
    )
    # This file declares the fake literals, so it would match the credential
    # patterns just by existing. It must not count as a *use* of them either, or
    # the staleness check below becomes self-validating and can never fire.
    $self = 'codex-quota-keeper/tests/secret-scan.ps1'

    $files = Get-ScannedFile -Root $Root
    $issues = @()

    foreach ($required in $MustScan) {
        if ($files.path -notcontains $required) {
            $issues += "scan is blind: expected to scan '$required' but it was not discovered ($($files.Count) files walked)"
        }
    }

    $uses = @{}
    foreach ($l in $FakeLiterals) { $uses[[string]$l] = 0 }

    foreach ($f in $files) {
        try {
            $text = [System.IO.File]::ReadAllText($f.full)
        } catch {
            # A file nobody can read is not a clean file.
            $issues += "unreadable file: $($f.path) - $($_.Exception.Message)"
            continue
        }
        foreach ($l in $FakeLiterals) {
            $n = ([regex]::Matches($text, [regex]::Escape([string]$l))).Count
            if ($n -eq 0) { continue }
            if ($f.path -ne $self) { $uses[[string]$l] += $n }
            # A fixture literal outside a fixture file is a finding, not a pass:
            # pasting a fake token into production code looks exactly like pasting
            # a real one, and the scanner should not be able to tell the difference.
            if ($f.path -ne $self -and $FixturePaths -notcontains $f.path) {
                $issues += "$($f.path) uses fixture credential literal but is not an allowlisted fixture: $l"
            }
            $text = $text.Replace([string]$l, 'fake-token-fixture')
        }
        foreach ($p in $Patterns) {
            if ($text -match $p) { $issues += "$($f.path) matches $p" }
        }
    }

    # The reverse direction, which is the half that rots: an allowlist entry whose
    # file or literal has gone away has to go away with it. Silent leftovers here
    # are exactly how a scan becomes blind again without anyone editing a filter.
    foreach ($fp in $FixturePaths) {
        if ($files.path -notcontains $fp) {
            $issues += "allowlisted fixture file is not present in the scan: $fp"
        }
    }
    foreach ($l in $FakeLiterals) {
        if ($uses[[string]$l] -eq 0) {
            $issues += "stale fixture allowlist entry, used by no file (only declared): $l"
        }
    }

    return @{ files = $files.Count; issues = @($issues) }
}

# Direct execution (CI step, or a developer running it locally).
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Root) {
        $Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $result = Invoke-SecretScan -Root $Root -MustScan $MustScan
    foreach ($i in $result.issues) { Write-Host "SECRET HIT: $i" -ForegroundColor Red }
    if ($result.issues.Count -gt 0) {
        Write-Host "Secret scan failed: $($result.issues.Count) issue(s) across $($result.files) file(s)." -ForegroundColor Red
        exit 1
    }
    Write-Host "No credential patterns found ($($result.files) files scanned, no path exclusions)." -ForegroundColor Green
    exit 0
}
