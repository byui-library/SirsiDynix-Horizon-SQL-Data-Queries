<#
.SYNOPSIS
    End-to-end delete-list run: verify, build, grant, pre-flight, delete.
    One command, one confirmation.

.DESCRIPTION
    Runs the whole sequence for a "records created by <user> on <date> whose 590
    mentions <term>" removal:

      1  Connect and verify the login
      2  Count the selection          - must equal -ExpectedRows
      3  Discriminator check          - has the 590 filter ever excluded anything?
      4  Create the delete-list table - dropped and recreated, PK on bib#
      5  Populate it                  - in a transaction, count-checked, committed
      6  Grant SELECT to staff        - skipped if -StaffPrincipal is omitted
      7  Pre-flight                   - orphaned codes, row count, audit file
      8  CONFIRM                      - typed row count, unless -Yes
      9  KillBib                      - the irreversible part
     10  Post-verify                  - confirm the bibs are gone

    Steps 1-7 change nothing in the catalog. Step 4-6 create and populate the
    list table only. Step 9 is the only destructive step, and everything before
    it is designed to fail before reaching it.

    THERE IS NO DRY-RUN IN KILLBIB. Its /w flag documents that bib/bib_control
    rows are wiped by default; /k merely widens that to items, copies and circ
    data. Running without /k is not a preview.

.PARAMETER ExpectedRows
    The row count you have already reviewed and signed off. The run aborts if
    the live selection does not match it exactly - that mismatch means the data
    drifted since your review.

.PARAMETER Trial
    Opt in to a single-bib trial delete (via /b and /e) before the full run.
    Off by default.

.PARAMETER Yes
    Skip the typed confirmation. Intended for a scheduled or repeat run of a
    sequence already exercised by hand.

.EXAMPLE
    tools\Invoke-DeleteListRun.ps1 -Server ILSSERVER -Database ILSDB `
        -Table ProQuest_CAT_20260825_DeleteList `
        -CreateUser CATALOGER -CreateDate 2026-08-25 -ExpectedRows 6790 `
        -StaffPrincipal HorizonStaff -Brutal
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string]   $Server,
    [Parameter(Mandatory=$true)] [string]   $Database,

    # KillBib /r. A Horizon staff identity, entirely separate from the SQL
    # login in -Credential (/u). KillBib authenticates to SQL Server first,
    # prints "Logged in to <server>\..\<db>", and then waits on this. Omitting
    # it makes KillBib hang after login with no visible prompt, which is what
    # happened on 2026-08-27. Mandatory so it is always asked for.
    [Parameter(Mandatory=$true,
        HelpMessage='Horizon staff User ID (/r) - your Horizon client login, NOT the SQL login')]
    [string] $HorizonUserId,

    # KillBib /l. A Horizon location code, validated against the location table
    # in step 1 before anything else runs - a bad code fails there rather than
    # stalling KillBib.
    [Parameter(Mandatory=$true,
        HelpMessage='Horizon location code (/l) - must exist in the location table')]
    [string] $Location,

    [Parameter(Mandatory=$true)] [string]   $Table,
    [Parameter(Mandatory=$true)] [string]   $CreateUser,
    [Parameter(Mandatory=$true)] [datetime] $CreateDate,
    [Parameter(Mandatory=$true)] [int]      $ExpectedRows,

    [string]   $NoteTerm     = 'ProQuest',
    [string]   $NoteTag      = '590',
    [string]   $Epoch        = '1970-01-01',

    # Discriminator scope. bib_control has no index on create_user, so this
    # check is a table scan - it MUST be bounded or it runs for minutes.
    [datetime] $DiscriminatorFrom,
    [int]      $DiscriminatorTimeout = 90,
    [switch]   $SkipDiscriminator,

    [string] $StaffPrincipal,
    [string] $KillBibPath,
    [switch] $Brutal,
    [switch] $Trial,
    [switch] $Yes,
    [switch] $WhatIfOnly,
    [System.Management.Automation.PSCredential] $Credential
)

$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- identifier guards -----------------------------------------------------
# These values are concatenated into SQL. Nothing unvalidated goes near a query.
. (Join-Path $toolsDir 'HorizonSql.ps1')

# Identifier + KillBib's 31-character /t truncation limit, one definition.
Test-HorizonTableName -Table $Table
if ($StaffPrincipal -and $StaffPrincipal -notmatch '^[A-Za-z_][A-Za-z0-9_\\\- ]*$') { throw "StaffPrincipal '$StaffPrincipal' looks unsafe." }
if ($NoteTag        -notmatch '^[0-9A-Za-z]{3}$')          { throw "NoteTag '$NoteTag' should be a 3-character MARC tag." }
if ($NoteTerm       -match "'")                            { throw "NoteTerm must not contain a quote." }
if ($CreateUser     -match "'")                            { throw "CreateUser must not contain a quote." }
if ($Location       -match "'")                            { throw "Location must not contain a quote." }
if ($HorizonUserId  -match "'")                            { throw "HorizonUserId must not contain a quote." }

$dateLiteral = $CreateDate.ToString('yyyy-MM-dd')
$stepNo = 0

# Default the discriminator window to the 6 months before the target date.
# Wide enough to catch occasional hand-created records, narrow enough that the
# unindexed create_user scan stays quick.
if (-not $PSBoundParameters.ContainsKey('DiscriminatorFrom')) {
    $DiscriminatorFrom = $CreateDate.AddMonths(-6)
}

# --- output helpers --------------------------------------------------------
function Write-Step {
    param([string] $Text)
    $script:stepNo++
    Write-Host ""
    Write-Host ("[{0}] {1}" -f $script:stepNo, $Text) -ForegroundColor Cyan
}
function Write-Ok   { param([string]$m) Write-Host "     OK    $m" -ForegroundColor Green }
function Write-Info { param([string]$m) Write-Host "           $m" -ForegroundColor DarkGray }
function Write-Warn { param([string]$m) Write-Host "     WARN  $m" -ForegroundColor Yellow }
function Fail       { param([string]$m) Write-Host "     FAIL  $m" -ForegroundColor Red; throw $m }

# --- SQL helpers -----------------------------------------------------------
function New-Conn {
    param([System.Management.Automation.PSCredential] $Cred)
    New-HorizonConnection -Server $Server -Database $Database -Credential $Cred -AppName 'DeleteListRun'
}
function Get-Table {
    param($Conn, [string]$Sql, [int]$Timeout = 600)
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $Timeout
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    $dt = New-Object System.Data.DataTable
    [void] $da.Fill($dt)
    # ,$dt - PowerShell enumerates a DataTable into DataRows on return; the
    # leading comma keeps the table itself intact.
    return ,$dt
}
function Get-Scalar {
    param($Conn, [string]$Sql, [int]$Timeout = 600)
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $Timeout
    return $cmd.ExecuteScalar()
}
function Invoke-NonQuery {
    param($Conn, [string]$Sql, [int]$Timeout = 600)
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $Timeout
    return $cmd.ExecuteNonQuery()
}

# The selection predicate. Defined ONCE and reused for the count, the
# discriminator and the INSERT, so the three can never diverge - the same
# guarantee the README makes about Query A / Query C / the load.
$predicate = @"
bc.create_user = '$CreateUser'
  AND bc.create_date = DATEDIFF(day, '$Epoch', '$dateLiteral')
  AND EXISTS (
        SELECT 1 FROM bib p
        WHERE p.[bib#] = bc.[bib#]
          AND p.tag = '$NoteTag'
          AND p.text LIKE '%$NoteTerm%')
"@

# ===========================================================================
Write-Host ""
Write-Host ("=" * 70)
Write-Host " Horizon delete-list run" -ForegroundColor White
Write-Host ("=" * 70)
Write-Host " server     : $Server / $Database"
Write-Host " horizon id : $HorizonUserId  (KillBib /r - not the SQL login)"
Write-Host " location   : $Location  (KillBib /l)"
Write-Host " selection  : create_user = '$CreateUser', create_date = $dateLiteral"
Write-Host "              with a $NoteTag containing '$NoteTerm'"
Write-Host " table      : dbo.$Table"
Write-Host " expected   : $ExpectedRows rows"
Write-Host " kill mode  : $(if ($Brutal) { '/k  - items, copies and circ data go too' } else { 'default - bib/bib_control wiped, items remain' })"
Write-Host ("=" * 70)

if (-not $Credential) {
    $Credential = Get-Credential -Message "Database login for $Server / $Database (also used for KillBib /u /p)"
}
if (-not $Credential) { throw "No credential supplied." }

$conn = $null
try {

# --- 1 connect -------------------------------------------------------------
Write-Step "Connecting"
# The connection and the identity query are caught separately, so a failure in
# one is never reported as the other. An earlier version wrapped both and
# reported a query bug as "cannot connect", which sent debugging the wrong way.
try {
    $conn = New-Conn -Cred $Credential
} catch {
    Fail "cannot connect to $Server / $Database as $($Credential.UserName): $($_.Exception.Message)"
}
try {
    $who = Get-Table -Conn $conn -Sql "SELECT SUSER_SNAME() AS [login], DB_NAME() AS [db];"
    Write-Ok "connected as $($who.Rows[0].login) to $($who.Rows[0].db)"
} catch {
    Fail "connected, but the identity query failed: $($_.Exception.Message)"
}

# Validate the /l location code now, while a connection is open. A code that
# does not exist would otherwise only surface as KillBib misbehaving, which is
# far harder to read than a failure here.
$locName = Get-Scalar -Conn $conn -Sql "SELECT MAX(name) FROM location WHERE location = '$Location';"
if ($null -eq $locName -or $locName -is [DBNull]) {
    Write-Host "     FAIL  location '$Location' does not exist in the location table" -ForegroundColor Red
    $near = Get-Table -Conn $conn -Sql @"
SELECT TOP 15 location AS [location], name AS [name]
FROM location ORDER BY location;
"@
    Write-Info "first 15 valid location codes:"
    foreach ($row in $near.Rows) {
        Write-Info ("  {0,-8} {1}" -f $row['location'], $row['name'])
    }
    Fail "bad -Location value"
}
Write-Ok "location '$Location' valid ($locName)"

# --- 2 count the selection -------------------------------------------------
Write-Step "Counting the selection"
$actual = [int] (Get-Scalar -Conn $conn -Sql "SELECT COUNT(*) FROM bib_control bc WHERE $predicate;")
if ($actual -ne $ExpectedRows) {
    Fail "selection returns $actual rows, expected $ExpectedRows. The data has drifted since review - stop and re-review."
}
Write-Ok "$actual rows, matches the reviewed count"

# --- 3 discriminator -------------------------------------------------------
# Does the note filter actually exclude anything? A predicate that has never
# excluded a single record is indistinguishable from one that is broken, and
# this filter's whole job is keeping hand-created records out of the delete.
Write-Step "Discriminator check - has the $NoteTag filter ever excluded anything?"
$discWarning = $false
if ($SkipDiscriminator) {
    Write-Warn "skipped at your request (-SkipDiscriminator)"
    $discWarning = $true
} else {
    # Asked as "find me an example", not "count everything". TOP 5 lets SQL
    # Server stop at the first few hits, so the common case - the filter does
    # exclude things - returns almost immediately.
    #
    # This has to be bounded. bib_control has no index on create_user (its only
    # unique index is on bib#), so an unbounded scan of a bulk-load account's
    # entire history is a full table scan with a correlated leading-wildcard
    # LIKE per row. That runs for minutes and looks like a hang.
    $discFromLit = $DiscriminatorFrom.ToString('yyyy-MM-dd')
    Write-Info "looking for records by '$CreateUser' since $discFromLit with no matching $NoteTag..."
    Write-Info "(bounded and TOP 5 - unbounded this is a full scan of bib_control)"
    try {
        $disc = Get-Table -Timeout $DiscriminatorTimeout -Conn $conn -Sql @"
SELECT TOP 5
       bc.[bib#] AS [bib#],
       DATEADD(day, bc.create_date, CAST('$Epoch' AS DATE)) AS [created]
FROM bib_control bc
WHERE bc.create_user = '$CreateUser'
  AND bc.create_date >= DATEDIFF(day, '$Epoch', '$discFromLit')
  AND NOT EXISTS (
        SELECT 1 FROM bib p
        WHERE p.[bib#] = bc.[bib#]
          AND p.tag = '$NoteTag'
          AND p.text LIKE '%$NoteTerm%')
ORDER BY bc.create_date DESC;
"@
        if ($disc.Rows.Count -gt 0) {
            Write-Ok "filter demonstrably discriminates - records by this user WITHOUT a matching $NoteTag exist:"
            foreach ($row in $disc.Rows) {
                Write-Info ("  bib# {0}  created {1:yyyy-MM-dd}" -f $row['bib#'], $row['created'])
            }
            Write-Info "those are exactly the records the $NoteTag condition keeps out of the delete"
        } else {
            Write-Warn "no excluded records found since $discFromLit."
            Write-Warn "Every record this user created in that window carries a matching $NoteTag,"
            Write-Warn "so the filter has not been observed excluding anything. It may be correct -"
            Write-Warn "or it may be matching regardless of content. Widen with -DiscriminatorFrom,"
            Write-Warn "or accept that its protective value is unproven."
            $discWarning = $true
        }
    } catch {
        Write-Warn "discriminator check did not complete: $($_.Exception.Message)"
        Write-Warn "Treating its protective value as unproven. Narrow the window with"
        Write-Warn "-DiscriminatorFrom, raise -DiscriminatorTimeout, or use -SkipDiscriminator."
        $discWarning = $true
    }
}

if ($WhatIfOnly) {
    Write-Host ""
    Write-Host "-WhatIfOnly: stopping before any table is created. Nothing was changed." -ForegroundColor Yellow
    return
}

# --- 4 create the table ----------------------------------------------------
Write-Step "Creating dbo.$Table"
# LOCK_TIMEOUT makes a blocked DDL statement fail in 20s with a named error
# instead of sitting there looking like a hang. CREATE TABLE is instantaneous
# when it is not blocked, so any wait at all here means contention - commonly
# an orphaned query from an interrupted run still holding locks.
try {
    # LOCK_TIMEOUT is SESSION-scoped, not batch-scoped. It must be reset at the
    # end of this batch or every later query on this connection inherits the
    # 20s limit - which is what broke step 6's permission read on 2026-08-27.
    # -LockTimeoutMs sets and resets LOCK_TIMEOUT in the helper's finally, so
    # an aborted batch cannot leave the session limit set - the bug that broke
    # the permission read on 2026-08-27.
    [void] (Invoke-HorizonNonQuery -Connection $conn -Timeout 60 -LockTimeoutMs 20000 -Sql @"
IF OBJECT_ID('dbo.$Table','U') IS NOT NULL DROP TABLE dbo.[$Table];
CREATE TABLE dbo.[$Table] (
    [bib#] INT NOT NULL
        CONSTRAINT [PK_$Table] PRIMARY KEY CLUSTERED ([bib#])
);
"@)
    Write-Ok "created with PRIMARY KEY CLUSTERED on [bib#]"
} catch {
    Write-Host "     FAIL  could not create dbo.$Table" -ForegroundColor Red
    Write-Info $_.Exception.Message
    Write-Info ""
    if ($_.Exception.Message -match 'Lock request time out') {
        Write-Info "The DROP was blocked. dbo.$Table already exists and something holds a"
        Write-Info "lock on it - almost always an interrupted earlier run whose session is"
        Write-Info "still open with a transaction against this table. Ctrl+C stops"
        Write-Info "PowerShell; it does not end the session on the server."
        Write-Info ""
        Write-Info "Options, in order of preference:"
        Write-Info "  1. Have a sysadmin KILL the orphaned session, then re-run."
        Write-Info "  2. Wait - the session dies when its TCP connection times out."
        Write-Info "  3. Re-run against a different -Table name to sidestep it entirely."
        Show-HorizonBlockers -Connection $conn
    } else {
        Write-Info "CREATE TABLE is instant unless something is blocking it."
        Show-HorizonBlockers -Connection $conn
    }
    throw "aborted at step 4 - nothing was changed"
}

# --- 5 populate ------------------------------------------------------------
Write-Step "Populating the list"
# Deliberately NOT wrapped in an explicit transaction.
#
# The INSERT scans bib_control and bib and takes a while. Held inside an open
# transaction, an interrupted run (Ctrl+C kills the client but not the server
# session) leaves that transaction open, holding an exclusive lock on the table
# - which then blocks the next run's DROP and looks like a hang. That is
# exactly what happened on 2026-08-27.
#
# The transaction bought very little: this is a disposable scratch table, so a
# wrong row count is fixed by dropping and rebuilding, not by rollback. Letting
# the INSERT autocommit removes the orphaned-lock hazard entirely.
Write-Info "inserting (this scans bib_control and bib - allow a minute)..."
$inserted = Invoke-NonQuery -Timeout 900 -Conn $conn -Sql @"
INSERT INTO dbo.[$Table] ([bib#])
SELECT bc.[bib#] FROM bib_control bc WHERE $predicate;
"@
if ($inserted -ne $ExpectedRows) {
    Write-Warn "inserted $inserted rows, expected $ExpectedRows - dropping the table"
    try { [void] (Invoke-NonQuery -Timeout 60 -Conn $conn -Sql "DROP TABLE dbo.[$Table];") } catch {}
    Fail "row count mismatch - the table was dropped, nothing is left behind."
}
Write-Ok "$inserted rows inserted"

# --- 6 grant ---------------------------------------------------------------
if ($StaffPrincipal) {
    Write-Step "Granting SELECT to [$StaffPrincipal]"
    [void] (Invoke-NonQuery -Timeout 60 -Conn $conn -Sql "GRANT SELECT ON dbo.[$Table] TO [$StaffPrincipal];")
    Write-Ok "GRANT SELECT executed without error"

    # Read back what actually landed. This is confirmation, not the work - the
    # GRANT above either succeeded or threw. A failure to READ the catalog
    # (blocking, permissions) must not abort a run whose table is already built
    # and populated, so this is warn-only.
    try {
        $g = Get-Table -Timeout 60 -Conn $conn -Sql @"
SELECT dp.name AS [principal], p.permission_name AS [perm], p.state_desc AS [state]
FROM sys.database_permissions p
INNER JOIN sys.database_principals dp ON dp.principal_id = p.grantee_principal_id
WHERE p.major_id = OBJECT_ID('dbo.$Table');
"@
        if ($g.Rows.Count -eq 0) {
            Write-Warn "no permissions read back for dbo.$Table - verify by hand before relying on it"
        } else {
            foreach ($row in $g.Rows) { Write-Ok "confirmed: $($row.state) $($row.perm) to $($row.principal)" }
        }
    } catch {
        Write-Warn "could not read back the permission: $($_.Exception.Message)"
        Write-Info "the GRANT itself succeeded; only the confirmation read failed. Check with:"
        Write-Info "  SELECT dp.name, p.permission_name, p.state_desc"
        Write-Info "  FROM sys.database_permissions p"
        Write-Info "  JOIN sys.database_principals dp ON dp.principal_id = p.grantee_principal_id"
        Write-Info "  WHERE p.major_id = OBJECT_ID('dbo.$Table');"
    }
} else {
    Write-Step "Granting SELECT - skipped (no -StaffPrincipal given)"
    Write-Info "pass -StaffPrincipal <name> to grant read access"
}

$conn.Close()

# --- 7 pre-flight ----------------------------------------------------------
Write-Step "Pre-flight checks"
$ok = & (Join-Path $toolsDir 'Test-DeleteListPreflight.ps1') `
        -Server $Server -Database $Database -Table $Table `
        -ExpectedRows $ExpectedRows -Credential $Credential
if (-not $ok) { Fail "pre-flight did not pass. The list table exists but nothing was deleted." }

# --- 8 confirm -------------------------------------------------------------
Write-Step "Confirmation"
Write-Host ""
Write-Host ("-" * 70) -ForegroundColor Red
Write-Host " ABOUT TO DELETE $ExpectedRows BIB RECORDS. THIS CANNOT BE UNDONE." -ForegroundColor Red
Write-Host " KillBib has no dry-run: bib and bib_control rows go by default," -ForegroundColor Red
if ($Brutal) {
Write-Host " and /k is set, so items, copies and circulation data go too." -ForegroundColor Red
}
if ($discWarning) {
Write-Host "" -ForegroundColor Red
Write-Host " NOTE: the $NoteTag filter has never been observed excluding a record." -ForegroundColor Yellow
Write-Host " Its protective value against hand-created records is unproven." -ForegroundColor Yellow
}
Write-Host ("-" * 70) -ForegroundColor Red

if (-not $Yes) {
    Write-Host ""
    Write-Host " Type the row count ($ExpectedRows) to proceed, anything else to abort:" -ForegroundColor Red
    $answer = Read-Host "  rows"
    if ($answer -ne "$ExpectedRows") {
        Write-Host ""
        Write-Host "Aborted. The list table remains; nothing was deleted." -ForegroundColor Yellow
        return
    }
} else {
    Write-Warn "-Yes given: proceeding without confirmation"
}

# --- 9 KillBib -------------------------------------------------------------
Write-Step "Running KillBib"
$kbArgs = @{
    Server = $Server; Database = $Database; Table = $Table
    ExpectedRows = $ExpectedRows; Credential = $Credential
}
if ($Brutal)        { $kbArgs.Brutal        = $true }
if ($KillBibPath)   { $kbArgs.KillBibPath   = $KillBibPath }
# /r is mandatory - always passed through, never conditional.
$kbArgs.HorizonUserId = $HorizonUserId
# /l is mandatory - always passed through.
$kbArgs.Location = $Location
if (-not $Trial)    { $kbArgs.SkipTrial     = $true; $kbArgs.Force = $true }
# Step 7 already ran pre-flight and step 8 already took the typed confirmation.
# Without these the wrapper repeats both - a second orphan scan, a second audit
# CSV for the same run, and a second prompt for the same acknowledgement.
$kbArgs.SkipPreflight = $true
$kbArgs.Yes           = $true

& (Join-Path $toolsDir 'Invoke-KillBib.ps1') @kbArgs
$kbExit = $LASTEXITCODE

# --- 10 post-verify --------------------------------------------------------
Write-Step "Post-run verification"
$conn = New-Conn -Cred $Credential
try {
    $left = [int] (Get-Scalar -Conn $conn -Sql @"
SELECT COUNT(*) FROM bib_control bc
INNER JOIN dbo.[$Table] d ON d.[bib#] = bc.[bib#];
"@)
    if ($left -eq 0) {
        Write-Ok "all $ExpectedRows listed bibs are gone from bib_control"
    } else {
        Write-Warn "$left of $ExpectedRows listed bibs are still present"
        Write-Info "if KillBib stopped early, resume from the bib# it reported:"
        Write-Info "  tools\Invoke-KillBib.ps1 -Server $Server -Database $Database ``"
        Write-Info "      -Table $Table -ExpectedRows $ExpectedRows ``"
        Write-Info "      -HorizonUserId $HorizonUserId -Location $Location ``"
        Write-Info "      -ResumeFrom <failing-bib#> -SkipTrial -Force$(if($Brutal){' -Brutal'})"
    }

    $items = [int] (Get-Scalar -Conn $conn -Sql @"
SELECT COUNT(*) FROM item i
INNER JOIN dbo.[$Table] d ON d.[bib#] = i.[bib#];
"@)
    if ($items -gt 0) {
        Write-Warn "$items item row(s) remain against listed bibs"
        Write-Info "KillBib skips copies with issues or predictions attached - expected for serials"
    } else {
        Write-Ok "no item rows remain against listed bibs"
    }
} finally { $conn.Close(); $conn = $null }

Write-Host ""
Write-Host ("=" * 70)
if ($kbExit -eq 0 -and $left -eq 0) {
    Write-Host " Run complete." -ForegroundColor Green
} else {
    Write-Host " Run finished with issues - read the warnings above." -ForegroundColor Yellow
}
Write-Host ("=" * 70)
Write-Host ""

} finally {
    if ($conn -and $conn.State -eq 'Open') { $conn.Close() }
}
