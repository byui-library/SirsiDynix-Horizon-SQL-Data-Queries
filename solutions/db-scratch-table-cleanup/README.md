# Scratch and backup table cleanup

## The Problem

Years of ad-hoc work leave tables behind: scratch copies, pre-change backups,
one-off working sets, delete lists from past batch removals. This database held
969 user tables before the first run of this audit and 928 after — 42 were
accumulated scratch.

They cost little space but are actively harmful in two ways:

1. **They look authoritative.** A query written against a stale `*_bak` table
   returns plausible, wrong answers. `docs/schema/AGENTS.md` has a rule about
   this because it is a live hazard, not a theoretical one.
2. **They pollute the schema reference.** Every one appears in
   `horizon-schema/` and the generated index pages, so anyone browsing for a
   real table wades through scratch.

### Why you cannot do this by name

**There is no safe name pattern.** `tmp`, `del`, `temp` and `bak` prefixes
appear on tables Horizon itself ships — the vendor uses them for its own working
storage, and the application recreates and depends on some. Dropping one breaks
the ILS in a way that will not surface until whichever module uses it next runs.

### The discriminator: creation date, then structure

`sys.tables.create_date` records when each object was created. Tables that
arrived with an install or upgrade share that event's timestamp, clustered
tightly — hundreds within the same minute. A locally-created scratch table has
an isolated timestamp on an ordinary working day. Step 1a shows you those
clusters so **you** choose the cutoff.

Date alone is not enough. **A vendor table that was later rebuilt gets a new
`create_date` and looks local.** On the first real run (2026-08-28) three such
tables reached the candidate list and had to be pulled out by hand:

| Table | Why it is vendor |
| --- | --- |
| `item_circ_renewal` | 15 columns of Horizon UDTs; holds one of the database's only 6 declared primary keys; circulation renewal history |
| `bstat_group` | `code + descr + timestamp` shape, one of 19 sibling `*_group` lookups; empty only because the site does not use the feature |
| `sort_order` | `string / equivalence / char_type / char_equivalence` — character-equivalence data for browse indexes |

None was caught by the dependency check, because **a standalone lookup table has
nothing referencing it**. Step 1b therefore reports structural signals beside
each candidate so the evidence sits on the same line as the decision.

### A backup is required before Step 2

`DROP TABLE` is not recoverable. Take a **full database backup** — not just
`bib` and `item` — because this touches objects outside the catalog tables.

### About `@VendorCutoff`

Every block below declares it independently, because each generated `.sql` file
must run on its own. **Set the same value in all of them.**

The shipped default is `'2099-01-01'`, which deliberately matches **nothing** —
an unedited run returns zero candidates rather than selecting the whole
database. Replace it with the value from step 1a.

---

## Step 1: The Audit

Five parts, in order. Each narrows the next.

### 1a. Find the install/upgrade clusters

```sql
-- Large counts on one timestamp = a vendor install or upgrade event.
-- Isolated singles = created by hand.
-- max_created is the value to paste into @VendorCutoff below: the last moment
-- of the cluster, at the second precision the later steps compare on.
SELECT
    CONVERT(char(16), t.create_date, 120)      AS [cluster],
    COUNT(*)                                   AS [tables_created],
    CONVERT(char(19), MAX(t.create_date), 120) AS [max_created]
FROM sys.tables t
WHERE t.is_ms_shipped = 0
GROUP BY CONVERT(char(16), t.create_date, 120)
ORDER BY [cluster];
```

Expect a few rows with large counts (the install, then each upgrade) and a long
tail of 1s and 2s. **Take `max_created` from the most recent large cluster** —
that is your cutoff. If a later cluster exists, it is an upgrade and everything
before it is vendor.

### 1b. Candidates, with the evidence for judging them

One row per candidate, carrying both the practical facts (age, size) and the
structural signals that separate vendor from scratch.

```sql
DECLARE @VendorCutoff datetime = '2099-01-01 00:00:00';   -- from 1a

SELECT
    t.name                                   AS [table_name],
    CONVERT(char(19), t.create_date, 120)    AS [created],
    CONVERT(char(19), t.modify_date, 120)    AS [last_modified],
    ISNULL(SUM(p.rows), 0)                   AS [rows],
    (SELECT COUNT(*) FROM sys.columns c
      WHERE c.object_id = t.object_id)       AS [columns],
    -- Vendor tables are built from Horizon's user-defined types. A scratch
    -- copy made by SELECT INTO inherits base types instead.
    (SELECT COUNT(*) FROM sys.columns c
     INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
      WHERE c.object_id = t.object_id AND ty.is_user_defined = 1) AS [udt_cols],
    CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i
                      WHERE i.object_id = t.object_id AND i.is_primary_key = 1)
         THEN 'YES' ELSE '' END              AS [declared_pk],
    CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i
                      WHERE i.object_id = t.object_id AND i.is_unique = 1)
         THEN 'yes' ELSE '' END              AS [unique_idx]
FROM sys.tables t
LEFT JOIN sys.partitions p
       ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.is_ms_shipped = 0
  AND t.create_date > @VendorCutoff
GROUP BY t.name, t.object_id, t.create_date, t.modify_date
ORDER BY [udt_cols] DESC, [columns] DESC, t.name;
```

**How to read it.** Sorted so the most suspicious rows come first. A `SELECT
INTO` scratch copy is typically 1–3 columns of base types, no key, `udt_cols` of
0. **Anything with user-defined-type columns, a declared PK, or more than a
handful of columns is vendor until you prove otherwise.**

The exception that proves the rule: this repository's own delete lists carry a
declared PK and are still safe to drop. Structure is evidence, not a verdict —
only a table whose history you recognise should be dropped despite these signals.

`last_modified` well after `created` means something has been writing to it.

### 1c. Does anything depend on them?

A table referenced by a view, procedure, or foreign key is not scratch, whatever
its name suggests. **This check is necessary but not sufficient** — see 1b.

```sql
DECLARE @VendorCutoff datetime = '2099-01-01 00:00:00';   -- from 1a

-- Views / procedures / functions referencing a candidate
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

-- Foreign keys pointing AT a candidate (these would block the DROP anyway)
SELECT
    fk.name                          AS [fk_name],
    OBJECT_NAME(fk.parent_object_id) AS [child_table],
    t.name                           AS [candidate_table]
FROM sys.foreign_keys fk
INNER JOIN sys.tables t ON t.object_id = fk.referenced_object_id
WHERE t.is_ms_shipped = 0
  AND t.create_date > @VendorCutoff
ORDER BY t.name;
```

Anything appearing here comes off the drop list — 1d excludes it automatically.

### 1d. Generate the DROP script for review

**This produces text; it drops nothing.** Its predicate is the one Step 2a
re-derives, character for character.

Add any table you decided to keep in 1b to `@Keep`. The three below are this
site's known vendor rebuilds; adjust for yours.

```sql
DECLARE @VendorCutoff datetime = '2099-01-01 00:00:00';   -- from 1a

-- Tables to keep despite matching the predicate. Reason travels with the name.
DECLARE @Keep TABLE (name sysname PRIMARY KEY, reason nvarchar(200));
INSERT INTO @Keep VALUES
 ('item_circ_renewal', 'Horizon: circ renewal history, declared PK, 15 UDT cols'),
 ('bstat_group',       'Horizon: lookup, one of 19 sibling *_group tables'),
 ('sort_order',        'Horizon: character-equivalence data for browse indexes');

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
  AND NOT EXISTS (SELECT 1 FROM sys.sql_expression_dependencies d
                  WHERE d.referenced_entity_name = t.name)
  AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys fk
                  WHERE fk.referenced_object_id = t.object_id)
  AND NOT EXISTS (SELECT 1 FROM @Keep k WHERE k.name = t.name)
GROUP BY t.name
ORDER BY t.name;
```

**Record the row count.** That number is what Step 2a gates on.

`rows_it_holds` is there so a table with unexpected volume catches your eye
before you approve it.

---

## Step 2: The Drop

Two forms. Both require that a human has read the 1d output first.

### 2a. Count-gated — when you approved the whole 1d list

Re-derives 1d's predicate exactly, then **refuses to run unless the count matches
what you reviewed**. That mismatch check is the entire safety mechanism: if
someone created a table since your review, or you mistyped the cutoff, the set
differs and nothing is dropped.

```sql
SET NOCOUNT ON;
SET LOCK_TIMEOUT 10000;      -- fail fast on a lock rather than hanging

DECLARE @VendorCutoff datetime = '2099-01-01 00:00:00';   -- same value as 1d
DECLARE @ExpectedCount int    = 0;                        -- rows 1d returned

DECLARE @Keep TABLE (name sysname PRIMARY KEY, reason nvarchar(200));
INSERT INTO @Keep VALUES
 ('item_circ_renewal', 'Horizon: circ renewal history, declared PK, 15 UDT cols'),
 ('bstat_group',       'Horizon: lookup, one of 19 sibling *_group tables'),
 ('sort_order',        'Horizon: character-equivalence data for browse indexes');

IF OBJECT_ID('tempdb..#drop_list') IS NOT NULL DROP TABLE #drop_list;

-- Character-identical to 1d's WHERE clause. If you change one, change both.
SELECT t.name
INTO #drop_list
FROM sys.tables t
WHERE t.is_ms_shipped = 0
  AND t.create_date > @VendorCutoff
  AND NOT EXISTS (SELECT 1 FROM sys.sql_expression_dependencies d
                  WHERE d.referenced_entity_name = t.name)
  AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys fk
                  WHERE fk.referenced_object_id = t.object_id)
  AND NOT EXISTS (SELECT 1 FROM @Keep k WHERE k.name = t.name);

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

### 2b. Explicit list — when you kept only some of the 1d output

The count gate above would abort, correctly, because your list no longer matches
the predicate. Paste the edited statements instead.

```sql
SET LOCK_TIMEOUT 10000;

-- <<< PASTE YOUR EDITED DROP STATEMENTS FROM 1d HERE >>>
-- IF OBJECT_ID('dbo.SomeScratchTable','U') IS NOT NULL
--   BEGIN DROP TABLE dbo.[SomeScratchTable]; PRINT 'dropped SomeScratchTable'; END
-- ELSE PRINT 'SomeScratchTable not present';

SET LOCK_TIMEOUT -1;
```

### If a DROP reports "Lock request time out period exceeded"

That table is held by another session — not a failure of the script. Skip it and
retry later, or have a sysadmin `KILL` the holder. An ordinary login cannot
enumerate sessions: `sys.dm_exec_sessions` silently returns only its own row
rather than erroring, which reads like "nothing is holding it". Background on the
session-scoped `LOCK_TIMEOUT` behaviour is in
[`docs/killbib.md`](../../docs/killbib.md).

### Verify

**Re-run 1d. It should return zero rows.** Anything still listed either failed
to drop (check the `FAILED` lines) or was created since.

---

## Step 3: Re-export the schema

The committed export now disagrees with the database — it still lists the
dropped tables. **A stale export is worse than no export**, because
`docs/schema/AGENTS.md` tells people to trust it: *"if grep finds nothing, the
object does not exist."*

1. Re-run the four export queries in
   [`docs/schema/README.md`](../../docs/schema/README.md) and overwrite the CSVs
   in `horizon-schema/`.
2. Regenerate the derived pages:

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\Generate-SchemaDocs.ps1
   ```

3. **Update the counts stated in prose.** The generator refreshes
   `docs/schema/index/`, but several documents restate those figures by hand.
   Find every stale one:

   ```powershell
   Select-String -Path *.md, docs\*.md, docs\schema\*.md, horizon-schema\*.md `
       -Pattern '\d[\d,]* (tables|views|columns|objects)\b|captured 20\d\d-\d\d-\d\d'
   ```

   Reconcile each against `docs/schema/index/all-objects.md` and
   `docs/schema/index/date-columns.md`, and update the capture date.

4. Re-run the tooling tests, then commit the refreshed export together with the
   regenerated pages:

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\Test-Tools.ps1
   ```

---

## Notes and edge cases

- **`create_date` here is a real `datetime`**, not a Horizon integer day count.
  `sys.tables` is a SQL Server catalog view and follows SQL Server conventions —
  the `smallint` day-count rule in
  [`conventions.md`](../../docs/schema/conventions.md#dates) applies to Horizon's
  own tables, not to system metadata.
- **Views are out of scope.** This audit covers `sys.tables` only. Scratch views
  are rarer and better judged individually.
- **Empty is not the same as unused.** A table with 0 rows may be a working area
  Horizon truncates between runs, or a vendor lookup for a feature the site does
  not use — `bstat_group` was exactly that. Weigh 1b's structural signals, not
  the row count.
- **Delete lists from past batch removals** are safe to drop once their run is
  verified complete. The audit record is the CSV in `killbib-audit\`, not the
  table.
- **`sys.partitions` can inflate `rows`** for a table with multiple allocation
  units. Treat the figure as an order of magnitude, not an exact count.
