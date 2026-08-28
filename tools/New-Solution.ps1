<#
.SYNOPSIS
    Scaffolds a new solution directory with a README in the required structure.

.DESCRIPTION
    Creates solutions/<Name>/README.md pre-filled with the structure CLAUDE.md
    requires, and appends the index line to the top-level README.

    Two variants:
      -Type Report   read-only: a single "The Report (Read-Only)" section,
                     stating that no backup or transaction is required.
      -Type Fix      the Audit/Update pair, with the identical-joins guarantee
                     and the backup/transaction requirements spelled out.

    Nothing is overwritten: an existing directory is an error.

.EXAMPLE
    tools\New-Solution.ps1 -Name 245-missing-subfield-a -Type Report `
        -Summary "Bibs whose 245 has no subfield a."
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true,
        HelpMessage='Directory name, e.g. 245-missing-subfield-a')]
    [string] $Name,

    [Parameter(Mandatory=$true,
        HelpMessage='Report = read-only; Fix = audit + update')]
    [ValidateSet('Report','Fix')]
    [string] $Type,

    [Parameter(Mandatory=$true,
        HelpMessage='One sentence for the top-level README index')]
    [string] $Summary,

    [string] $Title,
    [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot  = Split-Path -Parent $scriptDir
}

# Directory names become paths, URLs and generated filenames - keep them plain.
if ($Name -notmatch '^[a-z0-9][a-z0-9._-]*$') {
    throw "Name '$Name' must be lowercase letters, digits, dot, dash or underscore, starting alphanumeric."
}
if (-not $Title) { $Title = $Name }

$solDir = Join-Path (Join-Path $RepoRoot 'solutions') $Name
if (Test-Path $solDir) { throw "Already exists: $solDir" }

$common = @"
# $Title

## The Problem

<!-- What is wrong, and why it matters. Include the SCHEMA reason it is hard -
     look up every table and column in docs/schema/ before writing anything.
     If two tables are both children of bib#, say so here: that is the
     Cartesian product this repo exists to guard against. -->

### The "Cartesian Product" Challenge

<!-- Which side fans out, and how this solution collapses it (EXISTS /
     DISTINCT / aggregation). Delete this heading if no join fans out, but
     check the grain of both sides in docs/schema/index/all-objects.md first. -->

"@

$reportBody = @"
### This is a read-only report

It is a ``SELECT`` only; it changes nothing. Per the read-only report exception
in ``CLAUDE.md``, **no backup and no transaction are required**, and there is no
audit/update split.

---

## The Report (Read-Only)

<!-- One row per what? State it. Then the query. -->

``````sql
-- Every table and column below was looked up in horizon-schema/, not inferred.
SELECT
    ...
FROM ...
WHERE ...;
``````

<!-- What the row count should be, and what to compare it against. -->

---

## Notes and edge cases

- <!-- Case sensitivity: collations here are CI, so = and LIKE ignore case. -->
- <!-- Date columns are smallint day counts - see docs/schema/conventions.md. -->
- <!-- Anything deliberately NOT filtered, so nobody "fixes" it later. -->
"@

$fixBody = @"
### A backup is required before Step 2

State plainly: a ``bib``/``item`` table (or full database) backup must be taken
before the ``UPDATE`` runs.

---

## Step 1: The Audit

**Run this first and record its row count.** It lists exactly the rows the
update will change, showing the current value beside the proposed new value.

``````sql
-- Every table and column below was looked up in horizon-schema/, not inferred.
SELECT
    ...            AS [current_value],
    ...            AS [proposed_value]
FROM ...
WHERE ...;
``````

---

## Step 2: The Update

The ``FROM``/``JOIN`` clauses below are **identical** to the audit query's, so
the affected row set provably matches what was reviewed. If you change one,
change both - diverging them breaks the core safety guarantee of this repo.

``````sql
BEGIN TRANSACTION;

UPDATE ...
SET    ...
FROM ...
WHERE ...;

SELECT @@ROWCOUNT AS [rows_updated];

-- Compare against the audit count, then:
-- COMMIT TRANSACTION;
-- ROLLBACK TRANSACTION;
``````

---

## Notes and edge cases

- <!-- Case sensitivity: collations here are CI, so = and LIKE ignore case. -->
- <!-- Date columns are smallint day counts - see docs/schema/conventions.md. -->
- <!-- Anything deliberately NOT filtered, so nobody "fixes" it later. -->
"@

New-Item -ItemType Directory -Path $solDir -Force | Out-Null
$readme = Join-Path $solDir 'README.md'
if ($Type -eq 'Report') { $content = $common + $reportBody } else { $content = $common + $fixBody }
$content | Out-File -FilePath $readme -Encoding utf8
Write-Host "created  $readme" -ForegroundColor Green

# --- index line in the top-level README ------------------------------------
$rootReadme = Join-Path $RepoRoot 'README.md'
$line = "* **[$Name](./solutions/$Name)**: $Summary"
$lines = Get-Content -Path $rootReadme -Encoding UTF8

# Append after the last existing solution bullet, so the index stays together.
$lastIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\* \*\*\[.+\]\(\./solutions/') { $lastIdx = $i }
}
if ($lastIdx -ge 0) {
    $new = @()
    $new += $lines[0..$lastIdx]
    $new += $line
    if ($lastIdx + 1 -lt $lines.Count) { $new += $lines[($lastIdx + 1)..($lines.Count - 1)] }
    # WriteAllLines with a BOM-less UTF8Encoding, not Out-File -Encoding utf8:
    # the latter writes a BOM on Windows PowerShell 5.1, so rewriting the
    # top-level README to add one index line put a spurious ﻿ on line 1 of
    # the repo's most-read file - and would do it again on every new solution.
    [System.IO.File]::WriteAllLines(
        $rootReadme, $new, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "indexed  README.md (after the last solution entry)" -ForegroundColor Green
} else {
    Write-Warning "Could not find the solution list in README.md - add this line by hand:"
    Write-Host "  $line" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. Read docs\schema\AGENTS.md before writing any SQL." -ForegroundColor Gray
Write-Host "  2. Fill in $readme - look up every name, never infer one." -ForegroundColor Gray
Write-Host "  3. powershell -ExecutionPolicy Bypass -File tools\Build-SolutionDocs.ps1 -Solution $Name" -ForegroundColor Gray
Write-Host "  4. Commit the README together with its generated sql\ and runbook.html." -ForegroundColor Gray
