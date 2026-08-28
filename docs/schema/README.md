# Horizon schema reference

Verified schema for this SirsiDynix Horizon database on SQL Server —
**928 tables, 433 views, 13,949 columns**, refreshed 2026-08-28.

**Read this before writing any query.** Never infer a table or column name from
convention; every name used in this repo must be looked up here or in the raw
exports. See the "Never guess a column or table name" rule in the top-level
`CLAUDE.md`.

## Start here

| If you want to… | Go to |
| --- | --- |
| Write a query (rules, lookup recipes, checklist) | **[AGENTS.md](AGENTS.md)** |
| Understand a schema-wide pattern (dates, types, keys) | [conventions.md](conventions.md) |
| Learn a specific core table | [core/](core/) |
| See what objects exist and their grain | [index/all-objects.md](index/all-objects.md) |
| Find the exact columns of any object | grep the CSVs (recipes in [AGENTS.md](AGENTS.md#rule-2--look-it-up-like-this)) |

`AGENTS.md` is tool-neutral: it applies to Claude Code, Copilot, Cursor, Codex,
Gemini, and to people.

## Layout

```
horizon-schema/              raw CSV exports — the source of truth
  all_tables_all_views.csv     13,949 columns
  indexes_and_keys.csv         1,868 index entries
  foreign_keys.csv             166 FK columns
docs/schema/
  README.md                  this page
  AGENTS.md                  rules for writing queries  ← the important one
  conventions.md             schema-wide patterns explained
  core/                      hand-written, per table
  index/                     GENERATED — do not hand-edit
tools/Generate-SchemaDocs.ps1  rebuilds index/ from the CSVs
```

**Markdown is for orientation; the CSVs are for lookup.** Don't read a
14,000-row CSV to find your bearings, and don't trust a summary page for an
exact column name.

## Documented tables

| Page | Grain |
| --- | --- |
| [core/bib.md](core/bib.md) | `bib#, tag, tagord` — MARC content |
| [core/bib_control.md](core/bib_control.md) | `bib#` — creation/change metadata |
| [core/title.md](core/title.md) | `bib#` — normalised title |
| [core/item.md](core/item.md) | `item#` — physical copies |
| [core/collection.md](core/collection.md) | `collection` — collection codes |
| [core/location.md](core/location.md) | `location` — branch/shelving codes |
| [core/borrower.md](core/borrower.md) | `borrower#` — patrons ⚠ personal data |
| [core/circ.md](core/circ.md) | `borrower#, item#` — current checkouts |
| [core/acquisitions.md](core/acquisitions.md) | `po`, `po_line`, `vendor`, `invoice` |

Anything not listed: check [index/all-objects.md](index/all-objects.md) for its
grain, then grep the CSV for its columns. If its role is unclear, ask rather than
assume — some tables are local scratch copies, not Horizon's.

## Generated pages

Rebuilt by `tools/Generate-SchemaDocs.ps1`; **never hand-edit them**.

| Page | Contents |
| --- | --- |
| [index/all-objects.md](index/all-objects.md) | All 1,361 objects: type, column count, grain |
| [index/joins.md](index/joins.md) | The 139 declared foreign keys (166 columns) |
| [index/no-unique-index.md](index/no-unique-index.md) | Objects with no unique index — fan-out risks |
| [index/date-columns.md](index/date-columns.md) | All 951 integer date columns |

---

## Refreshing the exports

Run the queries below and overwrite the CSVs in `horizon-schema/`, then:

```powershell
powershell -ExecutionPolicy Bypass -File tools\Generate-SchemaDocs.ps1
```

Save from SSMS with **Results to Grid** → right-click → **Save Results As…** →
CSV. The generator expects **no header row** and the exact column order produced
by these queries; if you change a query, update the matching `-Header` list in
the script.

### Engine compatibility
These use **only pre-2012 T-SQL** — `sys` catalog views, `CASE`, `TYPE_NAME()`.
No `STRING_AGG`, `CONCAT`, `IIF`, or `FORMAT`, because this database's
compatibility level is low enough that `STRING_AGG` fails outright. The `sys`
views themselves are SQL Server 2005+ and unaffected by compatibility level.

Needs `VIEW DEFINITION`; Query 4 also needs `VIEW DATABASE STATE`.

### Query 1 → `all_tables_all_views.csv`

```sql
SELECT
    SCHEMA_NAME(o.schema_id)  AS [schema],
    o.name                    AS [object],
    CASE o.type WHEN 'U' THEN 'TABLE'
                WHEN 'V' THEN 'VIEW'
                ELSE o.type END           AS [object_type],
    c.column_id               AS [ord],
    c.name                    AS [column],
    t.name                    AS [declared_type],
    TYPE_NAME(c.system_type_id) AS [base_type],
    c.max_length              AS [len_bytes],
    c.precision               AS [prec],
    c.scale                   AS [scale],
    CASE WHEN c.is_nullable = 1 THEN 'yes' ELSE 'no' END AS [nullable],
    CASE WHEN c.is_identity = 1 THEN 'yes' ELSE '' END   AS [is_identity],
    CASE WHEN c.is_computed = 1 THEN 'yes' ELSE '' END   AS [is_computed],
    c.collation_name          AS [collation],
    CASE WHEN pk.column_id IS NOT NULL THEN 'PK' ELSE '' END AS [pk],
    pk.key_ordinal            AS [pk_ord],
    dc.definition             AS [default_definition]
FROM sys.objects o
INNER JOIN sys.columns c ON c.object_id = o.object_id
INNER JOIN sys.types t   ON t.user_type_id = c.user_type_id   -- keeps UDT names
LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
LEFT JOIN (
        SELECT ic.object_id, ic.column_id, ic.key_ordinal
        FROM sys.indexes i
        INNER JOIN sys.index_columns ic
                ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        WHERE i.is_primary_key = 1
) pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
WHERE o.type IN ('U','V') AND o.is_ms_shipped = 0
ORDER BY [schema], [object], c.column_id;
```

### Query 2 → `indexes_and_keys.csv`

The most important export after Query 1: with only 6 declared primary keys in the
database, **unique indexes are the only statement of a table's grain**.

```sql
SELECT
    SCHEMA_NAME(o.schema_id)  AS [schema],
    o.name                    AS [object],
    i.name                    AS [index_name],
    i.type_desc               AS [index_type],
    CASE WHEN i.is_primary_key = 1 THEN 'yes' ELSE '' END AS [is_pk],
    CASE WHEN i.is_unique = 1 THEN 'yes' ELSE '' END      AS [is_unique],
    ic.key_ordinal            AS [key_ord],
    c.name                    AS [column],
    CASE WHEN ic.is_descending_key = 1 THEN 'DESC' ELSE 'ASC' END AS [direction],
    CASE WHEN ic.is_included_column = 1 THEN 'INCLUDED' ELSE 'KEY' END AS [part]
FROM sys.indexes i
INNER JOIN sys.objects o ON o.object_id = i.object_id
INNER JOIN sys.index_columns ic
        ON ic.object_id = i.object_id AND ic.index_id = i.index_id
INNER JOIN sys.columns c
        ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE o.type = 'U' AND o.is_ms_shipped = 0 AND i.type > 0
ORDER BY [schema], [object], i.name, ic.is_included_column, ic.key_ordinal;
```

### Query 3 → `foreign_keys.csv`

```sql
SELECT
    fk.name                       AS [fk_name],
    SCHEMA_NAME(pt.schema_id)     AS [parent_schema],
    pt.name                       AS [parent_table],
    pc.name                       AS [parent_column],
    SCHEMA_NAME(rt.schema_id)     AS [referenced_schema],
    rt.name                       AS [referenced_table],
    rc.name                       AS [referenced_column],
    fkc.constraint_column_id      AS [col_ord],
    fk.delete_referential_action_desc AS [on_delete],
    fk.update_referential_action_desc AS [on_update],
    CASE WHEN fk.is_disabled = 1 THEN 'DISABLED' ELSE '' END AS [disabled]
FROM sys.foreign_keys fk
INNER JOIN sys.foreign_key_columns fkc
        ON fkc.constraint_object_id = fk.object_id
INNER JOIN sys.objects pt ON pt.object_id = fk.parent_object_id
INNER JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id
                         AND pc.column_id = fkc.parent_column_id
INNER JOIN sys.objects rt ON rt.object_id = fk.referenced_object_id
INNER JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id
                         AND rc.column_id = fkc.referenced_column_id
ORDER BY [parent_table], [fk_name], [col_ord];
```

### Query 4 → `table_origin_and_rowcounts.csv`

Separates Horizon-native tables from local scratch/backup tables, and shows which
are populated. Tables sharing the install `create_date` are Horizon's; later ones
are local additions.

```sql
SELECT
    o.name            AS [table],
    o.create_date     AS [created],
    o.modify_date     AS [last_modified],
    SUM(ps.row_count) AS [rows]
FROM sys.objects o
INNER JOIN sys.dm_db_partition_stats ps ON ps.object_id = o.object_id
WHERE o.type = 'U' AND o.is_ms_shipped = 0
  AND ps.index_id IN (0,1)              -- heap or clustered only, no double-count
GROUP BY o.name, o.create_date, o.modify_date
ORDER BY o.create_date, o.name;
```

Reads stored metadata rather than scanning, so it returns instantly.

---

## Why the CSVs are committed

`.gitignore` blocks `*.csv` to keep catalog and patron data out of a public repo.
These exports are **metadata** — object names, types, collations, index and FK
definitions — with no catalog records, no patron data, and no credentials, so
that reason does not apply. A narrow `!horizon-schema/*.csv` exception keeps them
tracked while the blanket rule stands.

**Query output from `borrower`, `circ`, or any patron table remains covered by
the blanket rule. Never add an exception for it.**
