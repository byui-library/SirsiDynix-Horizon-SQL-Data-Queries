<#
.SYNOPSIS
    Discovers KillBib, runs pre-flight checks, performs a single-bib trial
    delete, then the full run - each behind a typed confirmation.

.DESCRIPTION
    Wraps Horizon's KillBib utility for a delete-list table. Flags are taken
    from KillBib's own usage output (version 7.61, 2024-05-28), not inferred.

    THERE IS NO DRY-RUN. KillBib's /w flag documents that bib/bib_control rows
    are wiped BY DEFAULT; /k merely widens the blast radius to items, copies and
    circulation data. Running without /k is not a preview - it still deletes.
    Every safeguard here is therefore about ordering and confirmation, never
    about a "safe mode" that does not exist.

    Sequence:
      1. Resolve KillBib.exe            (tools\Find-KillBib.ps1)
      2. Pre-flight checks              (tools\Test-DeleteListPreflight.ps1)
      3. Single-bib TRIAL via /b + /e   - one record, then verify count fell by 1
      4. Full run                       - separate typed confirmation
      5. On failure: orphan diagnostic + the resume command. Never auto-resumes.

    The password is held as a SecureString and converted to plain text only at
    the moment the argument list is built. Note that this cannot be made fully
    private: KillBib takes /p<password> on the command line, and Windows exposes
    command lines to anyone able to read the process list. That exposure is
    inherent to the utility, not to this script.

.PARAMETER Server        SQL Server instance         -> /s
.PARAMETER Database      Database name               -> /d
.PARAMETER Table         Delete-list table           -> /t
.PARAMETER ExpectedRows  Row count the table must hold before anything runs
.PARAMETER HorizonUserId Horizon User ID  -> /r  (mandatory - NOT the SQL login)
.PARAMETER Location      Location code    -> /l  (mandatory)
.PARAMETER Brutal        Pass /k - also deletes items, copies, circ info
.PARAMETER SkipTrial     Skip the single-bib trial. Requires -Force as well.
.PARAMETER KillBibPath   Use this executable instead of searching
.PARAMETER ResumeFrom    Start at this bib# (/b) - to resume a stopped run

.EXAMPLE
    tools\Invoke-KillBib.ps1 -Server ILSSERVER -Database ILSDB `
        -Table ProQuest_CAT_20260825_DeleteList -ExpectedRows 6790 -Brutal
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $Server,
    [Parameter(Mandatory=$true)] [string] $Database,
    [Parameter(Mandatory=$true)] [string] $Table,
    [Parameter(Mandatory=$true)] [int]    $ExpectedRows,

    # KillBib /r - a Horizon staff identity, separate from the SQL login (/u).
    # KillBib logs in to SQL Server, then waits on this. Without it the process
    # hangs after "Logged in to <server>\..\<db>" with no visible prompt.
    [Parameter(Mandatory=$true,
        HelpMessage='Horizon staff User ID (/r) - your Horizon client login, NOT the SQL login')]
    [string] $HorizonUserId,

    # KillBib /l - Horizon location code. Required, same as /r.
    [Parameter(Mandatory=$true,
        HelpMessage='Horizon location code (/l)')]
    [string] $Location,
    [switch] $Brutal,
    [switch] $SkipTrial,
    [switch] $Force,

    # Set by Invoke-DeleteListRun.ps1, which has already run pre-flight and
    # already taken a typed confirmation. Without these the orchestrated path
    # runs pre-flight twice (two orphan scans, two audit CSVs for one run) and
    # prompts twice for the same acknowledgement.
    [switch] $SkipPreflight,
    [switch] $Yes,
    [string] $KillBibPath,
    [int]    $ResumeFrom,
    [System.Management.Automation.PSCredential] $Credential
)

$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- helpers ---------------------------------------------------------------

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HorizonSql.ps1')

# Validates the identifier AND KillBib's 31-character /t truncation limit.
Test-HorizonTableName -Table $Table

function New-Conn { New-HorizonConnection -Server $Server -Database $Database -Credential $Credential -AppName 'KillBib' }

function Get-FirstBib {
    param([System.Management.Automation.PSCredential] $Cred)
    $conn = New-HorizonConnection -Server $Server -Database $Database -Credential $Cred -AppName 'KillBib'
    try {
        $v = Invoke-HorizonScalar -Connection $conn -Sql "SELECT MIN([bib#]) FROM dbo.[$Table];"
        if ($v -is [DBNull]) { return $null }
        return [int] $v
    } finally { $conn.Close() }
}

function Show-OrphanDiagnostic {
    param([System.Management.Automation.PSCredential] $Cred)
    Write-Host ""
    Write-Host "Running orphaned-code diagnostic..." -ForegroundColor Yellow
    try {
        $conn = New-HorizonConnection -Server $Server -Database $Database -Credential $Cred -AppName 'KillBib'
        try {
            # Shared with Test-DeleteListPreflight.ps1 - one definition, so a
            # new code type can never be visible to one and not the other.
            $dt = Get-HorizonOrphanCodes -Connection $conn -Table $Table
            if ($dt.Rows.Count -eq 0) {
                Write-Host "  Orphan check: clean. The failure was something else -" -ForegroundColor Gray
                Write-Host "  read KillBib's output above before doing anything further." -ForegroundColor Gray
            } else {
                Write-Host "  Orphaned codes found - this is very likely the cause:" -ForegroundColor Yellow
                foreach ($r in $dt.Rows) {
                    Write-Host ("    {0,-11} {1,-10} {2,6} items  {3,6} bibs" -f $r.code_type, $r.code, $r.items, $r.bibs) -ForegroundColor Yellow
                }
                Write-Host ""
                Write-Host "  Restore the missing code to its parent table, or correct the items." -ForegroundColor Gray
                Write-Host "  Never drop or disable the FK to force it through." -ForegroundColor Gray
            }
        } finally { $conn.Close() }
    } catch {
        Write-Host "  Diagnostic could not run: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-KillBibRun {
    param(
        [string] $Exe,
        [System.Management.Automation.PSCredential] $Cred,
        [int] $BeginBib,
        [int] $EndBib,
        [string] $Label
    )
    $pw = Get-HorizonPlainPassword -Credential $Cred

    # Flags per KillBib 7.61 usage output. Values abut their switch, no space.
    $args = @(
        "/s$Server"
        "/d$Database"
        "/u$($Cred.UserName)"
        "/p$pw"
        "/t$Table"
    )
    $args += "/r$HorizonUserId"
    $args += "/l$Location"
    if ($BeginBib)      { $args += "/b$BeginBib" }
    if ($EndBib)        { $args += "/e$EndBib" }
    if ($Brutal)        { $args += "/k" }

    # Masked echo - never print the real password
    $shown = $args | ForEach-Object { if ($_ -like '/p*') { '/p********' } else { $_ } }
    Write-Host ""
    Write-Host "$Label command:" -ForegroundColor Cyan
    Write-Host ("  `"{0}`" {1}" -f $Exe, ($shown -join ' ')) -ForegroundColor Gray
    Write-Host ""

    # Run from KillBib's own directory. Horizon's command-line utilities expect
    # their install folder as the working directory - that is where their
    # configuration and DLLs live. Invoking by full path from elsewhere can make
    # one fail silently, which is what the first live run looked like.
    $exeDir = Split-Path -Parent $Exe
    Write-Host "  working directory: $exeDir" -ForegroundColor DarkGray

    # NOT piped through Tee-Object.
    #
    # KillBib is interactive - it prints "Logged in to <server>\..\<db>" and then
    # waits for confirmation before a /k delete. Piping its output into
    # Tee-Object buffers stdout and starves that prompt: the user never sees the
    # question and KillBib never gets an answer. The first live run failed this
    # way, exiting 2147483647 with nothing on screen.
    #
    # Losing the log file is the right trade. An interactive tool has to keep
    # its console. Everything KillBib prints is still visible on screen, and the
    # audit record lives in killbib-audit\<table>-<stamp>.csv, written before
    # anything is deleted.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location -LiteralPath $exeDir
    try {
        Write-Host "  KillBib may prompt for confirmation - answer it here." -ForegroundColor Yellow
        Write-Host ""
        & $Exe @args
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $sw.Stop()
    $pw = $null
    $args = $null

    Write-Host ""
    Write-Host ("-" * 62) -ForegroundColor DarkGray
    Write-Host ("$Label finished in {0:N1}s, exit code {1}." -f $sw.Elapsed.TotalSeconds, $code) `
        -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Red' })

    # Report what actually went, measured against the catalog rather than
    # inferred from KillBib's exit code.
    try {
        $rconn = New-HorizonConnection -Server $Server -Database $Database -Credential $Cred -AppName 'KillBib'
        try { $remaining = Get-HorizonRemainingBibCount -Connection $rconn -Table $Table }
        finally { $rconn.Close() }
        $gone = $ExpectedRows - $remaining
        Write-Host ("  bib records: {0} deleted, {1} still present (of {2})" -f `
            $gone, $remaining, $ExpectedRows) -ForegroundColor $(if ($remaining -eq 0) { 'Green' } else { 'Yellow' })
        if ($remaining -eq 0) {
            Write-Host "  Every listed bib is gone from bib_control." -ForegroundColor Green
        }
    } catch {
        Write-Host "  could not re-count after the run: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Write-Host ("-" * 62) -ForegroundColor DarkGray

    if ($code -eq 2147483647) {
        Write-Host ""
        Write-Host "  Exit code 2147483647 is Int32.MaxValue - not a real status code." -ForegroundColor Yellow
        Write-Host "  On the 2026-08-27 run this meant KillBib was launched from the wrong" -ForegroundColor Yellow
        Write-Host "  working directory and died before printing anything. Run from its own" -ForegroundColor Yellow
        Write-Host "  folder (this script now does) and it logs in and prompts normally." -ForegroundColor Yellow
        Write-Host "  /r and /l are always sent, so they are not the cause." -ForegroundColor Yellow
    }
    # Set a script-scope variable rather than returning the code.
    #
    # If the caller writes `$code = Invoke-KillBibRun ...`, that assignment
    # captures this function's ENTIRE output stream - and KillBib's own stdout
    # goes into that stream. The result is a run that deletes thousands of
    # records while showing nothing on screen, which is what happened on
    # 2026-08-27. Our own Write-Host lines survived only because Write-Host
    # bypasses the pipeline.
    #
    # Leaving the native output uncaptured also keeps it unbuffered and
    # line-immediate, and leaves stdin attached, so any prompt KillBib writes
    # appears at once and can be answered.
    $script:KillBibExitCode = $code
}

# --- 0. credential ---------------------------------------------------------

if (-not $Credential) {
    $Credential = Get-Credential -Message "Database login for $Server / $Database (KillBib /u and /p)"
}
if (-not $Credential) { throw "No credential supplied." }

# --- 1. locate KillBib -----------------------------------------------------

Write-Host ""
Write-Host "Locating KillBib..." -ForegroundColor Cyan
if ($KillBibPath) { $exe = & (Join-Path $toolsDir 'Find-KillBib.ps1') -Path $KillBibPath }
else              { $exe = & (Join-Path $toolsDir 'Find-KillBib.ps1') }
Write-Host "  $exe" -ForegroundColor Gray

# --- 2. pre-flight ---------------------------------------------------------

if ($SkipPreflight) {
    Write-Host ""
    Write-Host "Pre-flight skipped - already run by the caller." -ForegroundColor DarkGray
    $ok = $true
} else {
$ok = & (Join-Path $toolsDir 'Test-DeleteListPreflight.ps1') `
        -Server $Server -Database $Database -Table $Table `
        -ExpectedRows $ExpectedRows -Credential $Credential
}
if (-not $ok) {
    Write-Host "Aborting: pre-flight did not pass. Nothing was deleted." -ForegroundColor Red
    exit 1
}

# --- 3. the warning --------------------------------------------------------

Write-Host ("=" * 62) -ForegroundColor Red
Write-Host " KillBib deletes permanently. There is no dry-run and no undo." -ForegroundColor Red
if ($Brutal) {
    Write-Host " /k is set: items, copies and circulation data go too." -ForegroundColor Red
} else {
    Write-Host " /k is NOT set: bib and bib_control rows are still wiped" -ForegroundColor Red
    Write-Host " (that is KillBib's default), but items and copies remain." -ForegroundColor Red
}
Write-Host ("=" * 62) -ForegroundColor Red

# --- 4. trial run ----------------------------------------------------------

if ($SkipTrial) {
    if (-not $Force) {
        throw "-SkipTrial requires -Force. The trial run is the only chance to see KillBib's real behaviour before the full batch."
    }
    Write-Host ""
    Write-Host "Trial run SKIPPED at your request." -ForegroundColor Yellow
} else {
    $trialBib = Get-FirstBib -Cred $Credential
    if ($null -eq $trialBib) { throw "Delete-list table is empty." }

    Write-Host ""
    Write-Host "TRIAL RUN - one record only (bib# $trialBib), via /b and /e." -ForegroundColor Yellow
    Write-Host "Type the bib# to run the trial, anything else to abort:" -ForegroundColor Yellow
    $answer = Read-Host "  bib#"
    if ($answer -ne "$trialBib") {
        Write-Host "Aborted. Nothing was deleted." -ForegroundColor Red
        exit 1
    }

    # No assignment - see Invoke-KillBibRun. Capturing this hides KillBib's output.
    Invoke-KillBibRun -Exe $exe -Cred $Credential -BeginBib $trialBib -EndBib $trialBib -Label "TRIAL"
    $code = $script:KillBibExitCode

    if ($code -ne 0) {
        Show-OrphanDiagnostic -Cred $Credential
        Write-Host ""
        Write-Host "Trial failed. Resolve the cause before attempting the full run." -ForegroundColor Red
        exit $code
    }

    # No before/after count of the list table: KillBib deletes catalog records
    # and never touches the list, so that number is invariant by construction.
    # Invoke-KillBibRun already reported the count that does move.
    Write-Host ""
    Write-Host "VERIFY THE TRIAL before continuing:" -ForegroundColor Yellow
    Write-Host "  SELECT COUNT(*) FROM bib_control WHERE [bib#] = $trialBib;   -- expect 0" -ForegroundColor Gray
    Write-Host "  SELECT COUNT(*) FROM bib          WHERE [bib#] = $trialBib;   -- expect 0" -ForegroundColor Gray
    Write-Host "  SELECT COUNT(*) FROM item         WHERE [bib#] = $trialBib;   -- expect 0 with /k" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Run those, confirm the record is gone and nothing else changed," -ForegroundColor Yellow
    Write-Host "then re-run this script with -SkipTrial -Force for the full batch." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Stopping here deliberately: the trial is worthless if you do not look at it." -ForegroundColor Yellow
    exit 0
}

# --- 5. full run -----------------------------------------------------------

$count = $ExpectedRows   # verified against the table by pre-flight
Write-Host ""
Write-Host "FULL RUN - $count bib# in dbo.$Table on $Server/$Database." -ForegroundColor Red
Write-Host "Type the row count to confirm, anything else to abort:" -ForegroundColor Red
if ($Yes) {
    Write-Host "  -Yes given: confirmation already taken by the caller." -ForegroundColor DarkGray
    $answer = "$count"
} else {
    $answer = Read-Host "  rows"
}
if ($answer -ne "$count") {
    Write-Host "Aborted. Nothing was deleted." -ForegroundColor Red
    exit 1
}

# No assignment - capturing this would swallow every line KillBib prints.
Invoke-KillBibRun -Exe $exe -Cred $Credential -BeginBib $ResumeFrom -EndBib 0 -Label "FULL RUN"
$code = $script:KillBibExitCode

if ($code -ne 0) {
    Show-OrphanDiagnostic -Cred $Credential
    Write-Host ""
    Write-Host "The run stopped. To resume once the cause is fixed, restart at the" -ForegroundColor Yellow
    Write-Host "bib# KillBib reported failing on:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  tools\Invoke-KillBib.ps1 -Server $Server -Database $Database ``" -ForegroundColor Gray
    Write-Host "      -Table $Table -ExpectedRows $ExpectedRows ``" -ForegroundColor Gray
    Write-Host "      -HorizonUserId $HorizonUserId -Location $Location ``" -ForegroundColor Gray
    Write-Host "      -ResumeFrom <failing-bib#> -SkipTrial -Force$(if($Brutal){' -Brutal'})" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Not resuming automatically - a partial delete that stopped for an" -ForegroundColor Yellow
    Write-Host "unexplained reason is a decision for you, with the diagnostic in hand." -ForegroundColor Yellow
    exit $code
}

Write-Host ""
Write-Host "KillBib completed. Confirm the catalog side before closing out:" -ForegroundColor Green
Write-Host "  SELECT COUNT(*) FROM bib_control bc" -ForegroundColor Gray
Write-Host "  INNER JOIN dbo.$Table d ON d.[bib#] = bc.[bib#];   -- expect 0" -ForegroundColor Gray
Write-Host ""
Write-Host "Serials note: copies with issues or predictions attached are skipped," -ForegroundColor Gray
Write-Host "not deleted, so some copies may survive. Re-count rather than assume." -ForegroundColor Gray
