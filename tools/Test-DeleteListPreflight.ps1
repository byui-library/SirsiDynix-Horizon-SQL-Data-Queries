<#
.SYNOPSIS
    Pre-flight checks to run against a Horizon delete-list table before KillBib
    is launched.

.DESCRIPTION
    Four checks, all read-only. Every one of them exists because it is cheaper
    to fail here than partway through an irreversible delete:

      1. Connectivity   - the server, database and SQL login actually work.
      2. Table + count  - the delete-list table exists and holds exactly the
                          number of rows you expect.
      3. Orphaned codes - items on the list carrying location / collection /
                          itype codes that are missing from their parent table.
                          This is the documented KillBib killer: its statistics
                          insert hits FK_stat_data_location, the delete rolls
                          back, and the run stops midway.
      4. Audit file     - the exact bib# list written to a timestamped CSV
                          before anything is deleted.

    Uses System.Data.SqlClient directly, so no SqlServer PowerShell module is
    required. SQL authentication is used deliberately: it exercises the same
    login KillBib will use, which is the point of check 1.

    Returns $true when every check passes, $false otherwise. Nothing is
    modified in the database.

.PARAMETER AuditDirectory
    Where to write the bib# audit file. Defaults to .\killbib-audit\, which the
    repository .gitignore already excludes via *.csv - the file holds catalog
    data and must never be committed.

.EXAMPLE
    tools\Test-DeleteListPreflight.ps1 -Server ILSSERVER -Database ILSDB `
        -Table ProQuest_CAT_20260825_DeleteList -ExpectedRows 6790
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $Server,
    [Parameter(Mandatory=$true)] [string] $Database,
    [Parameter(Mandatory=$true)] [string] $Table,
    [Parameter(Mandatory=$true)] [int]    $ExpectedRows,
    [System.Management.Automation.PSCredential] $Credential,
    [string] $AuditDirectory
)

$ErrorActionPreference = 'Stop'

if (-not $AuditDirectory) {
    $AuditDirectory = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'killbib-audit'
}

if (-not $Credential) {
    $Credential = Get-Credential -Message "SQL login for $Server / $Database (the same login KillBib will use)"
}
if (-not $Credential) { throw "No credential supplied." }

# --- helpers ---------------------------------------------------------------

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HorizonSql.ps1')

function Write-Check {
    param([string] $Name, [bool] $Pass, [string] $Detail)
    if ($Pass) { $mark = '  PASS'; $col = 'Green' } else { $mark = '  FAIL'; $col = 'Red' }
    Write-Host ("{0}  {1}" -f $mark, $Name) -ForegroundColor $col
    if ($Detail) { Write-Host ("        {0}" -f $Detail) -ForegroundColor DarkGray }
}

# Validates the identifier AND KillBib's 31-character truncation limit. This
# script is documented as runnable standalone, so it must enforce the same rule
# the callers do - otherwise all four checks pass on a 35-character table and
# KillBib then fails on "Invalid object name".
Test-HorizonTableName -Table $Table

$allPass = $true
Write-Host ""
Write-Host "KillBib pre-flight - $Database.dbo.$Table" -ForegroundColor Cyan
Write-Host ("=" * 62)

$conn = $null
try {
    # --- 1. connectivity ---------------------------------------------------
    try {
        $conn = New-HorizonConnection -Server $Server -Database $Database -Credential $Credential -AppName "KillBib-Preflight"
        $v = (Invoke-HorizonTable -Connection $conn -Timeout 120 -Sql "SELECT SUSER_SNAME() AS [login], DB_NAME() AS [db];").Rows[0]
        Write-Check -Name "Connectivity and login" -Pass $true -Detail "connected as $($v.login) to $($v.db)"
    } catch {
        Write-Check -Name "Connectivity and login" -Pass $false -Detail $_.Exception.Message
        Write-Host ""
        Write-Host "Cannot continue without a connection." -ForegroundColor Red
        return $false
    }

    # --- 2. table exists and row count matches -----------------------------
    $exists = (Invoke-HorizonTable -Connection $conn -Timeout 120 -Sql "SELECT OBJECT_ID('dbo.$Table','U') AS [id];").Rows[0].id
    if ($exists -is [DBNull]) {
        Write-Check -Name "Delete-list table exists" -Pass $false -Detail "dbo.$Table not found"
        return $false      # nothing below can run without the table
    }
    Write-Check -Name "Delete-list table exists" -Pass $true -Detail "dbo.$Table"

    $actual = [int] (Invoke-HorizonScalar -Connection $conn -Timeout 120 -Sql "SELECT COUNT(*) FROM dbo.[$Table];")
    if ($actual -eq $ExpectedRows) {
        Write-Check -Name "Row count matches expected" -Pass $true -Detail "$actual rows"
    } else {
        Write-Check -Name "Row count matches expected" -Pass $false -Detail "expected $ExpectedRows, found $actual - do NOT proceed"
        $allPass = $false
    }

    # --- 3. orphaned parent codes -----------------------------------------
    # An item on the delete list carrying a code absent from its parent table
    # makes KillBib's statistics insert fail on FK_stat_data_*, rolling the
    # delete back partway through.
    # One definition, shared with Show-OrphanDiagnostic in Invoke-KillBib.ps1.
    # Previously two copies returning different columns, so adding a code type
    # to one left the other silently blind to it.
    $orphans = Get-HorizonOrphanCodes -Connection $conn -Table $Table
    if ($orphans.Rows.Count -eq 0) {
        Write-Check -Name "No orphaned location/collection/itype codes" -Pass $true -Detail "all item codes resolve to a parent row"
    } else {
        Write-Check -Name "No orphaned location/collection/itype codes" -Pass $false -Detail "$($orphans.Rows.Count) orphaned code(s) - KillBib will fail on FK_stat_data_*"
        $allPass = $false
        Write-Host ""
        foreach ($r in $orphans.Rows) {
            Write-Host ("        {0,-11} {1,-10} {2,6} items  {3,6} bibs" -f $r.code_type, $r.code, $r.items, $r.bibs) -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "        Restore the missing code to its parent table, or correct the" -ForegroundColor DarkGray
        Write-Host "        offending items. Never drop or disable the FK to force it through -" -ForegroundColor DarkGray
        Write-Host "        that writes statistics rows pointing at a code that does not exist." -ForegroundColor DarkGray
    }

    # --- 4. audit file -----------------------------------------------------
    if (-not (Test-Path -LiteralPath $AuditDirectory)) {
        New-Item -ItemType Directory -Path $AuditDirectory -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $auditPath = Join-Path $AuditDirectory ("$Table-$stamp.csv")
    $bibs = Invoke-HorizonTable -Connection $conn -Timeout 120 -Sql "SELECT [bib#] FROM dbo.[$Table] ORDER BY [bib#];"
    $sw = New-Object System.IO.StreamWriter($auditPath, $false, [System.Text.Encoding]::UTF8)
    try {
        $sw.WriteLine("bib#")
        foreach ($r in $bibs.Rows) { $sw.WriteLine($r['bib#']) }
    } finally { $sw.Dispose() }
    Write-Check -Name "Audit file written" -Pass $true -Detail "$($bibs.Rows.Count) bib# to $auditPath"

} finally {
    if ($conn -and $conn.State -eq 'Open') { $conn.Close() }
}

Write-Host ("=" * 62)
if ($allPass) {
    Write-Host "All pre-flight checks passed." -ForegroundColor Green
} else {
    Write-Host "PRE-FLIGHT FAILED - do not run KillBib until every check passes." -ForegroundColor Red
}
Write-Host ""
return $allPass
