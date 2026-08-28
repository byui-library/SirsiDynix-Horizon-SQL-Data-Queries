# Tools

PowerShell scripts for this repository. Two groups: **documentation generators**
(safe, run them freely) and **delete-run tooling** (one of them is irreversible).

All are Windows PowerShell 5.1 compatible and use `System.Data.SqlClient`
directly, so no `SqlServer` module is needed.

| Script | Group | Touches the catalog? |
| --- | --- | --- |
| [`Build-SolutionDocs.ps1`](#build-solutiondocsps1) | docs | no |
| [`Generate-SchemaDocs.ps1`](#generate-schemadocsps1) | docs | no |
| [`New-Solution.ps1`](#new-solutionps1) | docs | no |
| [`Find-KillBib.ps1`](#find-killbibps1) | delete | no |
| [`Test-DeleteListPreflight.ps1`](#test-deletelistpreflightps1) | delete | no (read-only) |
| [`Invoke-KillBib.ps1`](#invoke-killbibps1) | delete | **YES — irreversible** |
| [`Invoke-DeleteListRun.ps1`](#invoke-deletelistrunps1) | delete | **YES — irreversible** |

> **Run scripts by absolute path**, or from the repository root. A relative
> `tools\...` path fails if your prompt is somewhere else, and one of these
> scripts deliberately changes directory while it runs.

---

# The batch delete — one command

`Invoke-DeleteListRun.ps1` runs the entire sequence for a "delete every record
created by `<user>` on `<date>` whose `<tag>` mentions `<term>`" job: verify,
build the list, grant, pre-flight, delete, verify again. One typed confirmation
before the irreversible step.

```powershell
& "C:\path\to\repo\tools\Invoke-DeleteListRun.ps1" -Table PQ_CAT_20260825_DeleteList -CreateUser CATALOGER -CreateDate 2026-08-25 -ExpectedRows 6790 -StaffPrincipal staff_readers -Brutal
```

It prompts for what it doesn't have:

```text
Server:        ILSSERVER
Database:      ILSDB
HorizonUserId: HZUSER            <- KillBib /r, your Horizon client login
Location:      LOC           <- KillBib /l, validated against the location table
```

…then a standard credential dialog for the **SQL** login (`/u` and `/p`).

## What the ten steps do

| Step | Action | Catalog touched |
| ---: | --- | --- |
| 1 | Connect; validate the `/l` location code against the `location` table | no |
| 2 | Count the selection — must equal `-ExpectedRows` or it aborts | no |
| 3 | Discriminator check: has the note filter ever excluded anything? | no |
| 4 | Create the delete-list table, `PRIMARY KEY CLUSTERED ([bib#])` | no |
| 5 | Populate it, count-checked | no |
| 6 | `GRANT SELECT` to the staff principal | no |
| 7 | Pre-flight: orphaned codes, row count, audit file | no |
| 8 | **Typed confirmation** — enter the row count | — |
| 9 | KillBib | **yes, irreversible** |
| 10 | Post-verify: listed bibs gone, item rows gone | no |

Steps 1–7 change nothing in the catalog. A failure in any of them aborts before
step 9. Steps 4–6 create and populate a scratch table only — if something is
wrong, drop it and start over.

## Start with `-WhatIfOnly`

```powershell
& "...\tools\Invoke-DeleteListRun.ps1" -Table PQ_CAT_20260825_DeleteList -CreateUser CATALOGER -CreateDate 2026-08-25 -ExpectedRows 6790 -Brutal -WhatIfOnly
```

Runs steps 1–3 and stops, creating nothing. Since [KillBib has no dry-run of its
own](../docs/killbib.md#2-there-is-no-dry-run), this is the closest equivalent
available, and it answers the discriminator question before anything exists.

## Parameters

| Parameter | Maps to | Notes |
| --- | --- | --- |
| `-Server` `-Database` | `/s` `/d` | prompted if omitted |
| `-HorizonUserId` | `/r` | **mandatory** — Horizon login, *not* the SQL login |
| `-Location` | `/l` | **mandatory** — validated against `location` in step 1 |
| `-Table` | `/t` | **max 30 chars** — KillBib truncates at 31 |
| `-CreateUser` `-CreateDate` | — | the selection: who created records, and when |
| `-ExpectedRows` | — | the reviewed count; a mismatch aborts the run |
| `-Brutal` | `/k` | also deletes items, copies, circ data |
| `-StaffPrincipal` | — | `GRANT SELECT` target; omit to skip step 6 |
| `-NoteTag` `-NoteTerm` | — | default `590` / `ProQuest` |
| `-Epoch` | — | default `1970-01-01`; see the date convention |
| `-DiscriminatorFrom` | — | default 6 months before `-CreateDate` |
| `-DiscriminatorTimeout` | — | default 90s |
| `-SkipDiscriminator` | — | skips step 3, flags the warning |
| `-Trial` | `/b`+`/e` | opt in to a single-bib trial delete first |
| `-Yes` | — | skip the typed confirmation |
| `-WhatIfOnly` | — | steps 1–3 only |
| `-ResumeFrom` | `/b` | restart a stopped run at this `bib#` |
| `-KillBibPath` | — | use a specific executable |

## Safety properties

- **The selection predicate is defined once** and reused for the count, the
  discriminator and the `INSERT`, so those three cannot drift apart — the same
  guarantee this repo's READMEs make by using an identical `WHERE` clause in the
  audit and the update.
- **Step 2 aborts on a count mismatch** rather than adapting. A mismatch means
  the data drifted since your review; re-review rather than changing
  `-ExpectedRows` to whatever it now returns.
- **Every parameter reaching SQL is validated** as a plain identifier or checked
  for quotes before any query is built.
- **The audit file is written before anything is deleted** —
  `killbib-audit\<table>-<timestamp>.csv` holds the exact `bib#` list. It is
  catalog data, so `.gitignore` keeps it out of the repository.
- **No explicit transaction wraps the load.** An interrupted run would otherwise
  leave a transaction open, holding a lock on the list table and blocking the
  next attempt. This is a disposable scratch table: a wrong count is fixed by
  dropping and rebuilding, not by rollback.

## If it stops partway

Non-zero exit runs the orphaned-code diagnostic and prints the exact resume
command. **It never resumes automatically** — a partial delete that stopped for
an unexplained reason is a decision for a human holding the diagnostic. See
[`docs/killbib.md`](../docs/killbib.md#fk_stat_data_-failures).

---

# Script reference

## `Invoke-DeleteListRun.ps1`

The orchestrator described above. Prefer it over calling the pieces separately.

## `Invoke-KillBib.ps1`

Wraps KillBib alone, against a delete-list table that already exists. Discovers
the executable, runs pre-flight, optionally performs a single-bib trial, then the
full run. Used by the orchestrator; call it directly to resume a stopped run:

```powershell
& "...\tools\Invoke-KillBib.ps1" -Table PQ_CAT_20260825_DeleteList -ExpectedRows 6790 -ResumeFrom 5384912 -SkipTrial -Force -Brutal
```

Two behaviours worth knowing:

- **It runs KillBib from the executable's own directory**, because KillBib dies
  silently otherwise.
- **It does not capture KillBib's output.** Capturing it — via `$x = ...` or a
  pipe into `Tee-Object` — swallows every line the tool prints and starves any
  prompt it writes. Output goes straight to your console, unbuffered, with stdin
  attached.

## `Test-DeleteListPreflight.ps1`

Four read-only checks against a delete-list table. Returns `$true`/`$false`.

1. Connectivity using the same SQL login KillBib will use
2. Table exists and holds exactly the expected row count
3. **Orphaned `location`/`collection`/`itype` codes** — the documented KillBib
   killer
4. Writes the `bib#` audit file

```powershell
& "...\tools\Test-DeleteListPreflight.ps1" -Server ILSSERVER -Database ILSDB -Table PQ_CAT_20260825_DeleteList -ExpectedRows 6790
```

## `Find-KillBib.ps1`

Resolves `KillBib.exe` from known SirsiDynix/Horizon install roots. Returns the
full path.

**If it finds more than one copy it refuses to choose.** Sites commonly have
several Horizon client installs side by side of differing versions — this machine
has both `Horizon` and `Horizon_2` — and running a delete utility from the wrong
build against a live database is not a guess worth automating. Pass `-Path` to
name one, or `-All` to list every copy.

## `Build-SolutionDocs.ps1`

Generates `sql/NN-<slug>.sql` files and `runbook.html` from each solution's
`README.md`. The README is the source of truth; both outputs are derived and
carry a header saying so.

```powershell
powershell -ExecutionPolicy Bypass -File tools\Build-SolutionDocs.ps1
powershell -ExecutionPolicy Bypass -File tools\Build-SolutionDocs.ps1 -Solution 590-proquest-new-by-creator-report
```

Scans `solutions/`. Full conventions in
[`docs/authoring-solution-docs.md`](../docs/authoring-solution-docs.md).

## `Generate-SchemaDocs.ps1`

Rebuilds the generated pages under `docs/schema/index/` from the CSV exports in
`horizon-schema/`. Run after refreshing those exports.

```powershell
powershell -ExecutionPolicy Bypass -File tools\Generate-SchemaDocs.ps1
```

Hand-written pages (`AGENTS.md`, `conventions.md`, `core/*.md`) are never
touched.

## `New-Solution.ps1`

Scaffolds a new solution directory with a README skeleton in the required
structure, and adds its line to the top-level README index.

```powershell
powershell -ExecutionPolicy Bypass -File tools\New-Solution.ps1 -Name 245-missing-subfield-a -Type Report -Summary "Bibs whose 245 has no subfield a."
```

`-Type Report` produces the read-only single-section variant; `-Type Fix`
produces the Audit/Update pair. See
[`docs/authoring-solution-docs.md`](../docs/authoring-solution-docs.md).

---

## Before writing any query

Read [`docs/schema/AGENTS.md`](../docs/schema/AGENTS.md). Never infer a table or
column name — the complete schema is exported in
[`horizon-schema/`](../horizon-schema/README.md).
