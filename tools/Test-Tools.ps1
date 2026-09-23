<#
.SYNOPSIS
    Tests for the PowerShell tooling. No database, no external modules.

.DESCRIPTION
    Covers the parts that can be checked without a live Horizon connection:
    validation guards, README parsing, the doc generators, the scaffold, and
    two behaviours that caused real failures during the 2026-08-27 run but are
    provable offline with a fake connection object.

    NOT covered - these need a real server or the vendor binary, and stay
    manual: connecting, the selection/discriminator queries, GRANT, the orphan
    check against live data, and anything that launches KillBib.

    Exits 0 when everything passes, 1 otherwise, so a hook or CI can gate on it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-Tools.ps1
#>

[CmdletBinding()]
param([switch] $Quiet)

$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $toolsDir

$script:Pass = 0
$script:Fail = 0
$script:Group = ''

function Group { param([string]$Name) $script:Group = $Name; if (-not $Quiet) { Write-Host ""; Write-Host "  $Name" -ForegroundColor Cyan } }

function Ok {
    param([string]$What)
    $script:Pass++
    if (-not $Quiet) { Write-Host "    ok    $What" -ForegroundColor DarkGray }
}
function Bad {
    param([string]$What, [string]$Detail)
    $script:Fail++
    Write-Host "    FAIL  $What" -ForegroundColor Red
    if ($Detail) { Write-Host "          $Detail" -ForegroundColor Red }
}
function Assert-True {
    param([bool]$Condition, [string]$What, [string]$Detail)
    if ($Condition) { Ok $What } else { Bad $What $Detail }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ($Expected -eq $Actual) { Ok $What } else { Bad $What "expected '$Expected', got '$Actual'" }
}
function Assert-Throws {
    param([scriptblock]$Script, [string]$What, [string]$MatchText)
    try {
        & $Script | Out-Null
        Bad $What "expected a throw, none happened"
    } catch {
        if ($MatchText -and $_.Exception.Message -notmatch [regex]::Escape($MatchText)) {
            Bad $What "threw, but message did not contain '$MatchText': $($_.Exception.Message)"
        } else { Ok $What }
    }
}

# Load the units under test.
. (Join-Path $toolsDir 'HorizonSql.ps1')

# Build-SolutionDocs.ps1 runs work at load time, so lift out just its functions.
$bsd = Get-Content (Join-Path $toolsDir 'Build-SolutionDocs.ps1') -Raw
foreach ($fn in @('ConvertTo-HtmlText','ConvertTo-Slug','Get-ReadmeBlocks','Test-IsWrite')) {
    $m = [regex]::Match($bsd, "(?s)function $fn \{.*?\n\}")
    if (-not $m.Success) { throw "Could not lift function $fn out of Build-SolutionDocs.ps1" }
    Invoke-Expression $m.Value
}

Write-Host ""
Write-Host "Tooling tests (no database required)" -ForegroundColor White
Write-Host ("=" * 60)

# ---------------------------------------------------------------------------
Group 'Test-HorizonTableName'

Assert-True  ($null -eq (Test-HorizonTableName -Table 'PQ_CAT_20260825_DeleteList')) 'accepts a valid 27-char name'
# Synthetic name, so this stays valid regardless of what the example table
# in the docs is called.
$tooLong = 'T' + ('a' * 34)   # 35 characters
Assert-Throws { Test-HorizonTableName -Table $tooLong } `
    'rejects 35 chars (KillBib truncates /t at 31)' 'is 35 characters'
Assert-Throws { Test-HorizonTableName -Table 'a; DROP TABLE b--' } `
    'rejects a SQL-injection attempt' 'not a plain identifier'
Assert-Throws { Test-HorizonTableName -Table '1_starts_with_digit' } `
    'rejects a leading digit' 'not a plain identifier'
Assert-Throws { Test-HorizonTableName -Table 'has space' } 'rejects an embedded space'
Assert-True  ($null -eq (Test-HorizonTableName -Table $tooLong -SkipLengthCheck)) `
    '-SkipLengthCheck allows a long name for non-KillBib use'
# Boundary: 30 passes, 31 fails.
Assert-True  ($null -eq (Test-HorizonTableName -Table ('a' * 30))) 'accepts exactly 30 characters'
Assert-Throws { Test-HorizonTableName -Table ('a' * 31) } 'rejects 31 characters'

# ---------------------------------------------------------------------------
Group 'Test-IsWrite - the runbook safety chip must fail CLOSED'

Assert-Equal $false (Test-IsWrite -Code 'SELECT COUNT(*) FROM bib;')                       'plain SELECT is read-only'
Assert-Equal $false (Test-IsWrite -Code "-- do not UPDATE anything`nSELECT 1;")            'keyword inside a comment does not count'
Assert-Equal $false (Test-IsWrite -Code "SELECT 'we should DELETE this' AS note;")         'keyword inside a string literal does not count'
Assert-Equal $true  (Test-IsWrite -Code 'UPDATE bib SET text = ''x'';')                    'UPDATE is a write'
Assert-Equal $true  (Test-IsWrite -Code 'DROP TABLE dbo.x;')                               'DROP is a write'
Assert-Equal $true  (Test-IsWrite -Code 'GRANT SELECT ON dbo.x TO y;')                     'GRANT is a write'
# These four all read as safe under a naive keyword allow-list.
Assert-Equal $true  (Test-IsWrite -Code 'MERGE t USING s ON 1=1 WHEN MATCHED THEN DELETE;') 'MERGE is a write'
Assert-Equal $true  (Test-IsWrite -Code 'SELECT a INTO dbo.NewTable FROM b;')               'SELECT ... INTO is a write'
Assert-Equal $true  (Test-IsWrite -Code 'EXEC sp_rename ''a'', ''b'';')                     'EXEC is a write'
Assert-Equal $true  (Test-IsWrite -Code ';WITH c AS (SELECT 1 x) UPDATE t SET y = 1;')      'CTE fronting an UPDATE is a write'

# ---------------------------------------------------------------------------
Group 'ConvertTo-Slug / ConvertTo-HtmlText'

Assert-Equal 'query-a-the-report' (ConvertTo-Slug -Text 'Query A - The Report')  'slug lowercases and dashes'
Assert-Equal 'step-1-create'      (ConvertTo-Slug -Text '`Step 1` Create!!')     'slug strips backticks and punctuation'
Assert-Equal 'query'              (ConvertTo-Slug -Text '!!!')                    'slug falls back when nothing survives'
Assert-True  ((ConvertTo-Slug -Text ('word ' * 40)).Length -le 48)                'slug is capped at 48 chars'
Assert-Equal '&lt;staff&gt; &amp; co' (ConvertTo-HtmlText -Text '<staff> & co')   'HTML escaping covers & < >'

# ---------------------------------------------------------------------------
Group 'Get-ReadmeBlocks'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $fixture = Join-Path $tmp 'README.md'
    @'
# Title

## Query A — The Report

```sql
SELECT 1;
```

## Step 5 - Hand off

```text
killbib /s x
```

### Untagged fence

```
not extracted
```
'@ | Out-File -FilePath $fixture -Encoding utf8

    $blocks = @(Get-ReadmeBlocks -Path $fixture)
    Assert-Equal 3        $blocks.Count            'finds all three fenced blocks'
    Assert-Equal 'sql'    $blocks[0].Lang          'first block is tagged sql'
    Assert-Equal 'text'   $blocks[1].Lang          'second block is tagged text'
    Assert-Equal ''       $blocks[2].Lang          'untagged fence has empty Lang'
    Assert-Equal 'Query A'       $blocks[0].Heading 'em-dash subtitle is stripped from the heading'
    Assert-Equal 'Step 5 - Hand off' $blocks[1].Heading 'a plain hyphen is NOT treated as a subtitle'
    Assert-Equal 'SELECT 1;' $blocks[0].Code       'code body is captured verbatim'
    Assert-True  ($blocks[0].Heading -notmatch '`') 'backticks stripped from headings'

    # A heading inside a fence must not be mistaken for a real heading.
    @'
# T

## Real Heading

```sql
-- ## Not A Heading
SELECT 2;
```
'@ | Out-File -FilePath $fixture -Encoding utf8
    $b2 = @(Get-ReadmeBlocks -Path $fixture)
    Assert-Equal 'Real Heading' $b2[0].Heading 'a ## line inside a fence is not treated as a heading'
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
Group 'Invoke-HorizonTable returns a DataTable, not DataRows'

# The 2026-08-27 failure: `return $dt` makes PowerShell enumerate the table
# into DataRow objects, so the caller's .Rows is null. Proven with a fake
# connection - no server involved.
$fakeCmd = New-Object psobject
$fakeCmd | Add-Member NoteProperty CommandText ''
$fakeCmd | Add-Member NoteProperty CommandTimeout 0
$fakeCmd | Add-Member ScriptMethod ExecuteScalar { 42 }
$fakeCmd | Add-Member ScriptMethod ExecuteNonQuery { $script:executed += ,$this.CommandText; 7 }

$fakeConn = New-Object psobject
$fakeConn | Add-Member ScriptMethod CreateCommand { $script:lastCmd }

$script:lastCmd = $fakeCmd
$script:executed = @()

Assert-Equal 42 (Invoke-HorizonScalar -Connection $fakeConn -Sql 'SELECT 42;') 'Invoke-HorizonScalar returns the scalar'
Assert-Equal 7  (Invoke-HorizonNonQuery -Connection $fakeConn -Sql 'UPDATE x;') 'Invoke-HorizonNonQuery returns rows affected'

# The unrolling guard itself, on a real DataTable.
function Get-TableUnguarded { $t = New-Object System.Data.DataTable; [void]$t.Columns.Add('a'); [void]$t.Rows.Add('x'); return $t }
function Get-TableGuarded   { $t = New-Object System.Data.DataTable; [void]$t.Columns.Add('a'); [void]$t.Rows.Add('x'); return ,$t }
Assert-Equal 'DataRow'   (Get-TableUnguarded).GetType().Name 'without the comma a DataTable unrolls to DataRow (the bug)'
Assert-Equal 'DataTable' (Get-TableGuarded).GetType().Name   'with the leading comma the DataTable survives (the fix)'

# ---------------------------------------------------------------------------
Group 'Invoke-HorizonNonQuery resets LOCK_TIMEOUT'

# LOCK_TIMEOUT is session-scoped. Leaving it set broke the permission read on
# 2026-08-27, so the reset must fire even when the batch throws.
$script:executed = @()
[void] (Invoke-HorizonNonQuery -Connection $fakeConn -Sql 'CREATE TABLE t (x int);' -LockTimeoutMs 20000)
Assert-True ($script:executed[0] -match 'SET LOCK_TIMEOUT 20000') 'sets LOCK_TIMEOUT before the batch'
Assert-True ($script:executed[-1] -match 'SET LOCK_TIMEOUT -1')   'resets LOCK_TIMEOUT after the batch'

# Same again, but the batch throws.
$throwCmd = New-Object psobject
$throwCmd | Add-Member NoteProperty CommandText ''
$throwCmd | Add-Member NoteProperty CommandTimeout 0
$throwCmd | Add-Member ScriptMethod ExecuteNonQuery {
    $script:executed += ,$this.CommandText
    if ($this.CommandText -notmatch 'LOCK_TIMEOUT -1') { throw "Lock request time out period exceeded." }
    return 0
}
$script:lastCmd = $throwCmd
$script:executed = @()
try { [void] (Invoke-HorizonNonQuery -Connection $fakeConn -Sql 'DROP TABLE t;' -LockTimeoutMs 20000) } catch { }
Assert-True (($script:executed | Where-Object { $_ -match 'SET LOCK_TIMEOUT -1' }).Count -ge 1) `
    'resets LOCK_TIMEOUT even when the batch THROWS'

$script:lastCmd = $fakeCmd

# ---------------------------------------------------------------------------
Group 'Find-KillBib'

$fk = Join-Path $toolsDir 'Find-KillBib.ps1'
Assert-Throws { & $fk -Path (Join-Path $tmp 'nope\KillBib.exe') } 'rejects a -Path that does not exist' 'not found'

$fakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("kb-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'Horizon_2') -Force | Out-Null
$fakeExe = Join-Path $fakeRoot 'Horizon_2\KillBib.exe'
'stub' | Out-File -FilePath $fakeExe -Encoding ascii
try {
    $resolved = & $fk -Path $fakeExe
    Assert-Equal $fakeExe $resolved '-Path resolves an existing executable'
} finally { Remove-Item -Recurse -Force $fakeRoot -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
Group 'New-Solution.ps1 (in a throwaway repo)'

$fakeRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("repo-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fakeRepo 'solutions') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fakeRepo 'tools')     -Force | Out-Null
Copy-Item (Join-Path $toolsDir 'New-Solution.ps1') (Join-Path $fakeRepo 'tools') -Force
@'
# Test Repo

* **[existing-one](./solutions/existing-one)**: An existing entry.

## Best practices
'@ | Out-File -FilePath (Join-Path $fakeRepo 'README.md') -Encoding utf8

try {
    $ns = Join-Path $fakeRepo 'tools\New-Solution.ps1'
    & $ns -Name 'zz-test-report' -Type Report -Summary 'A test.' -RepoRoot $fakeRepo 6>$null | Out-Null

    $made = Join-Path $fakeRepo 'solutions\zz-test-report\README.md'
    Assert-True (Test-Path $made) 'creates solutions/<name>/README.md'
    $body = Get-Content $made -Raw
    Assert-True ($body -match '## The Problem')              'skeleton has The Problem'
    Assert-True ($body -match 'The Report \(Read-Only\)')    '-Type Report uses the read-only section'
    Assert-True ($body -notmatch 'Step 2: The Update')       '-Type Report has no Update step'

    $idx = Get-Content (Join-Path $fakeRepo 'README.md')
    Assert-True (($idx | Where-Object { $_ -match 'zz-test-report' }).Count -eq 1) 'appends exactly one index line'
    Assert-True (($idx | Where-Object { $_ -match 'existing-one' }).Count -eq 1)   'leaves the existing index line intact'
    Assert-True (($idx | Where-Object { $_ -match 'Best practices' }).Count -eq 1) 'does not disturb later sections'

    & $ns -Name 'zz-test-fix' -Type Fix -Summary 'A fix.' -RepoRoot $fakeRepo 6>$null | Out-Null
    $fixBody = Get-Content (Join-Path $fakeRepo 'solutions\zz-test-fix\README.md') -Raw
    Assert-True ($fixBody -match 'Step 1: The Audit')  '-Type Fix has the Audit step'
    Assert-True ($fixBody -match 'Step 2: The Update') '-Type Fix has the Update step'
    Assert-True ($fixBody -match 'BEGIN TRANSACTION')  '-Type Fix wraps the update in a transaction'

    Assert-Throws { & $ns -Name 'Bad Name!' -Type Report -Summary 'x' -RepoRoot $fakeRepo } `
        'rejects an invalid directory name'
    Assert-Throws { & $ns -Name 'zz-test-report' -Type Report -Summary 'x' -RepoRoot $fakeRepo } `
        'refuses to overwrite an existing solution' 'Already exists'
} finally { Remove-Item -Recurse -Force $fakeRepo -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
Group 'Generators run against the real repo'

$gen = & powershell -ExecutionPolicy Bypass -File (Join-Path $toolsDir 'Build-SolutionDocs.ps1') 2>&1
Assert-True ($LASTEXITCODE -eq 0) 'Build-SolutionDocs exits 0'
Assert-True (($gen -join "`n") -match 'sql file\(s\)') 'Build-SolutionDocs reports generated files'

$sch = & powershell -ExecutionPolicy Bypass -File (Join-Path $toolsDir 'Generate-SchemaDocs.ps1') 2>&1
Assert-True ($LASTEXITCODE -eq 0) 'Generate-SchemaDocs exits 0'

foreach ($p in @('all-objects.md','joins.md','no-unique-index.md','date-columns.md')) {
    Assert-True (Test-Path (Join-Path $repoRoot "docs\schema\index\$p")) "produced index/$p"
}

# Every generated .sql must carry the do-not-edit header.
# Only the generated sql/ directories. Hand-authored .sql lives elsewhere
# (e.g. a frozen delete list under "excel reports/") and must NOT carry the
# generated header - globbing all of solutions/ wrongly flagged it.
$sqlFiles = @(Get-ChildItem (Join-Path $repoRoot 'solutions') -Recurse -Filter *.sql |
              Where-Object { $_.Directory.Name -eq 'sql' })
# -join first: on an ARRAY, -notmatch returns the non-matching ELEMENTS (a
# truthy array), not a boolean - so the unjoined form matched every file.
$missing  = @($sqlFiles | Where-Object {
    ((Get-Content $_.FullName -TotalCount 8 -Encoding UTF8) -join "`n") -notmatch 'GENERATED from'
})
Assert-Equal 0 $missing.Count "all $($sqlFiles.Count) generated .sql files carry the GENERATED header"

# ---------------------------------------------------------------------------
function ConvertTo-RedactionPattern {
    <#
    .SYNOPSIS
        Turns one denylist line into the regex the guard matches with.
    .DESCRIPTION
        Plain entry      matched ANYWHERE in the file. The default, and the
                         safest: it catches a value however it is embedded.

        'word:<value>'   matched only where the value stands as its own token -
                         i.e. not butted up against another letter or digit.

        The 'word:' form exists for SHORT values that legitimately occur inside
        unrelated longer identifiers. A four-character site abbreviation buried
        in a vendor table name like fixXXXXProxy is not a leak, but a plain
        entry fires on it every run, and a guard that cries wolf gets switched
        off - which is the real risk.

        This is a NARROWING, not an exclusion. The value is still scanned for
        across every tracked file; it simply has to appear as a standalone
        token. A login, server name or location code written into prose, a
        path, or a quoted string is still caught. Compare an exclusion, which
        drops a whole FILE and is a permanent blind spot.

        Underscore, dash, dot and whitespace all count as boundaries, so for an
        entry 'word:acct', both acct_test and dbo.acct still match.
    #>
    param([Parameter(Mandatory=$true)] [string] $Entry)

    if ($Entry -match '^\s*word:\s*(.+?)\s*$') {
        # Lookaround on alphanumerics only - \b treats '_' as a word character,
        # so it would MISS <login>_test, which is exactly the shape a scratch
        # table named after a staff member takes.
        return '(?<![A-Za-z0-9])' + [regex]::Escape($Matches[1]) + '(?![A-Za-z0-9])'
    }
    return [regex]::Escape($Entry.Trim())
}

# ---------------------------------------------------------------------------
Group 'Redaction pattern matching'

$plain = ConvertTo-RedactionPattern 'abcd'
$token = ConvertTo-RedactionPattern 'word:abcd'

Assert-True ('fixabcdProxy' -match $plain)  'plain entry matches inside a longer identifier'
Assert-True ('abcd'         -match $plain)  'plain entry matches standalone'

Assert-True ('fixabcdProxy' -notmatch $token) 'word: entry does NOT match inside a longer identifier'
Assert-True ('abcd'         -match    $token) 'word: entry still matches standalone'
Assert-True ('abcd_test'    -match    $token) 'word: entry still matches before an underscore'
Assert-True ('dbo.abcd'     -match    $token) 'word: entry still matches after a dot'
Assert-True ('run abcd now' -match    $token) 'word: entry still matches between spaces'
Assert-True ("server='abcd'" -match   $token) 'word: entry still matches inside quotes'
Assert-True ('ABCD'         -match    $token) 'word: entry is still case-insensitive'
Assert-True ('abcde'        -notmatch $token) 'word: entry does not match a longer word starting with it'
Assert-True ('xabcd'        -notmatch $token) 'word: entry does not match a longer word ending with it'
# The prefix must not survive into the compiled pattern, or the guard would
# hunt for the literal text 'word:...' and never find the value at all.
# Asserted against the PATTERN, not a sample string: 'word:abcd' as a string
# legitimately contains a standalone abcd token and so SHOULD match.
Assert-True ($token -notmatch 'word')       'word: prefix is stripped from the compiled pattern'
Assert-True ($token -match 'abcd')          'the value survives into the compiled pattern'

# ---------------------------------------------------------------------------
Group 'Redaction guard - no real site identifiers in tracked files'

# The denylist holds the real values and is GITIGNORED, so the secrets never
# enter the repo while the check still works. Absent (a fresh clone) = skipped
# with a note, never a silent pass.
$denyPath = Join-Path $toolsDir '.redaction-denylist.txt'
if (-not (Test-Path $denyPath)) {
    Write-Host "    skip  no tools/.redaction-denylist.txt - guard not run" -ForegroundColor Yellow
    Write-Host "          create it (gitignored) to enable this check" -ForegroundColor DarkGray
} else {
    $deny = @(Get-Content $denyPath | ForEach-Object { $_.Trim() } |
              Where-Object { $_ -and -not $_.StartsWith('#') })
    Assert-True ($deny.Count -gt 0) "denylist has $($deny.Count) entries"

    # Compile once, not once per file - this loop is entries x tracked files.
    $denyPatterns = @($deny | ForEach-Object { ConvertTo-RedactionPattern $_ })
    $narrowed = @($deny | Where-Object { $_ -match '^\s*word:' }).Count
    if ($narrowed -gt 0) {
        Write-Host "          $narrowed entr$(if ($narrowed -eq 1) { 'y is' } else { 'ies are' }) token-scoped (word:)" -ForegroundColor DarkGray
    }

    # Only files git actually tracks - untracked scratch is not published.
    #
    # Excluded: docs/superpowers/ only - frozen historical planning records.
    #
    # If a real identifier shows up in the schema export, fix it at the SOURCE -
    # rename the table and re-export - rather than adding an exclusion here. An
    # exclusion is a permanent blind spot; see docs/SESSION-HANDOFF.md for the
    # 2026-08-28 case that established this.
    #
    # The one case where the source CANNOT be fixed: a short site abbreviation
    # baked into vendor/application table names that other systems reference,
    # so renaming them is not on the table. Mark that entry 'word:' in the
    # denylist - it stays scanned everywhere, but only as a standalone token.
    # That is a narrowing, not an exclusion; no file stops being checked.
    Push-Location $repoRoot
    $tracked = @(& git ls-files 2>$null | Where-Object {
        # csv included deliberately: horizon-schema/*.csv is the raw export, and
        # a real identifier appearing there as a table name is exposed exactly
        # as much as one in prose. Omitting it left the only file that ever
        # carried such a name unscanned.
        $_ -match '\.(md|ps1|sql|html|txt|csv|json|yml|yaml)$' -and
        $_ -notmatch '^docs/superpowers/'
    })
    Pop-Location
    Assert-True ($tracked.Count -gt 0) "found $($tracked.Count) tracked text files to scan"

    $hits = @()
    foreach ($rel in $tracked) {
        $full = Join-Path $repoRoot $rel
        if (-not (Test-Path $full)) { continue }
        $text = Get-Content $full -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($pattern in $denyPatterns) {
            if ($text -match $pattern) { $hits += "$rel contains a denylisted value" }
        }
    }
    # Report the file, never the value - echoing it would defeat the purpose.
    if ($hits.Count -eq 0) {
        Ok 'no denylisted value appears in any tracked file'
    } else {
        Bad 'denylisted values found in tracked files' (($hits | Select-Object -Unique) -join '; ')
    }
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 60)
if ($script:Fail -eq 0) {
    Write-Host " $($script:Pass) passed, 0 failed" -ForegroundColor Green
    exit 0
} else {
    Write-Host " $($script:Pass) passed, $($script:Fail) FAILED" -ForegroundColor Red
    exit 1
}
