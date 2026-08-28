# Scratch and backup table cleanup

## The Problem

The database holds **969 user tables**, and an unknown number of them are not
Horizon's. Years of ad-hoc work leave behind scratch copies, pre-change backups,
and one-off working sets: `tmp*`, `del*`, `*_bak`, `ITEM_*` variants,
`temp_*_history`, delete lists from past batch removals.

They cost little space but they are actively harmful in two ways:

1. **They look authoritative.** A query written against a stale `*_bak` table
   returns plausible, wrong answers. `docs/schema/AGENTS.md` has a rule about
   this because it is a live hazard, not a theoretical one.
2. **They pollute the schema reference.** Every one appears in
   `horizon-schema/` and in the generated index pages, so anyone browsing for a
   real table wades through scratch.

### Why you cannot do this by name

**There is no safe name pattern.** `tmp`, `del`, `temp` and `bak` prefixes appear
on tables Horizon itself ships — the vendor uses them for its own working
storage, and the application recreates and depends on some of them. Dropping one
breaks the ILS in a way that will not surface until whichever module uses it
next runs.

So the audit below does **not** classify by name. It classifies by **when the
table was created**, cross-checked against what depends on it.

### The discriminator: creation date

`sys.tables.create_date` records when each object was created. Tables that
arrived with an install or upgrade share that event's timestamp, clustered
tightly — hundreds of tables within the same minute. A locally-created scratch
table has an isolated timestamp on an ordinary working day.

That gives a defensible rule: **anything created in a large same-moment cluster
is vendor; anything created alone, later, is local.** Step 1 shows you the
clusters so you can pick the cutoff yourself rather than trusting a guess.

### A backup is required before Step 2

`DROP TABLE` is not recoverable. Take a full database backup — not just `bib`
and `item` — because this touches objects outside the catalog tables.

---

## Step 1: The Audit

Run all four parts. **Read them in order**; each narrows the next.

### 1a. Find the install/upgrade clusters

```sql
-- Large counts on one timestamp = a vendor install or upgrade event.
-- Isolated singles = created by hand.
SELECT
    CONVERT(char(16), t.create_date, 120) AS [created_at],
    COUNT(*)                              AS [tables_created]
FROM sys.tables t
WHERE t.is_ms_shipped = 0
GROUP BY CONVERT(char(16), t.create_date, 120)
HAVING COUNT(*) > 0
ORDER BY [created_at];
```

Expect a handful of rows with large counts (the install, then each upgrade), and
a long tail of rows with a count of 1 or 2. **Note the timestamp of the most
recent large cluster** — that is your cutoff for step 1b.

### 1b. Candidate list

Substitute the cutoff you chose. Nothing created at or before it is offered.

```sql
DECLARE @VendorCutoff datetime = '2026-01-01 00:00:00';   -- from step 1a

SELECT
    t.name                                   AS [table_name],
    CONVERT(char(19), t.create_date, 120)    AS [created],
    CONVERT(char(19), t.modify_date, 120)    AS [last_modified],
    ISNULL(SUM(p.rows), 0)                   AS [rows],
    CAST(ROUND(SUM(a.total_pages) * 8.0 / 1024, 1) AS decimal(10,1)) AS [mb]
FROM sys.tables t
LEFT JOIN sys.partitions p
       ON p.object_id = t.object_id AND p.index_id IN (0,1)
LEFT JOIN sys.allocation_units a
       ON a.container_id = p.partition_id
WHERE t.is_ms_shipped = 0
  AND t.create_date > @VendorCutoff
GROUP BY t.name, t.create_date, t.modify_date
ORDER BY t.create_date;
```

Review every row. `last_modified` well after `created` means something has been
writing to it — investigate before assuming it is abandoned.

### 1c. Does anything depend on them?

**Run this before dropping anything.** A table referenced by a view, procedure,
or foreign key is not scratch, whatever its name suggests.

```sql
DECLARE @VendorCutoff datetime = '2026-01-01 00:00:00';

-- Views / procedures / functions that reference a candidate
SELECT
    OBJECT_NAME(d.referencing_id) AS [referenced_by],
    o.type_desc                   AS [referencer_type],
    d.referenced_entity_name      AS [candidate_table]
FROM sys.sql_expression_dependencies d
INNER JOIN sys.objects o ON o.object_id = d.referencing_id
INNER JOIN sys.tables  t ON t.name = d.referenced_entity_name
WHERE t.is_ms_shipped = 0
  AND t.create_date > @VendorCutoff
ORDER BY d.referenced_entity_name, [referenced_by];

-- Foreign keys pointing AT a candidate (would block the DROP anyway)
SELECT
    fk.name                            AS [fk_name],
    OBJECT_NAME(fk.parent_object_id)   AS [child_table],
    t.name                             AS [candidate_table]
FROM sys.foreign_keys fk
INNER JOIN sys.tables t ON t.object_id = fk.referenced_object_id
WHERE t.is_ms_shipped = 0
  AND t.create_date > @VendorCutoff
ORDER BY t.name;
```

**Anything appearing here comes off the drop list.** Both queries returning zero
rows is the green light.

### 1e. Vendor-signal check — **1c is not sufficient on its own**

Step 1c only finds tables that something *else* references. A standalone vendor
lookup table — no foreign key pointing at it, no view using it — passes 1c
cleanly and lands on the drop list.

That happened on the first real run of this audit (2026-08-28). Three tables
reached the candidate list and had to be pulled out by hand:

| Table | Why it is vendor |
| --- | --- |
| `item_circ_renewal` | 15 columns of Horizon UDTs; holds one of the database's only 6 declared primary keys; circulation renewal history |
| `bstat_group` | `code + descr + timestamp` shape, one of 19 sibling `*_group` lookups; empty only because the site does not use the feature |
| `sort_order` | `string / equivalence / char_type / char_equivalence` — character-equivalence data for browse indexes |

All three had a `create_date` after the install because something rebuilt them
later. **A rebuilt vendor table is indistinguishable from a local one by date
alone** — this step is what separates them.

```sql
DECLARE @VendorCutoff datetime = '2022-04-11 06:45:59';

SELECT
    t.name                                            AS [table_name],
    (SELECT COUNT(*) FROM sys.columns c
      WHERE c.object_id = t.object_id)                AS [columns],
    CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i
                      WHERE i.object_id = t.object_id AND i.is_primary_key = 1)
         THEN 'YES' ELSE '' END                       AS [declared_pk],
    CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i
                      WHERE i.object_id = t.object_id AND i.is_unique = 1)
         THEN 'yes' ELSE '' END                       AS [unique_index],
    -- Vendor tables are built from Horizon's user-defined types. A scratch
    -- table made by SELECT INTO inherits base types instead.
    (SELECT COUNT(*) FROM sys.columns c
     INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
      WHERE c.object_id = t.object_id AND ty.is_user_defined = 1) AS [udt_columns]
FROM sys.tables t
WHERE t.is_ms_shipped = 0
  AND t.create_date > @VendorCutoff
ORDER BY [udt_columns] DESC, [columns] DESC, t.name;
```

**Read it like this.** A `SELECT INTO` scratch copy is typically 1–3 columns of
base types with no key. Sort the output by `udt_columns` and `columns`
descending: anything with **user-defined-type columns, a declared PK, or more
than a handful of columns is vendor until you prove otherwise.** Only a table
whose own history you recognise should be dropped despite those signals — the
delete lists this repository creates carry a declared PK, for instance, and are
still safe to drop.

### 1d. Generate the DROP script for review

This **produces text, it does not drop anything.** Copy the output into a new
window, delete the lines for anything you want to keep, and that edited script
becomes Step 2.

```sql
DECLARE @VendorCutoff datetime = '2026-01-01 00:00:00';

SELECT
    'IF OBJECT_ID(''dbo.' + t.name + ''',''U'') IS NOT NULL' +
    ' BEGIN DROP TABLE dbo.[' + t.name + ']; PRINT ''dropped ' + t.name + '''; END' +
    ' ELSE PRINT ''' + t.name + ' not present'';'   AS [drop_statement],
    ISNULL(SUM(p.rows), 0)                          AS [rows_it_holds]
FROM sys.tables t
LEFT JOIN sys.partitions p
       ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.is_ms_shipped = 0
  AND t.create_date > @VendorCutoff
  -- Exclude anything step 1c flagged as depended upon:
  AND NOT EXISTS (SELECT 1 FROM sys.sql_expression_dependencies d
                  WHERE d.referenced_entity_name = t.name)
  AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys fk
                  WHERE fk.referenced_object_id = t.object_id)
GROUP BY t.name
ORDER BY t.name;
```

The `rows_it_holds` column is there so a table with unexpected volume catches
your eye before you approve it.

---

## Step 2: The Drop

Two forms. Both require that a human has read the 1d output first.

### 2a. Count-gated (use this when you approved the whole 1d list)

Re-derives **exactly** the 1d predicate, then **refuses to run unless the count
matches the number you reviewed**. That mismatch check is the entire safety
mechanism: if someone created a table since your review, or you mistyped the
cutoff, the set differs and nothing is dropped.

Set `@ExpectedCount` to the number of rows 1d returned. Set `@VendorCutoff` to
the same value you used there — a different cutoff silently selects a different
set, which is exactly what the count guard catches.

```sql
SET NOCOUNT ON;
SET LOCK_TIMEOUT 10000;      -- fail fast on a lock rather than hanging

DECLARE @VendorCutoff datetime = '2022-04-11 06:45:59';   -- same as step 1
DECLARE @ExpectedCount int    = 0;                        -- rows you approved

IF OBJECT_ID('tempdb..#drop_list') IS NOT NULL DROP TABLE #drop_list;

-- Identical predicate to 1d. If you change one, change both.
SELECT t.name
INTO #drop_list
FROM sys.tables t
WHERE t.is_ms_shipped = 0
  AND t.create_date > @VendorCutoff
  AND NOT EXISTS (SELECT 1 FROM sys.sql_expression_dependencies d
                  WHERE d.referenced_entity_name = t.name)
  AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys fk
                  WHERE fk.referenced_object_id = t.object_id)
  -- Vendor tables rebuilt after install, so their create_date looks local.
  -- Identified by step 1e; see the table there for the evidence.
  AND t.name NOT IN ('item_circ_renewal', 'bstat_group', 'sort_order');

DECLARE @actual int = (SELECT COUNT(*) FROM #drop_list);
PRINT 'candidates now: ' + CAST(@actual AS varchar(10))
    + '   approved: '    + CAST(@ExpectedCount AS varchar(10));

IF @actual <> @ExpectedCount
BEGIN
    RAISERROR('ABORTED: the candidate set changed since you reviewed it. Re-run the audit.', 16, 1);
    RETURN;
END

DECLARE @name sysname, @sql nvarchar(400), @ok int = 0, @failed int = 0;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM #drop_list ORDER BY name;
OPEN c;
FETCH NEXT FROM c INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- QUOTENAME, not concatenation: the name comes from a catalog view, but
    -- building dynamic SQL from an unquoted identifier is never acceptable.
    SET @sql = N'DROP TABLE dbo.' + QUOTENAME(@name) + N';';
    BEGIN TRY
        EXEC sp_executesql @sql;
        SET @ok = @ok + 1;
        PRINT '  dropped  ' + @name;
    END TRY
    BEGIN CATCH
        -- Per-table, so one locked table does not abandon the rest.
        SET @failed = @failed + 1;
        PRINT '  FAILED   ' + @name + '  -> ' + ERROR_MESSAGE();
    END CATCH
    FETCH NEXT FROM c INTO @name;
END
CLOSE c;
DEALLOCATE c;

PRINT '';
PRINT 'dropped ' + CAST(@ok AS varchar(10))
    + ', failed ' + CAST(@failed AS varchar(10));

SET LOCK_TIMEOUT -1;   -- session-scoped; reset or later queries inherit 10s
```

Each `DROP` is wrapped in its own `TRY`/`CATCH`, so a table held by an orphaned
session is reported and skipped rather than aborting the batch and leaving the
rest undone.

### 2b. Explicit list (use this when you removed rows from the 1d output)

If you kept only some of the candidates, paste the edited statements instead —
the count gate above would abort, correctly, because your list no longer matches
the predicate.

```sql
SET LOCK_TIMEOUT 10000;

-- <<< PASTE YOUR EDITED DROP STATEMENTS FROM 1d HERE >>>
-- IF OBJECT_ID('dbo.SomeScratchTable','U') IS NOT NULL
--   BEGIN DROP TABLE dbo.[SomeScratchTable]; PRINT 'dropped SomeScratchTable'; END
-- ELSE PRINT 'SomeScratchTable not present';

SET LOCK_TIMEOUT -1;
```

`SET LOCK_TIMEOUT` matters both ways here. Without it a `DROP` blocked by an
orphaned session hangs with no explanation. Without the reset, **every
subsequent query on that connection** inherits the 10-second limit — the same
session-scoped leak documented in `docs/killbib.md`.

### If a DROP reports "Lock request time out period exceeded"

That table is held by another session. It is not a failure of the script — skip
it and retry later, or have a sysadmin `KILL` the holder. An ordinary login
cannot enumerate sessions: `sys.dm_exec_sessions` silently returns only its own
row rather than erroring, which reads like "nothing is holding it".

### Verify

```sql
DECLARE @VendorCutoff datetime = '2026-01-01 00:00:00';

SELECT COUNT(*) AS [candidates_remaining]
FROM sys.tables
WHERE is_ms_shipped = 0 AND create_date > @VendorCutoff;
```

---

## Step 3: Re-export the schema

The committed schema export is now out of date — it still lists the dropped
tables. Refresh it so the reference matches the database:

1. Re-run the four export queries in
   [`docs/schema/README.md`](../../docs/schema/README.md) and overwrite the CSVs
   in `horizon-schema/`.
2. Regenerate the derived pages:

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\Generate-SchemaDocs.ps1
   ```

3. Confirm the object count fell by what you dropped:

   ```powershell
   Select-String -Path "docs\schema\index\all-objects.md" -Pattern '^\*\*\d+ objects'
   ```

4. Re-run the tooling tests, then commit the refreshed export with the
   generated pages:

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\Test-Tools.ps1
   ```

**A stale export is worse than no export**, because `AGENTS.md` tells people to
trust it: "if grep finds nothing, the object does not exist". Do not leave step 3
undone.

---

## Notes and edge cases

- **`create_date` here is a real `datetime`**, not a Horizon integer day count.
  `sys.tables` is a SQL Server catalog view and follows SQL Server conventions —
  the `smallint` day-count rule in
  [`conventions.md`](../../docs/schema/conventions.md#dates) applies to Horizon's
  own tables, not to system metadata.
- **A rebuilt or altered table gets a new `create_date`.** Some operations
  recreate a table under the covers, which can make a vendor table look local.
  That is why step 1c exists — a vendor table almost always has something
  depending on it.
- **Views are out of scope.** This audit covers `sys.tables` only. Scratch views
  are rarer and are better judged individually.
- **Empty is not the same as unused.** A table with 0 rows may be a working area
  that Horizon truncates between runs. Weigh `last_modified` and step 1c, not
  the row count alone.
- **Delete lists from past batch removals** are safe to drop once their run is
  verified complete — the audit record is the CSV in `killbib-audit\`, not the
  table.
