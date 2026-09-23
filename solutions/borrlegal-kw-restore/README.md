# borrLegal_KW restore

## The Problem

`dbo.borrLegal_KW` was dropped along with its three DML triggers. The table has
since been recreated and the immediate edit error cleared, but **the triggers and
the table's permissions did not come back with it**. A cataloguer editing a
borrower record hits the path those triggers sit on.

Three things have to be true before this is finished, and only the first has
been done:

1. the table exists again — **done**
2. `borrLegal_KW_i_trig`, `_u_trig` and `_d_trig` exist and are enabled
3. the principal that used the table can reach it again

And one thing nobody has checked: **what happened to the keyword counters while
the triggers were missing.** See "The part that is easy to miss" below.

### This is not a scratch table

Worth establishing up front, because the name looks local and the table was
dropped during a scratch-table cleanup.

`KW` is **keyword**. Horizon maintains a global keyword index in `dbo.word`, one
row per distinct word, carrying a per-index occurrence counter:

| Ord | Column |
| ---: | --- |
| 4 | `n_bibs` |
| 5 | `n_subjects` |
| 6 | `n_borrowers` |
| … | … |
| 18 | `n_title_wordkws` |
| **19** | **`n_borrLegalKW`** |

Looked up in `horizon-schema/all_tables_all_views.csv`, not inferred. **`dbo.word`
still carries `n_borrLegalKW`** — the keyword machinery is still wired to expect
this index, and it is why the triggers matter: they are what keeps the postings
and the counters in step.

More precisely, this is a **local customisation wired into a vendor table**, not
stock Horizon. `n_borrLegalKW` sits at ordinal 19, the last column of `word`, so
it was added after the base schema; and the table and its three triggers were
deployed together on **2023-07-26**, all four objects created within six seconds
of one another. Do not assume another Horizon site has any of this.

That combination — locally created, recent-ish, no declared PK, nothing
referencing it — is exactly why the scratch-table cleanup dropped it. See
[`db-scratch-table-cleanup`](../db-scratch-table-cleanup/README.md#the-second-discriminator-scratch-has-no-moving-parts),
which now excludes any table carrying triggers for this reason.

### The name is `borrLegal_KW`, not `borrLegal_WK`

The loose `find-borrlegal-wk.sql` script this solution replaces searched for
`borrLegal_WK`. **No object by either name exists in the schema export**, and no
`*_WK` object exists anywhere in it — but `word.n_borrLegalKW` does, and `KW`
for *keyword* is the convention the rest of that table follows
(`n_instrumentkws`, `n_genrekws`, `n_title_wordkws`).

`_WK` reads as a transposition. **Confirm it in Step 1a rather than taking this
on trust** — if a genuine second object exists, this solution does not cover it.

`borrLegal_KW` being absent from the export is expected and not evidence of
anything: the export was refreshed 2026-08-28, while the table was dropped, and
the table was recreated afterwards.

### Where the good copy lives

**The training database.** The loose scripts this solution replaces disagreed —
one said `TEST`, another said `TRAINING` — and it is the training copy that
still holds the intact table, triggers and grants.

Every read-only extraction below happens there. **Only Step 2b and Step 3 touch
production**, and each says so in its heading.

This README uses **`ILSTRAINDB`** for the training database and **`ILSDB`** for
production, per the placeholder table in
[`CLAUDE.md`](../../CLAUDE.md#never-publish-real-site-identifiers). Substitute
your own names, and **check the database in the SSMS toolbar, not the tab
title** — connecting to the wrong one is the step that goes wrong, and in Step 2b
it goes wrong silently.

Before relying on the training copy, satisfy yourself it is not stale: if it
predates the change that dropped the table, what it holds may not be what
production had. Step 1c's column comparison is the check.

### The part that is easy to miss

Restoring the triggers fixes **future** edits. It does not repair what happened
while they were gone.

If anything wrote to `borrLegal_KW` during the gap, those writes did not update
`word.n_borrLegalKW`, because the trigger that does so did not exist. The
counters can therefore be wrong in either direction, and nothing will report it
— a drifted keyword counter produces wrong search results, not an error.

Step 4 reconciles them. Do not skip it on the grounds that the edit error went
away; the edit error and the counter drift are separate consequences of the same
cause.

### A note on this solution's shape

This repo's contract is an audit `SELECT` listing the rows an `UPDATE` will
change, with identical joins. **These changes are DDL and DCL, not DML** — there
are no rows to list. The principle still applies and is enforced differently:

- the trigger bodies are **scripted from the training database**, never retyped;
- the `GRANT` statements are **generated from the training database's own
  permissions** by Step 1g, never hand-written.

In both cases what gets applied to production is mechanically derived from what
was reviewed, which is the guarantee the identical-joins rule exists to give.

### A backup is required before Step 2

Take a **full database backup** of production, or confirm one from today exists.
`CREATE TRIGGER` and `GRANT` are individually reversible, but the reconciliation
in Step 4 may lead to an `UPDATE` against `word`, and that one is not.

---

## Step 1: The Audit

**All read-only. Run every section and record the results before Step 2.**

### 1a. Production — what is actually missing?

```sql
-- Run in ILSDB (production).
-- Every table and column below was looked up in horizon-schema/, not inferred.
SELECT
    s.name                                AS [schema],
    o.name                                AS [object_name],
    o.type_desc                           AS [object_type],
    CONVERT(char(23), o.create_date, 121) AS [created]
FROM sys.objects o
INNER JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.name LIKE 'borrLegal%'
ORDER BY o.type_desc, o.name;
```

**Expect four rows** — the `USER_TABLE` plus the three triggers.

| Result | Meaning |
| --- | --- |
| 4 rows | Triggers are present. Check they are enabled (1b), then go to Step 3. |
| 1 row (table only) | Triggers gone. Continue. |
| 0 rows | The table is not there either. **Stop** — this solution assumes it was recreated. |

This query also answers the `_WK` question: if an object with that spelling
exists, it appears here.

### 1b. Production — are they enabled?

A disabled trigger is as good as an absent one, and it will not show up as
missing.

```sql
-- Run in ILSDB (production).
SELECT
    tr.name                   AS [trigger_name],
    OBJECT_NAME(tr.parent_id) AS [on_table],
    tr.is_disabled,
    tr.is_instead_of_trigger
FROM sys.triggers tr
WHERE tr.name LIKE 'borrLegal%'
ORDER BY tr.name;
```

If rows come back with `is_disabled = 1`, **do not recreate them** — enable them
instead and skip to Step 3:

```sql
-- Only if 1b shows existing but disabled triggers. Run in ILSDB.
ENABLE TRIGGER [borrLegal_KW_i_trig] ON [dbo].[borrLegal_KW];
ENABLE TRIGGER [borrLegal_KW_u_trig] ON [dbo].[borrLegal_KW];
ENABLE TRIGGER [borrLegal_KW_d_trig] ON [dbo].[borrLegal_KW];
```

### 1c. Both databases — does the recreated table match the original?

**Run in `ILSTRAINDB` and in `ILSDB`, and compare the two results row for row.**
If the column lists differ, the table was recreated wrong; neither triggers nor
grants will fix that, and a trigger written against the original shape may fail
at runtime. Stop and correct the table first.

```sql
-- Run in BOTH ILSTRAINDB and ILSDB. Compare the outputs.
SELECT
    c.column_id,
    c.name            AS [column_name],
    ty.name           AS [type_name],
    ty.is_user_defined,
    c.max_length,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity
FROM sys.columns c
INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.borrLegal_KW')
ORDER BY c.column_id;
```

```sql
-- Run in BOTH ILSTRAINDB and ILSDB. Indexes carry the grain; a missing unique
-- index lets duplicate postings in, which is a silent correctness problem.
SELECT
    i.name        AS [index_name],
    i.type_desc,
    i.is_unique,
    i.is_primary_key,
    c.name        AS [column_name],
    ic.key_ordinal
FROM sys.indexes i
INNER JOIN sys.index_columns ic
        ON ic.object_id = i.object_id AND ic.index_id = i.index_id
INNER JOIN sys.columns c
        ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID('dbo.borrLegal_KW')
ORDER BY i.name, ic.key_ordinal;
```

> **Record the column names from this step.** Step 4's reconciliation needs
> them, and this README deliberately does not guess what they are.

### 1d. Source — do the trigger bodies depend on anything else that was dropped?

**The check most worth not skipping.** A trigger that compiles cleanly can still
fail at runtime on a missing object, and it will fail *during a cataloguer's
edit* rather than at `CREATE` time.

**Populate `@Dropped` from your own cleanup's drop list** — the output of
[`db-scratch-table-cleanup` step 1d](../db-scratch-table-cleanup/README.md), or
whatever record exists of what was removed. Deliberately not hardcoded here:
those are local table names, they differ at every site, and at this one several
were named after the staff member who created them.

If no record of the drop list survives, derive the candidates instead — anything
the trigger bodies reference that does not currently exist is a problem whether
or not you know how it went missing. The second query below does that and needs
no list at all.

```sql
-- Run in ILSTRAINDB. Replace these with YOUR dropped object names.
DECLARE @Dropped TABLE (name sysname PRIMARY KEY);
INSERT INTO @Dropped (name) VALUES
 ('some_dropped_table'), ('another_dropped_table');

SELECT
    o.name AS [trigger_name],
    d.name AS [references_dropped_object]
FROM sys.sql_modules m
INNER JOIN sys.objects o ON o.object_id = m.object_id
INNER JOIN @Dropped d ON m.definition LIKE '%' + d.name + '%'
WHERE o.name LIKE 'borrLegal%'
ORDER BY o.name, d.name;
```

```sql
-- Run in ILSDB (production). The list-free version, and the better check:
-- what do the triggers reference that does not exist HERE, now? This catches
-- objects nobody remembered were dropped, which is the real risk.
--
-- Run it AFTER the triggers exist in production (after Step 2b) - an object
-- that is absent cannot have its references resolved.
SELECT
    OBJECT_NAME(d.referencing_id)  AS [trigger_name],
    d.referenced_entity_name       AS [missing_object]
FROM sys.sql_expression_dependencies d
WHERE OBJECT_NAME(d.referencing_id) LIKE 'borrLegal%'
  AND d.referenced_id IS NULL          -- unresolved = does not exist
  AND d.referenced_entity_name IS NOT NULL
ORDER BY [trigger_name], [missing_object];
```

`referenced_id IS NULL` means SQL Server could not resolve the name — the object
is not there. **No rows is the result you want.**

**No rows** = the triggers are self-contained and safe to recreate as they are.
**Any row** = that object has to be restored first, or you are installing a
runtime failure.

```sql
-- Run in ILSTRAINDB. Encrypted modules have definition = NULL and CANNOT be
-- text-searched, so the check above has a blind spot if any exist. Note them.
SELECT o.name AS [encrypted_module], o.type_desc
FROM sys.sql_modules m
INNER JOIN sys.objects o ON o.object_id = m.object_id
WHERE m.definition IS NULL;
```

### 1e. Source — read the trigger bodies

```sql
-- Run in ILSTRAINDB. sp_helptext preserves line breaks; the sys.sql_modules
-- grid does not, and it truncates long definitions.
EXEC sp_helptext 'dbo.borrLegal_KW_i_trig';
EXEC sp_helptext 'dbo.borrLegal_KW_u_trig';
EXEC sp_helptext 'dbo.borrLegal_KW_d_trig';
```

Read them. You are looking for what they do to `dbo.word` — that is the
behaviour Step 4 reconciles, and knowing which counter column they touch tells
you whether the assumption in Step 4 holds.

### 1f. Production — is an object-level grant needed at all?

```sql
-- Run in ILSDB. Substitute your real principal.
DECLARE @Principal sysname = 'staff_readers';

SELECT name, type_desc, is_fixed_role, default_schema_name
FROM sys.database_principals
WHERE name = @Principal;

-- Fixed-role membership covers every table automatically.
SELECT r.name AS [role_name], m.name AS [member_name]
FROM sys.database_role_members drm
INNER JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
INNER JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
WHERE m.name = @Principal
ORDER BY r.name;

-- Database-wide (class 0) and schema-wide (class 3) grants cover it too.
SELECT dp.class_desc, dp.permission_name, dp.state_desc,
       CASE dp.class WHEN 3 THEN SCHEMA_NAME(dp.major_id) ELSE '' END AS [on_schema]
FROM sys.database_permissions dp
WHERE dp.grantee_principal_id = DATABASE_PRINCIPAL_ID(@Principal)
  AND dp.class IN (0, 3)
ORDER BY dp.class, dp.permission_name;
```

**If the principal is in `db_datareader`/`db_datawriter`, or holds a schema-wide
grant on `dbo`, the recreated table is already covered. Grant nothing** — an
unnecessary object-level grant is noise the next person has to interpret.

### 1g. Source — generate the grants, do not invent them

```sql
-- Run in ILSTRAINDB. This produces statements to run in ILSDB.
SELECT
    CASE dp.state_desc
         WHEN 'GRANT_WITH_GRANT_OPTION' THEN 'GRANT'
         ELSE dp.state_desc
    END
    + ' ' + dp.permission_name
    + CASE WHEN dp.minor_id <> 0
           THEN ' (' + QUOTENAME(COL_NAME(dp.major_id, dp.minor_id)) + ')'
           ELSE '' END
    + ' ON dbo.' + QUOTENAME(o.name)
    + ' TO ' + QUOTENAME(pr.name)
    + CASE WHEN dp.state_desc = 'GRANT_WITH_GRANT_OPTION'
           THEN ' WITH GRANT OPTION' ELSE '' END
    + ';'                                    AS [statement_to_run_in_prod],
    pr.name                                  AS [grantee],
    pr.type_desc                             AS [grantee_type]
FROM sys.database_permissions dp
INNER JOIN sys.objects o              ON o.object_id     = dp.major_id
INNER JOIN sys.database_principals pr ON pr.principal_id = dp.grantee_principal_id
WHERE dp.class = 1
  AND o.name = 'borrLegal_KW'
ORDER BY pr.name, dp.permission_name;
```

**If this returns nothing**, the table never carried object-level grants and
access came from role membership. Grant nothing; 1f is your answer.

**Record this output.** It is what Step 3 applies, verbatim.

---

## Step 2: The Update — triggers

**Everything above is read-only. This is the first step that changes production.**

### 2a. Script the triggers from the source

Not SQL — do this in Object Explorer:

> **`ILSTRAINDB`** → Tables → `dbo.borrLegal_KW` → Triggers →
> right-click each → **Script Trigger as → CREATE To → New Query Editor Window**

All three.

**Do not copy trigger bodies out of a results grid.** The scripting route emits
the `SET ANSI_NULLS` / `SET QUOTED_IDENTIFIER` headers, and a trigger created
under the wrong `SET` options can behave differently from the original **without
erroring** — which is the worst failure mode available here.

`Script Table as → CREATE To` does **not** reliably include triggers; it depends
on *Tools → Options → SQL Server Object Explorer → Scripting → Script triggers*,
which is not dependably on. Script the triggers individually.

### 2b. Change the connection to production, then run them

Check the database name in the SSMS toolbar. Then run the three scripts
**unedited** — keep the `SET` statements and the `GO` batch separators.

```sql
-- Run in ILSDB. Paste the three scripted CREATE TRIGGER statements here,
-- exactly as 2a produced them. Each arrives looking roughly like:
--
--   SET ANSI_NULLS ON
--   GO
--   SET QUOTED_IDENTIFIER ON
--   GO
--   CREATE TRIGGER [dbo].[borrLegal_KW_i_trig] ON [dbo].[borrLegal_KW]
--   ...
--   GO
```

### 2c. Confirm

```sql
-- Run in ILSDB. Expect four rows, and is_disabled = 0 on all three triggers.
SELECT o.name AS [object_name], o.type_desc
FROM sys.objects o
WHERE o.name LIKE 'borrLegal%'
ORDER BY o.type_desc, o.name;

SELECT tr.name AS [trigger_name], OBJECT_NAME(tr.parent_id) AS [on_table],
       tr.is_disabled
FROM sys.triggers tr
WHERE tr.name LIKE 'borrLegal%'
ORDER BY tr.name;
```

---

## Step 3: The Update — permissions

Skip entirely if 1f showed the principal is already covered, or if 1g returned
nothing.

```sql
-- Run in ILSDB. Paste the output of 1g here, unedited. Do not hand-write these.
-- They will look like:
--   GRANT SELECT ON dbo.[borrLegal_KW] TO [staff_readers];
--   GRANT INSERT ON dbo.[borrLegal_KW] TO [staff_readers];
```

Verify against the effective permissions, which is the only answer that accounts
for role membership as well as object grants:

```sql
-- Run in ILSDB. Should now agree with 1g's list.
DECLARE @Check sysname = 'staff_readers';

EXECUTE AS USER = @Check;
    SELECT permission_name
    FROM fn_my_permissions('dbo.borrLegal_KW', 'OBJECT')
    ORDER BY permission_name;
REVERT;
```

---

## Step 4: Reconcile the keyword counters

**Do not skip this because the edit error went away.** While the triggers were
absent, writes to `borrLegal_KW` did not maintain `word.n_borrLegalKW`. Drift
there produces wrong keyword search results, never an error.

> **This step rests on an assumption this repo could not verify:** that
> `borrLegal_KW` carries a `word#` column joining it to `dbo.word`, which is the
> standard shape for a Horizon keyword posting table. **`borrLegal_KW` is not in
> the schema export** — it was dropped when the export was taken — so the column
> could not be looked up, and this README will not guess it.
>
> **Confirm against 1c's column list before running the query below**, and adjust
> the join column to whatever 1c actually reported. If there is no such column,
> read the trigger bodies from 1e instead: they state exactly which columns the
> counter is derived from, and that is authoritative.

```sql
-- Run in ILSDB. READ-ONLY - it reports drift, it does not correct it.
-- Adjust kw.[word#] to the actual join column from 1c if it differs.
SELECT TOP 200
    w.[word#],
    w.word,
    w.n_borrLegalKW      AS [counter_says],
    kw.actual            AS [postings_actually_present],
    kw.actual - w.n_borrLegalKW AS [drift]
FROM dbo.word w
INNER JOIN (
        SELECT k.[word#], COUNT(*) AS actual
        FROM dbo.borrLegal_KW k
        GROUP BY k.[word#]
) kw ON kw.[word#] = w.[word#]
WHERE kw.actual <> w.n_borrLegalKW
ORDER BY ABS(kw.actual - w.n_borrLegalKW) DESC;
```

```sql
-- Run in ILSDB. The other direction: counter says there are postings, but none
-- exist. An INNER JOIN above cannot see these.
SELECT TOP 200 w.[word#], w.word, w.n_borrLegalKW AS [counter_says]
FROM dbo.word w
WHERE w.n_borrLegalKW <> 0
  AND NOT EXISTS (SELECT 1 FROM dbo.borrLegal_KW k WHERE k.[word#] = w.[word#])
ORDER BY w.n_borrLegalKW DESC;
```

**No rows from either = nothing drifted.** Record that and stop; it is a real
result, not a non-event.

**Rows from either** — do not hand-correct them. Horizon builds these indexes
with its own reindex utility, and that is the supported repair. Raise it with
SirsiDynix support, quoting the drift counts. Correcting `word` by hand risks
making the counters agree with a posting table that is itself incomplete, which
is worse than visible drift because it looks fixed.

---

## Step 5: Verify with a real edit

Have a cataloguer edit a borrower record.

This matters more than it reads. **The triggers now fire on that path.** A
successful edit *before* they existed does not prove the edit still succeeds with
them in place — the original failure was on this exact path, and the only
evidence that it is genuinely repaired is the path working with everything
restored.

---

## Notes and edge cases

- **`_WK` vs `_KW`.** Step 1a is the check. No `*_WK` object exists in the schema
  export, and `word.n_borrLegalKW` follows the `KW`-for-keyword convention of its
  neighbours (`n_genrekws`, `n_title_wordkws`). If 1a does turn up a genuine
  `_WK` object, this solution does not cover it — treat it separately.
- **Where the object came from.** `borrLegal_KW` being absent from
  `horizon-schema/` is expected: the export was refreshed 2026-08-28 while the
  table was dropped. Its absence there is not evidence that it is not Horizon's.
  `word.n_borrLegalKW` is the evidence that it is.
- **`n_borrLegalKW` is column 19 of `word`** — the last, so probably added after
  the base schema. Treat this index as site-configured; another Horizon site may
  not have it.
- **Case sensitivity.** The collation is `CI`, so `LIKE 'borrLegal%'` matches
  whatever casing the objects actually carry. Do not "fix" the casing in these
  queries to match Object Explorer.
- **Deliberately not automated**: the trigger creation and the grants are both
  paste-the-generated-output steps. Generating DDL and executing it in one pass
  would remove the review point that makes this safe, and the review point is the
  whole design.
- **Not covered here**: rebuilding the keyword index itself. Step 4 detects
  drift; repairing it is Horizon's reindex utility, not SQL.
- **Do not trust the `runbook.html` badges on the two paste blocks.** Step 2b
  and Step 3 arrive as comment-only placeholders, so the generator classifies
  them *Read-only* — correctly, since they contain no executable SQL as shipped.
  They become the two statements that change production the moment you paste
  into them. The badge describes the file, not what you are about to run.
