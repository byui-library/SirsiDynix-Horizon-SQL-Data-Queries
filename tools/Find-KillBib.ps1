<#
.SYNOPSIS
    Locates Horizon's KillBib.exe on this machine.

.DESCRIPTION
    Searches the known SirsiDynix/Horizon install roots and PATH. Returns the
    full path when exactly one copy is found.

    If more than one copy is found it does NOT choose for you. Sites commonly
    have several Horizon client installs side by side of differing versions
    (this machine has both "Horizon" and "Horizon_2"), and running a delete
    utility from the wrong client build against a live database is not a
    guess worth making automatically. Pass -Path to name the one you want.

.PARAMETER Path
    Use this exact executable instead of searching. Still validated for
    existence.

.PARAMETER All
    Return every copy found rather than requiring exactly one.

.EXAMPLE
    $exe = & tools\Find-KillBib.ps1
    & tools\Find-KillBib.ps1 -All
#>

[CmdletBinding()]
param(
    [string] $Path,
    [switch] $All
)

$ErrorActionPreference = 'Stop'

if ($Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "KillBib not found at the path given: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

# Known install roots, most specific first. Add to this list rather than
# widening the search to whole drives - a recursive scan of C:\ is slow and
# turns up copies in backups and staging folders that must never be run.
$roots = @(
    'C:\Program Files (x86)\SirsiDynix',
    'C:\Program Files\SirsiDynix',
    'C:\Program Files (x86)\Horizon',
    'C:\Program Files\Horizon',
    'C:\Horizon',
    'C:\HzSys',
    'D:\Horizon',
    'D:\Program Files (x86)\SirsiDynix'
)

$hits = New-Object System.Collections.ArrayList

foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    try {
        $found = Get-ChildItem -LiteralPath $root -Filter 'KillBib.exe' -Recurse -ErrorAction SilentlyContinue
        foreach ($f in $found) { [void] $hits.Add($f.FullName) }
    } catch { }
}

# PATH, in case the site puts the client utilities there
$onPath = Get-Command 'KillBib.exe' -ErrorAction SilentlyContinue
if ($onPath) { [void] $hits.Add($onPath.Source) }

$unique = @($hits | Sort-Object -Unique)

if ($unique.Count -eq 0) {
    throw @"
KillBib.exe was not found in any known install root.

Searched:
$($roots -join "`n")
...and PATH.

If Horizon is installed elsewhere, pass the path explicitly:
    tools\Find-KillBib.ps1 -Path 'D:\SomeWhere\KillBib.exe'
"@
}

if ($All) { return $unique }

if ($unique.Count -gt 1) {
    $list = ($unique | ForEach-Object { "  $_" }) -join "`n"
    throw @"
More than one KillBib.exe was found. Choose deliberately - different Horizon
client builds against a live database is not a safe automatic guess.

$list

Re-run naming the one you want:
    -KillBibPath '<full path>'
"@
}

return $unique[0]
