# Codex Quota Keeper - machine-readable status (doc 02 §5).
# Same read-only data collection as status.ps1, emitted as JSON.

param(
    [string]$KeeperRoot = '',
    [string]$ConfigFile = '',
    [switch]$Live
)

$scriptDir = Split-Path -Parent $PSCommandPath
# Capture before dot-sourcing status.ps1: its param block re-binds these names
# in this scope with empty defaults.
$JsonKeeperRoot = $KeeperRoot
$JsonConfigFile = $ConfigFile
$JsonLive = [bool]$Live
. (Join-Path $scriptDir 'status.ps1')

$s = Get-KeeperStatus -KeeperRoot $JsonKeeperRoot -ConfigFile $JsonConfigFile -Live:$JsonLive
ConvertTo-Json -InputObject $s -Depth 8
exit 0
