# ProQuest `590` Records Created by an Operator on a Given Day

## The Problem
Cataloguing needs the list of bib records **created on 25 August 2026 by the
operator `CATALOGER`** that carry the word `ProQuest` somewhere in a `590` (local
note) tag — a per-operator, per-day slice of ProQuest ingest activity, used to
review what a single day's work actually added to the catalog.

Three facts have to be combined, and they live in two different tables:

| Fact | Where it lives |
| --- | --- |
| Who created the record, and when | `bib_control` — one row per `bib#` |
| The `590` note text | `bib` — **many** rows per `bib#` |
| The `245$a` title (for review) | `bib` — the `245` tag, also many rows per `bib#` |

The `bib_control` column list is recorded in
[`docs/schema/bib_control.md`](../../docs/schema/core/bib_control.md), captured from
`sp_help` against the live database. Every column name below comes from that
dump.

### The report is read-only; the delete-list step is not
**Queries 0, A, B and C are `SELECT`s only and change nothing.** Per the
read-only report exception in `CLAUDE.md` they need no backup and no
transaction, and there is no audit/update split.

**"Building the delete-list table" at the end of this README is different.** It
creates a table, writes to it, and grants a permission, and it feeds a
destructive external process (`killbib`). That section carries its own review
gate, transaction, and verification steps — read it before running any of it.

### The "Cartesian Product" Challenge
`bib_control` is one row per `bib#`, but `bib` is one row **per tag** per `bib#`.
A record whose `590`s say *"ProQuest Ebook Central perpetual access purchase"*
**and** *"ProQuest DDA"* has two matching `590` rows; a naive
`bib_control JOIN bib` would emit that record twice and inflate the count. The
report collapses the `bib` side with a per-bib `EXISTS` subquery, so the `590`
table can never multiply the output — **one row per bib#, always**.

---

## Match rule

A record qualifies when **all three** hold:

1. `bib_control.create_user = 'CATALOGER'`
2. `bib_control.create_date` = 25 August 2026
3. Some `590` on that `bib#` contains `ProQuest`

### Why the `590` condition is load-bearing, not decoration
`CATALOGER` is a cataloguer who **runs batch loads on most load days but also creates
the occasional record by hand — and does not always remember doing so.**

That is the entire reason condition 3 exists. `create_user` + `create_date`
alone would sweep up any hand-created record made on the same day as a load. The
ProQuest `590` test is what separates the ingest from that incidental hand work,
so a stray record is not deleted along with the batch.

Consequences worth holding on to:

- **The condition is a safety net, so it must be proven to work.** On 2026-08-25
  it excluded nothing (6,790 of 6,790) — consistent with the day being pure
  ingest, but indistinguishable from a predicate that is silently over-matching.
  If it were over-matching, hand-created records would be swept in without a
  trace: exactly the failure it exists to prevent. Verify it before relying on
  it — see below.
- **Measured 2026-08-27:** across 2026-08-17 → 2026-08-26, `CATALOGER` created records
  on one day only, 2026-08-25. Other operators account for 8/17 (20), 8/18 (22),
  8/20 (13), 8/24 (18) and 8/26 (22). A ten-day window is therefore too narrow to
  see his hand-created work; widen it to several months when checking.

### Proving the `590` filter discriminates — CONFIRMED 2026-08-27

**The filter works.** Searching `CATALOGER`'s records since 2026-02-25 for any
carrying no matching `590` returned real examples:

| `bib#` | created |
| --- | --- |
| 5739490 | 2026-07-23 |
| 5739481 | 2026-07-22 |
| 5739294, 5739295, 5739296 | 2026-06-10 |

Singles on two dates and a cluster of three on another — the hand-created
pattern exactly. These records exist in the catalogue and the `590` condition is
what keeps them out of the delete list. Its protective value is demonstrated,
not assumed.

`tools\Invoke-DeleteListRun.ps1` runs this automatically as step 3 and refuses
to treat a null result as a pass.

#### Query the check uses

Ask for **examples, not counts**. `bib_control` has no index on `create_user`,
so an unbounded aggregate over a bulk-load account's whole history is a full
table scan with a correlated leading-wildcard `LIKE` per row — it runs for
minutes and looks like a hang. `TOP` plus a date bound short-circuits on the
first hits:

```sql
SELECT TOP 5
       bc.[bib#] AS [bib#],
       DATEADD(day, bc.create_date, CAST('1970-01-01' AS DATE)) AS [created]
FROM bib_control bc
WHERE bc.create_user = 'CATALOGER'
  AND bc.create_date >= DATEDIFF(day, '1970-01-01', '2026-02-25')
  AND NOT EXISTS (
        SELECT 1 FROM bib p
        WHERE p.[bib#] = bc.[bib#]
          AND p.tag = '590'
          AND p.text LIKE '%ProQuest%')
ORDER BY bc.create_date DESC;
```

Rows returned = the filter excludes things = it can protect hand-created work.
No rows = it has never been observed excluding anything in that window; widen
the window before trusting it.

#### The per-day form (slower, more detail)

If you want the full picture rather than a proof, this counts matched against
excluded per day — but **bound the window**, for the reason above.

```sql
SELECT d.[created],
       COUNT(*)                 AS [total],
       SUM(d.is_pq)             AS [proquest],
       COUNT(*) - SUM(d.is_pq)  AS [not_proquest]
FROM (
    SELECT DATEADD(day, bc.create_date, CAST('1970-01-01' AS DATE)) AS [created],
           CASE WHEN EXISTS (SELECT 1 FROM bib p
                             WHERE p.[bib#] = bc.[bib#]
                               AND p.tag = '590'
                               AND p.text LIKE '%ProQuest%')
                THEN 1 ELSE 0 END AS is_pq
    FROM bib_control bc
    WHERE bc.create_user = 'CATALOGER'
      AND bc.create_date >= DATEDIFF(day, '1970-01-01', '2026-02-01')
) d
GROUP BY d.[created]
ORDER BY d.[created];
```

If `not_proquest` is zero on **every** day across months, the filter has never
excluded anything — investigate before trusting it with an irreversible delete.

The `EXISTS` must sit inside the derived table. Aggregating it directly
(`SUM(CASE WHEN EXISTS (...)`) fails with *Msg 130 — cannot perform an aggregate
function on an expression containing an aggregate or a subquery*.

### The creating operator is `create_user`
Not `creator`, not `created_by`, not `cataloger`. `bib_control.create_user` is a
`name_string` (30 chars). The table also carries `change_user` (last editor) and
`status_change_user` — this report deliberately uses **`create_user`**, since the
ask is who *created* the record. A record created by `CATALOGER` and later edited by
someone else still qualifies; a record created by someone else and later edited
by `CATALOGER` does not.

### `create_date` is a `smallint` day count, with `create_time` held separately
`create_date` is a `smallint` holding whole days elapsed since the epoch;
the time of day lives in its own `create_time` column. Two consequences:

- `create_date` has **no time component**, so `=` against a single day is exact
  and complete. No `>= / <` half-open range is needed, and none is used below.
- `smallint` widens to `int` implicitly, so comparing it against
  `DATEDIFF(day, ...)` (which returns `int`) needs no cast.

25 August 2026 is day **20690** under the `1970-01-01` epoch — well inside
`smallint`'s 32,767 ceiling. The queries write it as
`DATEDIFF(day, '1970-01-01', '2026-08-25')` rather than the bare literal, so the
intent is readable and the date changes in one place.

> **Epoch verified 2026-08-27.** Day 20690 is confirmed to be Tuesday
> 2026-08-25: a daily histogram of `bib_control.create_date` put all four weekend
> days in the surrounding fortnight at zero and every populated day on a weekday,
> which rules out the one-day error that a `MAX(create_date)` check cannot see.
> Day 20690 holds 6,797 records — the ProQuest bulk load — splitting as 6,790
> `CATALOGER` + 7 `OTHERUSER`. Evidence:
> [`docs/schema/conventions.md`](../../docs/schema/conventions.md#epoch--verified-as-1970-01-01-2026-08-27).

### Case sensitivity
- `create_user = 'CATALOGER'` — the column's collation is
  `SQL_Latin1_General_CP850_CI_AS`; **`CI` = case-insensitive**, so a stored
  `CATALOGER` or `Cataloger` also matches. That is intended here. To force exact case,
  append `COLLATE Latin1_General_CS_AS` to that predicate. Trailing blanks are
  stored (`TrimTrailingBlanks` is `no`) but SQL Server's `=` ignores them for
  character data, so no `RTRIM` is needed.
- `%ProQuest%` — case-insensitive under the same default collation, so
  `PROQUEST`, `Proquest`, and `ProQuest` all match. Intended: vendor
  capitalisation in `590` notes is inconsistent.
- No case-sensitive guard is needed here. (Contrast `%DDA%` in
  `590-proquest-purchase-removal-report`, which **does** need
  `COLLATE Latin1_General_CS_AS` — a case-insensitive `%DDA%` also matches the
  `dDa` sequence formed where a `$d` subfield code abuts content beginning
  `Da…`. `ProQuest` is long enough that no code/content boundary can forge it.)

---

## Query 0 — Verify epoch and operator spelling
**Both checks passed on 2026-08-27; results recorded below.** Re-run only if the
database is restored, refreshed, or the report is pointed at a different Horizon
instance. Two unknowns can each silently empty the report — a wrong date epoch
and a mis-spelled operator — and both fail in a way that looks like a legitimate
"no records matched".

Confirmed results:

| Check | Result |
| --- | --- |
| Epoch | `1970-01-01` — day 20690 = Tuesday 2026-08-25 |
| Operator spelling | `CATALOGER` exactly — no staff ID, no domain qualifier |
| Records created that day | 6,797 total: **6,790 `CATALOGER`** + 7 `OTHERUSER` |

**Query C result (2026-08-27): 6,790.**

That is *every* record `CATALOGER` created that day — the ProQuest `590` condition
excluded none of them. Consistent with 2026-08-25 having been a single ProQuest
bulk load from start to finish, and corroborated by the day's total of 6,797
being only 7 higher (all `OTHERUSER`'s).

> Worth knowing rather than glossing over: **a predicate that filters nothing is
> indistinguishable from a predicate that is not working.** Before treating
> 6,790-of-6,790 as a finding, confirm the ProQuest test discriminates by running
> it against an ordinary day — e.g. Monday 2026-08-24 — and checking that the
> ProQuest count there is *lower* than that day's total. If an ordinary day also
> comes back 100% ProQuest, stop: the predicate is matching more than intended.

Every downstream count must equal **6,790**: Query A's row count, and
`rows_inserted` when the delete-list table is built.

```sql
-- 0a. Does the assumed 1970-01-01 epoch decode to sane dates?
SELECT
    MAX(create_date) AS [max_day_number],
    DATEADD(day, MAX(create_date), CAST('1970-01-01' AS DATE)) AS [decodes_to],
    MIN(create_date) AS [min_day_number],
    DATEADD(day, MIN(create_date), CAST('1970-01-01' AS DATE)) AS [min_decodes_to]
FROM bib_control;

-- 0b. Who created records on the target day, and how many?
SELECT
    bc.create_user AS [create_user],
    COUNT(*)       AS [bibs_created]
FROM bib_control bc
WHERE bc.create_date = DATEDIFF(day, '1970-01-01', '2026-08-25')
GROUP BY bc.create_user
ORDER BY [bibs_created] DESC;
```

How to read the results:

- **0a is a sanity check only — it cannot prove the epoch.** `decodes_to` should
  land on or near today and `min_decodes_to` on the catalog's oldest load, but
  "newest record is yesterday" and "newest record is today" are equally ordinary,
  so a **one-day** anchor error passes this test unnoticed. If it is off by weeks
  or nonsensical, stop and re-derive the encoding. To actually pin the anchor,
  use the weekday-histogram method in
  [`docs/schema/conventions.md`](../../docs/schema/conventions.md#re-verifying-after-a-restore-or-on-another-horizon-database).
- **0b returns zero rows** → the epoch is wrong (an entirely empty day is
  implausible for a working catalog), or that day genuinely had no cataloguing.
  0a distinguishes these.
- **0b returns rows but no `CATALOGER`** → the operator is stored under a different
  string (a staff ID, a domain-qualified login, a differently-spelled name).
  Take the exact value from this list and use it in Query A.

Do not skip this. A wrong epoch and a mis-spelled operator both produce an
*empty* Query A, which is indistinguishable from a legitimate "no records
matched."

---

## Query A — The Report (Read-Only)
**One row per bib.** Columns: `bib#`, `title`, `create_user`, `create_date`.
Run in SSMS, then right-click the grid → **Save Results As… → CSV**.

Uses **no `STRING_AGG`**, so it runs on any SQL Server version and any database
compatibility level — this Horizon database's compat level is below where
`STRING_AGG` is available. For the `590` note text on any record, use **Query B**.

```sql
SELECT
    bc.[bib#]      AS [bib#],
    t.title        AS [title],
    bc.create_user AS [create_user],
    DATEADD(day, bc.create_date, CAST('1970-01-01' AS DATE)) AS [create_date]
FROM bib_control bc
OUTER APPLY (                        -- 245$a title (see "Title parsing" below)
    SELECT TOP 1
        RTRIM(CASE WHEN RIGHT(RTRIM(raw.sa), 1) IN ('/',':',';',',','=','.')
                   THEN RTRIM(LEFT(RTRIM(raw.sa), LEN(RTRIM(raw.sa)) - 1))
                   ELSE RTRIM(raw.sa) END) AS title
    FROM bib t245
    CROSS APPLY (SELECT CHARINDEX(CHAR(31) + 'a', t245.text) AS pa) m
    CROSS APPLY (SELECT NULLIF(CHARINDEX(CHAR(31), t245.text, m.pa + 2), 0) AS nxt,
                        NULLIF(CHARINDEX(CHAR(30), t245.text, m.pa + 2), 0) AS fend) d
    CROSS APPLY (SELECT SUBSTRING(
                     t245.text, m.pa + 2,
                     COALESCE((SELECT MIN(v) FROM (VALUES (d.nxt),(d.fend)) x(v)),
                              LEN(t245.text) + 1) - (m.pa + 2)) AS sa) raw
    WHERE t245.[bib#] = bc.[bib#] AND t245.tag = '245' AND m.pa > 0
    ORDER BY t245.tagord             -- lowest-tagord 245 segment
) t
WHERE bc.create_user = 'CATALOGER'
  AND bc.create_date = DATEDIFF(day, '1970-01-01', '2026-08-25')
  AND EXISTS (                       -- some 590 contains ProQuest
        SELECT 1 FROM bib p
        WHERE p.[bib#] = bc.[bib#]
          AND p.tag = '590'
          AND p.text LIKE '%ProQuest%')
ORDER BY bc.[bib#];
```

`EXISTS` (not a join) is what holds this to one row per bib: it stops at the
first matching `590` and returns a boolean, so a record with three ProQuest
`590`s still contributes exactly one row.

`OUTER APPLY` (not `CROSS APPLY`) keeps a qualifying bib even when its `245$a`
cannot be parsed — `title` comes back `NULL` rather than the record vanishing.
The report must never silently hide a record the operator created.

---

## Query B — Detail / Verification (Read-Only)
**One row per `590` tag** on a qualifying bib — every `590`, not just the
ProQuest ones, so a title's full note history is visible. Row count exceeds the
record count from Query A — expected, not a bug.

```sql
SELECT
    bc.[bib#]      AS [bib#],
    bc.create_user AS [create_user],
    b.tag          AS [tag],
    b.text         AS [text]
FROM bib_control bc
INNER JOIN bib b
        ON b.[bib#] = bc.[bib#]
       AND b.tag = '590'
WHERE bc.create_user = 'CATALOGER'
  AND bc.create_date = DATEDIFF(day, '1970-01-01', '2026-08-25')
  AND EXISTS (
        SELECT 1 FROM bib p
        WHERE p.[bib#] = bc.[bib#]
          AND p.tag = '590'
          AND p.text LIKE '%ProQuest%')
ORDER BY bc.[bib#], b.tagord;
```

The `INNER JOIN` here is deliberate — this query *wants* the one-row-per-`590`
fan-out. The `EXISTS` still gates **which bibs** appear; the join then expands
each of those bibs to all its `590`s. Note `b.text` contains raw `CHAR(31)`
subfield delimiters, which render as control characters in the SSMS grid.

---

## Query C — Count (Read-Only)
The single authoritative record count for the day.

```sql
SELECT COUNT(*) AS [bibs]
FROM bib_control bc
WHERE bc.create_user = 'CATALOGER'
  AND bc.create_date = DATEDIFF(day, '1970-01-01', '2026-08-25')
  AND EXISTS (
        SELECT 1 FROM bib p
        WHERE p.[bib#] = bc.[bib#]
          AND p.tag = '590'
          AND p.text LIKE '%ProQuest%');
```

This must equal Query A's row count. If it does not, the `OUTER APPLY` title
block in Query A is emitting more than one row per bib — check that its
`TOP 1` is intact.

---

## Changing the date or operator
Applied identically to Queries A, B, and C:

- **Different day** — change the date literal in
  `DATEDIFF(day, '1970-01-01', '2026-08-25')`. Do not change `'1970-01-01'`;
  that is the epoch, not a parameter.
- **A date range** — replace the `=` predicate with
  `bc.create_date BETWEEN DATEDIFF(day,'1970-01-01','2026-08-25')
   AND DATEDIFF(day,'1970-01-01','2026-08-31')`. `BETWEEN` is inclusive of both
  endpoints and is safe here precisely because `create_date` is a whole-day
  integer with the time held separately in `create_time`.
- **Different operator** — change `'CATALOGER'`. Use the exact spelling Query 0b
  returned, not the one you expect.
- **Last editor instead of creator** — swap `create_user`/`create_date` for
  `change_user`/`change_date`. Both pairs exist on `bib_control`; they answer
  different questions.
- **Time of day** — `create_time` exists but its **encoding is unverified**
  (minutes since midnight, or `hhmm`?). Confirm it against a record with a known
  creation time before putting it in a predicate.

---

## Title parsing (`245$a`)
Reused verbatim from `590-proquest-purchase-removal-report`. `bib.text` stores a
MARC field's subfields delimited by `CHAR(31)`, with an optional trailing
`CHAR(30)`: `CHAR(31)+'a'+<title>+CHAR(31)+'c'+<author>…`. The `OUTER APPLY`
locates the `$a` delimiter, takes the text up to the next `CHAR(31)`/`CHAR(30)`
(or end of string), and strips one trailing ISBD punctuation mark
(`/ : ; , = .`) plus spaces. Horizon splits `245`s over 255 chars across multiple
`bib` rows (incrementing `tagord`); the lowest-`tagord` segment is used, so such
titles truncate to the first segment (rare for `245`).

## Notes and edge cases
- **No item table is involved.** "Created by CATALOGER" is a bib-level fact from
  `bib_control`, and the `590` is a bib-level tag, so `item` /
  `item_with_title` never enter the query. This report therefore includes
  ProQuest records regardless of collection — it is *not* restricted to `EBK`
  the way `590-proquest-purchase-removal-report` is. Add
  `AND EXISTS (SELECT 1 FROM item_with_title i WHERE i.[bib#] = bc.[bib#]
  AND i.collection = 'EBK')` if an EBK restriction is wanted.
- **No `purchase` condition.** Unlike the removal report, this one matches on
  `ProQuest` alone — purchase, DDA, and subscription notes all qualify. Query B
  shows which is which.
- **`status` is deliberately not filtered.** Confirmed with the requester that
  record status is out of scope here: every record `CATALOGER` created that day with a
  ProQuest `590` is listed, whatever its `bib_control.status`. `staff_only` is
  likewise unfiltered. This is a scope decision, not an oversight — do not add a
  status predicate without asking.
- `tagord` is order-only (and used in the title parser); it is not an output
  column.
- Query A and Query C row counts agree and are authoritative. Query B's larger
  row count is intentional.

---

## Building the delete-list table

The report above only *lists* records. To hand the set to Horizon's batch-delete
utility it must be materialised into a one-column table keyed on `bib#`.

### One command for the whole sequence

`tools\Invoke-DeleteListRun.ps1` runs every step below end to end — verify,
build, grant, pre-flight, delete, post-verify — with a single typed
confirmation before the irreversible part.

**Start here** — this runs steps 1–3 and stops, creating nothing:

```powershell
tools\Invoke-DeleteListRun.ps1 -Table ProQuest_CAT_20260825_DeleteList `
    -CreateUser CATALOGER -CreateDate 2026-08-25 -ExpectedRows 6790 -Brutal -WhatIfOnly
```

`-Server` and `-Database` are mandatory, so PowerShell prompts for them. Drop
`-WhatIfOnly` to perform the real run, and add `-StaffPrincipal <name>` — with a
real principal name, not the placeholder — to grant read access as step 6.

> **Do not paste angle-bracket placeholders into PowerShell.** `<` is a reserved
> redirection operator and the line fails to parse before anything runs:
> *"The '<' operator is reserved for future use."* Either substitute a real
> value with no brackets, or omit the parameter and let PowerShell prompt.
> Every mandatory parameter prompts, so the shortest safe invocation is simply:
>
> ```powershell
> tools\Invoke-DeleteListRun.ps1 -Brutal -WhatIfOnly
> ```
>
> and answer each prompt in turn.

| Step | Does what | Catalog touched |
| ---: | --- | --- |
| 1 | Connect, verify the login | no |
| 2 | Count the selection — must equal `-ExpectedRows` | no |
| 3 | Discriminator: has the `590` filter ever excluded anything? | no |
| 4 | Create `dbo.<Table>` with `PRIMARY KEY CLUSTERED ([bib#])` | no |
| 5 | Populate in a transaction, count-checked, committed | no |
| 6 | `GRANT SELECT` to the staff principal | no |
| 7 | Pre-flight: orphaned codes, row count, audit file | no |
| 8 | **Confirmation** — type the row count | — |
| 9 | KillBib | **yes, irreversible** |
| 10 | Post-verify: listed bibs gone, item rows gone | no |

Any failure in steps 1–7 aborts before step 9. Step 2 aborting means the live
selection no longer matches the count you reviewed — the data drifted, so
re-review rather than adjusting `-ExpectedRows` to whatever it returns now.

**`-WhatIfOnly` runs steps 1–3 and stops**, creating nothing. That is the
closest thing to a dry run that exists here, and it is worth doing first:

```powershell
tools\Invoke-DeleteListRun.ps1 ... -WhatIfOnly
```

Other switches: `-Trial` opts back into a single-bib trial delete before the
full run (off by default); `-Yes` skips the typed confirmation; `-HorizonUserId`
and `-Location` map to KillBib's `/r` and `/l`.

The selection predicate is defined **once** inside the script and reused for the
count, the discriminator and the `INSERT`, so those three cannot drift apart —
the same guarantee the manual steps below make by using an identical `WHERE`
clause in Query A, Query C and the load.

Parameters that reach SQL (`-Table`, `-CreateUser`, `-NoteTerm`, `-NoteTag`,
`-StaffPrincipal`) are validated as plain identifiers before any query is built.

### The manual steps

Everything below is what the script automates, kept because the README is the
source of truth and because a step sometimes needs running by hand.

### Why `CREATE TABLE` + `INSERT` and not `SELECT INTO`

**This database runs in `FULL` recovery** (confirmed 2026-08-27 via
`sys.databases.recovery_model_desc`). `SELECT INTO` is minimally logged only
under `SIMPLE` or `BULK_LOGGED`, so under `FULL` it is fully logged like any
other insert — the log saving that would justify it does not exist here.

Worse, the `SELECT INTO` route would generate **more** log, not less. It needs
three logged operations where the explicit form needs one:

| `SELECT INTO` route | Log cost |
| --- | --- |
| `SELECT INTO` — 6,790 rows into a heap | fully logged |
| `ALTER COLUMN [bib#] INT NOT NULL` | **rewrites the whole table** — fully logged |
| `ADD PRIMARY KEY CLUSTERED` | **rebuilds the table into index order** — fully logged |

Against that, `CREATE TABLE` with the key declared up front, then one `INSERT`,
writes the rows **straight into the clustered index, once**. Fewer statements,
less log, and no table rewrite.

So the explicit form wins on every axis here: it is two statements instead of
three, needs no `ALTER COLUMN` (the nullability trap disappears because the
column is declared `NOT NULL`), enforces the key *during* the load rather than
after, and rolls back cleanly on any problem instead of stranding a populated but
unkeyed table.

At 6,790 rows the absolute log volume is small either way. The reasoning matters
more for the next, larger run than for this one.

> **If log growth is ever a genuine constraint on a bigger set**, the levers are
> batched inserts with a log backup between batches, or temporarily switching the
> database to `BULK_LOGGED` for the load — a decision for whoever owns the backup
> and point-in-time-restore policy, **not** something to change unilaterally to
> speed up a delete-list build.

### This table exists to delete 6,790-odd records — review before you build it

> **Run Query A, review its output, and save the CSV before running anything in
> this section.** The repo convention is that a delete list is built from a
> *reviewed* set, not from a query nobody has read. Two specific risks here:
>
> - **This set is defined by a bulk load, not by a defect.** Every record `CATALOGER`
>   created on 2026-08-25 with a ProQuest `590` is in scope. If that day's load
>   added anything legitimately wanted, it goes too.
> - **The live `590` data drifts.** In the earlier ProQuest removal work the
>   subscription-flagged count fell from 6 to 2 over a few days. A re-run at
>   delete time can differ from what was approved.
>
> Keep the reviewed CSV alongside the generated script as the deletion's audit
> record. It is the only evidence of what was actually signed off.

### Order of operations

1. **Query C** — the count. Everything below reconciles against it, so get it
   first.
2. **Query A** — review the output and save the CSV. This is the approval gate.
3. **Steps 1–2** — create and populate; check `rows_inserted` against Query C
   before committing.
4. **Steps 0 and 3** — look up the principal and grant.
5. **Step 4** — verify, then hand off to `killbib` (Step 5).

### Step 0 — Find the staff principal

Numbered 0 so it is not forgotten, but it is **independent of the table build** —
it only feeds the `GRANT` in Step 3 and can be run at any point before it.

```sql
SELECT name        AS [principal],
       type_desc   AS [type]
FROM sys.database_principals
WHERE type IN ('R','G','U')          -- roles, Windows groups, users
  AND name NOT IN ('public','guest','INFORMATION_SCHEMA','sys')
  AND is_fixed_role = 0
ORDER BY type_desc, name;
```

**Do not guess the principal name.** A `GRANT` to a mistyped principal fails
loudly, which is the good case; a `GRANT` to the *wrong existing* principal
succeeds silently and gives the wrong people read access.

### Step 1 — Create the table

```sql
IF OBJECT_ID('dbo.ProQuest_CAT_20260825_DeleteList', 'U') IS NOT NULL
    DROP TABLE dbo.ProQuest_CAT_20260825_DeleteList;
GO

CREATE TABLE dbo.ProQuest_CAT_20260825_DeleteList (
    [bib#] INT NOT NULL
        CONSTRAINT PK_ProQuest_CAT_20260825_DeleteList
            PRIMARY KEY CLUSTERED ([bib#])
);
GO
```

**The `PRIMARY KEY CLUSTERED` *is* the index on `bib#`.** SQL Server builds a
unique clustered index to enforce it, so no separate `CREATE INDEX` is needed —
a second index on the same single column would duplicate the first and cost
space and maintenance for nothing.

Declaring `NOT NULL` here is what avoids the `SELECT INTO` nullability trap:
`bib_control.[bib#]` is itself nullable, so a `SELECT INTO` would inherit `NULL`
and then need an `ALTER COLUMN` before any key could be added.

The table is deliberately **one column**. `killbib` is known to work against this
shape; extra columns are untested with it. Provenance lives in the reviewed CSV,
not in the table.

### Step 2 — Populate it, count-checked before commit

```sql
BEGIN TRANSACTION;

INSERT INTO dbo.ProQuest_CAT_20260825_DeleteList ([bib#])
SELECT bc.[bib#]
FROM bib_control bc
WHERE bc.create_user = 'CATALOGER'
  AND bc.create_date = DATEDIFF(day, '1970-01-01', '2026-08-25')
  AND EXISTS (                       -- some 590 contains ProQuest
        SELECT 1 FROM bib p
        WHERE p.[bib#] = bc.[bib#]
          AND p.tag = '590'
          AND p.text LIKE '%ProQuest%');

SELECT @@ROWCOUNT AS [rows_inserted];

-- Compare rows_inserted against the Query C count and the reviewed CSV.
-- COMMIT only if all three agree.
-- COMMIT TRANSACTION;
-- ROLLBACK TRANSACTION;
```

The `WHERE` clause is **character-for-character identical** to Query A's and
Query C's. That is the repo's core guarantee: the rows loaded here are provably
the rows that were audited. If you change one, change all three.

`@@ROWCOUNT` is read immediately after the `INSERT`, so it reports the insert.
Do not put another statement between them.

Do not leave this transaction open while you go and reconcile spreadsheets — it
holds locks and log space. Have the Query C figure to hand first, then run,
compare, and commit or roll back promptly.

The primary key doubles as a correctness check during the load. `bib_control` is
one row per `bib#` and the `590` test is an `EXISTS`, so duplicates are
impossible and it should never fire. **If it does, the grain assumption behind
the whole report is wrong** — investigate rather than dropping the constraint to
force it through. The transaction means a failure leaves nothing behind.

### Step 3 — Grant read access to staff

Replace `<staff-principal>` with the exact name from Step 0.

```sql
GRANT SELECT ON dbo.ProQuest_CAT_20260825_DeleteList TO [<staff-principal>];
GO
```

`SELECT` only. The external delete program reads this list; nothing should be
writing to it after it is built and reconciled. Granting `INSERT`/`DELETE` would
let the approved set be altered after sign-off, defeating the audit trail.

### Step 4 — Verify before handing it off

This is the gate. Run all three and read the output.

```sql
-- 1. Row count must equal Query C and the reviewed CSV
SELECT COUNT(*) AS [rows_loaded]
FROM dbo.ProQuest_CAT_20260825_DeleteList;

-- 2. The key exists, is clustered and unique
SELECT i.name AS [index_name], i.type_desc, i.is_unique, i.is_primary_key
FROM sys.indexes i
WHERE i.object_id = OBJECT_ID('dbo.ProQuest_CAT_20260825_DeleteList')
  AND i.type > 0;

-- 3. The grant landed on the intended principal
SELECT dp.name            AS [principal],
       dp.type_desc       AS [principal_type],
       p.permission_name  AS [permission],
       p.state_desc       AS [state]
FROM sys.database_permissions p
INNER JOIN sys.database_principals dp
        ON dp.principal_id = p.grantee_principal_id
WHERE p.major_id = OBJECT_ID('dbo.ProQuest_CAT_20260825_DeleteList');
```

A grant that silently went to the wrong principal looks identical to a correct
one — until someone cannot read the table, or someone who should not have access
can.

If any check is wrong, `DROP TABLE` and start again from Step 1. Nothing in the
catalog has been touched at this point.

### Step 5 — Hand off to KillBib

Flags are documented from `KillBib.exe /?` (version 7.61) in
`590-proquest-purchase-removal-report/README.md`, along with the
`FK_stat_data_location` failure mode and how to resume with `/b`.

> **There is no dry-run.** KillBib's `/w` flag — *"don't wipe bib/bib_control
> rows (default is yes)"* — proves the default behaviour deletes bib rows with
> or without `/k`. `/k` widens the blast radius to items, copies and circ data;
> it does not switch deletion on. Nothing here can be run to "see what happens".

#### Use the wrapper

```powershell
tools\Invoke-KillBib.ps1 -Table ProQuest_CAT_20260825_DeleteList `
    -ExpectedRows 6790 -Brutal
```

`-Server` and `-Database` are mandatory and will be prompted for. Supply them
inline only with real values — an angle-bracket placeholder makes PowerShell
fail to parse the line (`<` is a reserved redirection operator).

It runs, in order: locate `KillBib.exe` → the four pre-flight checks → a
**mandatory single-bib trial** (`/b` and `/e` set to the same bib#) → stop, so
you can verify that one deletion → full run behind a typed row-count
confirmation. On a non-zero exit it runs the orphaned-code diagnostic and prints
the resume command; it never resumes on its own.

The password is prompted for as a `SecureString` and never written to disk.
**It is still visible in the process list while KillBib runs** — `/p<password>`
on the command line is inherent to the utility and no wrapper can hide it.

After the trial, verify before continuing:

```sql
SELECT COUNT(*) AS [bib_control] FROM bib_control WHERE [bib#] = <trial-bib#>;  -- 0
SELECT COUNT(*) AS [bib]         FROM bib         WHERE [bib#] = <trial-bib#>;  -- 0
SELECT COUNT(*) AS [item]        FROM item        WHERE [bib#] = <trial-bib#>;  -- 0 with /k
```

Then re-run with `-SkipTrial -Force` for the full batch.

#### Or run it by hand

```text
KillBib.exe /s<server> /u<login> /p<password> /dILSDB /tProQuest_CAT_20260825_DeleteList /k
```

Never commit real logins or passwords — this repository is public.

#### Afterwards

```sql
-- Every listed bib should be gone
SELECT COUNT(*) AS [still_present]
FROM bib_control bc
INNER JOIN dbo.ProQuest_CAT_20260825_DeleteList d ON d.[bib#] = bc.[bib#];
```

KillBib **skips copies that have issues or predictions attached** rather than
deleting them, so on a list containing serials some copies can survive a
successful run. Re-count rather than assuming.

### Step 6 — Verify, then clean up

**Verify first. Do not drop anything until both counts return 0.**

```sql
-- Every listed bib gone from the catalog
SELECT COUNT(*) AS [still_present]
FROM bib_control bc
INNER JOIN dbo.PQ_CAT_20260825_DeleteList d ON d.[bib#] = bc.[bib#];

-- Items gone too (only with /k)
SELECT COUNT(*) AS [items_left]
FROM item i
INNER JOIN dbo.PQ_CAT_20260825_DeleteList d ON d.[bib#] = i.[bib#];
```

A non-zero `items_left` with a zero `still_present` is not a failure — KillBib
skips copies with issues or predictions attached. Investigate before dropping
the list, because the list is what identifies the affected bibs.

Once both are 0, drop the scratch objects. **`SET LOCK_TIMEOUT` matters here:**
a delete-list table from an interrupted earlier run can still be held by an
orphaned session, and without it the `DROP` hangs indefinitely rather than
telling you so.

```sql
-- Fail in 10s rather than hanging on a lock left by an interrupted run.
SET LOCK_TIMEOUT 10000;

-- What is about to be dropped, and how many rows each holds.
SELECT t.name AS [table], SUM(p.rows) AS [rows]
FROM sys.tables t
INNER JOIN sys.partitions p
        ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name IN ('PQ_CAT_20260825_DeleteList',
                 'ProQuest_CAT_20260825_DeleteList',
                 'ProQuest_CAT_20260825_DeleteList_2',
                 'KillBibProbe')
GROUP BY t.name
ORDER BY t.name;
GO

SET LOCK_TIMEOUT 10000;

IF OBJECT_ID('dbo.PQ_CAT_20260825_DeleteList','U') IS NOT NULL
BEGIN DROP TABLE dbo.PQ_CAT_20260825_DeleteList;        PRINT 'dropped PQ_CAT_20260825_DeleteList'; END
ELSE PRINT 'PQ_CAT_20260825_DeleteList not present';

IF OBJECT_ID('dbo.ProQuest_CAT_20260825_DeleteList','U') IS NOT NULL
BEGIN DROP TABLE dbo.ProQuest_CAT_20260825_DeleteList;  PRINT 'dropped ProQuest_CAT_20260825_DeleteList'; END
ELSE PRINT 'ProQuest_CAT_20260825_DeleteList not present';

IF OBJECT_ID('dbo.ProQuest_CAT_20260825_DeleteList_2','U') IS NOT NULL
BEGIN DROP TABLE dbo.ProQuest_CAT_20260825_DeleteList_2; PRINT 'dropped ProQuest_CAT_20260825_DeleteList_2'; END
ELSE PRINT 'ProQuest_CAT_20260825_DeleteList_2 not present';

IF OBJECT_ID('dbo.KillBibProbe','U') IS NOT NULL
BEGIN DROP TABLE dbo.KillBibProbe;                       PRINT 'dropped KillBibProbe'; END
ELSE PRINT 'KillBibProbe not present';
GO

-- Confirm nothing is left.
SELECT name FROM sys.tables
WHERE name LIKE '%DeleteList%' OR name = 'KillBibProbe'
ORDER BY name;
```

**If a `DROP` fails with "Lock request time out period exceeded",** that table
is still held by an orphaned session from an interrupted run. It is harmless —
a one-column table of integers — so leave it and retry later, or have a sysadmin
`KILL` the session. The ordinary SQL login cannot enumerate sessions:
`sys.dm_exec_sessions` silently returns only its own row rather than erroring,
which reads like "no orphan exists".

**The delete-list table is not the audit record.** That is the timestamped CSV
in `killbib-audit\`, written before anything was deleted. Dropping the table
loses nothing.

### Alternative: `SELECT INTO` (only under `SIMPLE` / `BULK_LOGGED`)

Not applicable to this database as configured, kept for a differently-configured
instance. Under `SIMPLE` or `BULK_LOGGED` recovery `SELECT INTO` is minimally
logged, which can matter for a much larger set:

```sql
SELECT bc.[bib#]
INTO dbo.ProQuest_CAT_20260825_DeleteList
FROM bib_control bc
WHERE /* ...same predicate... */;

ALTER TABLE dbo.ProQuest_CAT_20260825_DeleteList
    ALTER COLUMN [bib#] INT NOT NULL;          -- required: SELECT INTO inherits NULL
GO
ALTER TABLE dbo.ProQuest_CAT_20260825_DeleteList
    ADD CONSTRAINT PK_ProQuest_CAT_20260825_DeleteList
        PRIMARY KEY CLUSTERED ([bib#]);
```

Check the recovery model before assuming the benefit applies:

```sql
SELECT name AS [database], recovery_model_desc AS [recovery_model]
FROM sys.databases
WHERE database_id = DB_ID();
```

Do not wrap this form in an explicit transaction — an open transaction defeats
minimal logging, which is the only reason to use it. Its trade-offs: the
`ALTER COLUMN` rewrites the table, the key is enforced only after loading, and a
duplicate leaves a populated but unkeyed table to clean up by hand.
