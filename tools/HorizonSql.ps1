<#
.SYNOPSIS
    Shared SQL and validation helpers for the delete-list scripts.

.DESCRIPTION
    Dot-source this from a script:

        . (Join-Path $PSScriptRoot 'HorizonSql.ps1')

    Dot-sourced rather than a module so callers need no Import-Module and the
    functions land in the caller's scope unchanged.

    Everything here was previously copy-pasted across Invoke-DeleteListRun.ps1,
    Invoke-KillBib.ps1 and Test-DeleteListPreflight.ps1. The copies had already
    drifted - most damagingly, only two of them set Application Name, so the
    blocking-session diagnostic could not identify sessions this tool set had
    itself opened.
#>

# No Set-StrictMode here: this file is dot-sourced, so any mode it sets leaks
# into the calling script's scope and changes how THAT script behaves.

# KillBib silently truncates the /t table name at 31 characters and then fails
# with "Invalid object name" against the truncated string. Measured 2026-08-27:
# a 35-character name arrived as 31. Capped at 30 for margin. See docs/killbib.md.
$script:KillBibMaxTableNameLength = 30

function Test-HorizonTableName {
    <#
    .SYNOPSIS
        Validates a delete-list table name for SQL safety and KillBib's limit.
    .DESCRIPTION
        Throws with an actionable message if the name is unusable. Called by
        every entry point, so no caller can route around either rule.
    #>
    param(
        [Parameter(Mandatory=$true)] [string] $Table,
        [switch] $SkipLengthCheck   # for tables never handed to KillBib
    )

    if ($Table -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Table name '$Table' is not a plain identifier. Refusing to build SQL from it."
    }
    if (-not $SkipLengthCheck -and $Table.Length -gt $script:KillBibMaxTableNameLength) {
        throw @"
Table name '$Table' is $($Table.Length) characters. KillBib truncates /t at 31
and then fails with "Invalid object name" against the truncated name. SQL Server
allows 128, so nothing on the database side catches this.

Use $($script:KillBibMaxTableNameLength) characters or fewer, e.g.:
  PQ_CAT_20260825_DeleteList   (27)
  CAT_20260825_DeleteList      (24)
"@
    }
}

function Get-HorizonPlainPassword {
    <#
    .SYNOPSIS
        SecureString -> plain text, with the unmanaged buffer zeroed.
    .DESCRIPTION
        The plaintext is unavoidable: SqlClient connection strings and KillBib's
        /p flag both take it. Keep the returned value's lifetime as short as
        possible at the call site.
    #>
    param([Parameter(Mandatory=$true)] [System.Management.Automation.PSCredential] $Credential)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function New-HorizonConnection {
    <#
    .SYNOPSIS
        Opens a SqlConnection. Caller closes it.
    .DESCRIPTION
        Application Name is always set. Show-HorizonBlockers reports
        program_name to name a blocking session, so an unnamed connection from
        these scripts would be invisible to our own diagnostic.
    #>
    param(
        [Parameter(Mandatory=$true)] [string] $Server,
        [Parameter(Mandatory=$true)] [string] $Database,
        [Parameter(Mandatory=$true)] [System.Management.Automation.PSCredential] $Credential,
        [string] $AppName = 'HorizonTools'
    )
    $pw = Get-HorizonPlainPassword -Credential $Credential
    try {
        $cs = "Server=$Server;Database=$Database;User ID=$($Credential.UserName);Password=$pw;Connect Timeout=15;Application Name=$AppName"
        $conn = New-Object System.Data.SqlClient.SqlConnection $cs
        $conn.Open()
        return $conn
    } finally {
        $pw = $null
        $cs = $null
    }
}

function New-HorizonCommand {
    param($Connection, [string] $Sql, [int] $Timeout = 600)
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText    = $Sql
    $cmd.CommandTimeout = $Timeout
    return $cmd
}

function Invoke-HorizonTable {
    <#
    .SYNOPSIS
        Runs a query and returns the DataTable.
    #>
    param($Connection, [string] $Sql, [int] $Timeout = 600)
    $cmd = New-HorizonCommand -Connection $Connection -Sql $Sql -Timeout $Timeout
    $da  = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    $dt  = New-Object System.Data.DataTable
    [void] $da.Fill($dt)
    # ,$dt - PowerShell enumerates a DataTable into DataRows on return; the
    # leading comma keeps the table itself intact so .Rows is not null.
    return ,$dt
}

function Invoke-HorizonScalar {
    param($Connection, [string] $Sql, [int] $Timeout = 600)
    $cmd = New-HorizonCommand -Connection $Connection -Sql $Sql -Timeout $Timeout
    return $cmd.ExecuteScalar()
}

function Invoke-HorizonNonQuery {
    <#
    .SYNOPSIS
        Runs a statement and returns rows affected.
    .PARAMETER LockTimeoutMs
        Sets SET LOCK_TIMEOUT for this batch and resets it to -1 afterwards.
        LOCK_TIMEOUT is SESSION-scoped, so without the reset every later query
        on the connection inherits the limit - the bug that broke the permission
        read on 2026-08-27. The reset runs in a finally so an aborted batch
        cannot leave it set.
    #>
    param($Connection, [string] $Sql, [int] $Timeout = 600, [int] $LockTimeoutMs = 0)

    if ($LockTimeoutMs -gt 0) {
        try {
            $cmd = New-HorizonCommand -Connection $Connection `
                     -Sql ("SET LOCK_TIMEOUT $LockTimeoutMs;`n" + $Sql) -Timeout $Timeout
            return $cmd.ExecuteNonQuery()
        } finally {
            try {
                $reset = New-HorizonCommand -Connection $Connection -Sql 'SET LOCK_TIMEOUT -1;' -Timeout 30
                [void] $reset.ExecuteNonQuery()
            } catch { }
        }
    }
    $cmd = New-HorizonCommand -Connection $Connection -Sql $Sql -Timeout $Timeout
    return $cmd.ExecuteNonQuery()
}

function Get-HorizonOrphanCodes {
    <#
    .SYNOPSIS
        Items on a delete list whose location/collection/itype code is missing
        from its parent table.
    .DESCRIPTION
        The documented KillBib killer: its statistics insert fails on
        FK_stat_data_*, the delete rolls back, and the run stops partway.

        One definition, used by both the pre-flight check and the post-failure
        diagnostic. Previously two copies that returned different columns, so
        adding a code type to one left the other silently blind to it.

        Returns a DataTable: code_type, code, items, bibs. Empty means clean.
    #>
    param($Connection, [Parameter(Mandatory=$true)] [string] $Table, [int] $Timeout = 300)
    Test-HorizonTableName -Table $Table
    $sql = @"
SELECT 'location' AS [code_type], i.location AS [code],
       COUNT(*) AS [items], COUNT(DISTINCT i.[bib#]) AS [bibs]
FROM item i
INNER JOIN dbo.[$Table] d ON d.[bib#] = i.[bib#]
LEFT JOIN location l ON l.location = i.location
WHERE l.location IS NULL
GROUP BY i.location
UNION ALL
SELECT 'collection', i.collection, COUNT(*), COUNT(DISTINCT i.[bib#])
FROM item i
INNER JOIN dbo.[$Table] d ON d.[bib#] = i.[bib#]
LEFT JOIN collection c ON c.collection = i.collection
WHERE c.collection IS NULL
GROUP BY i.collection
UNION ALL
SELECT 'itype', i.itype, COUNT(*), COUNT(DISTINCT i.[bib#])
FROM item i
INNER JOIN dbo.[$Table] d ON d.[bib#] = i.[bib#]
LEFT JOIN itype t ON t.itype = i.itype
WHERE t.itype IS NULL
GROUP BY i.itype;
"@
    return ,(Invoke-HorizonTable -Connection $Connection -Sql $sql -Timeout $Timeout)
}

function Get-HorizonRemainingBibCount {
    <#
    .SYNOPSIS
        How many listed bibs are STILL in the catalog.
    .DESCRIPTION
        Not the same as counting the delete-list table: KillBib deletes catalog
        records and never touches the list, so the list count stays at its
        original value throughout. Progress is measured against bib_control.
    #>
    param($Connection, [Parameter(Mandatory=$true)] [string] $Table, [int] $Timeout = 300)
    Test-HorizonTableName -Table $Table
    return [int] (Invoke-HorizonScalar -Connection $Connection -Timeout $Timeout -Sql @"
SELECT COUNT(*) FROM bib_control bc
INNER JOIN dbo.[$Table] d ON d.[bib#] = bc.[bib#];
"@)
}

function Show-HorizonBlockers {
    <#
    .SYNOPSIS
        Names the sessions competing for a lock, when a statement times out.
    #>
    param($Connection)
    try {
        $b = Invoke-HorizonTable -Connection $Connection -Timeout 30 -Sql @"
SELECT r.session_id AS [session_id], s.login_name AS [login],
       s.program_name AS [program], r.command AS [command],
       r.wait_type AS [wait_type], r.wait_time/1000 AS [wait_secs],
       LEFT(ISNULL(t.text,''), 120) AS [sql_text]
FROM sys.dm_exec_requests r
INNER JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE s.is_user_process = 1 AND r.session_id <> @@SPID
ORDER BY r.wait_time DESC;
"@
        if ($b.Rows.Count -eq 0) {
            Write-Host "           no other active requests visible - the blocker may be an idle session holding a lock" -ForegroundColor DarkGray
            return
        }
        Write-Host "           active sessions on this server:" -ForegroundColor DarkGray
        foreach ($row in $b.Rows) {
            Write-Host ("             spid {0}  {1}  {2}  wait={3} {4}s" -f `
                $row['session_id'], $row['login'], $row['command'], $row['wait_type'], $row['wait_secs']) -ForegroundColor DarkGray
            if ($row['sql_text']) { Write-Host ("               " + ($row['sql_text'] -replace '\s+',' ')) -ForegroundColor DarkGray }
        }
        Write-Host "           kill an orphaned one with:  KILL <session_id>;" -ForegroundColor DarkGray
    } catch {
        if ($_.Exception.Message -match 'VIEW SERVER STATE') {
            Write-Host "           cannot list sessions - this login lacks VIEW SERVER STATE." -ForegroundColor DarkGray
            Write-Host "           Connect SSMS with a sysadmin login and run:" -ForegroundColor DarkGray
            Write-Host "             SELECT session_id, login_name, program_name, status" -ForegroundColor DarkGray
            Write-Host "             FROM sys.dm_exec_sessions WHERE is_user_process = 1;" -ForegroundColor DarkGray
            Write-Host "             -- then: KILL <session_id>;" -ForegroundColor DarkGray
        } else {
            Write-Host "           could not read blocking info: $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }
}
