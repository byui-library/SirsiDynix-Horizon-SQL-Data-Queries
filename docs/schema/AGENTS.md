# Writing SQL against this Horizon database — agent instructions

Tool-neutral instructions for any AI assistant (Claude Code, Copilot, Cursor,
Codex, Gemini) or any person writing a query for this repository. `CLAUDE.md` at
the repo root points here; this file is the single source of truth for schema
rules.

The database is **SirsiDynix Horizon** on SQL Server: 969 tables, 433 views,
14,103 columns. Its schema is old, irregular, and actively misleading in places.
The rules below exist because each one has already cost somebody a wrong answer.

---

## Rule 1 — Never guess a name

**Look up every table and column before you use it.** Do not infer a name from
Horizon convention, from another site's schema, from a similar column elsewhere
in this database, or from what the name "should" be.

This was learned the expensive way: a report was written against
`bib_control.creator`. The real column is **`create_user`**. The query was
plausible, readable, and wrong.

These scripts run against a live production ILS and are handed to a DBA to
execute. A wrong name either errors in front of that DBA or — much worse —
silently returns a different row set than intended. This repo's entire safety
model rests on the audit `SELECT` provably matching the `UPDATE`; a guessed name
breaks that guarantee invisibly.

If a lookup does not answer the question, **ask the user**. They can run
`sp_help <table>` and paste the result. Asking costs one message. Guessing costs
credibility and possibly data.

## Rule 2 — Look it up like this

The authoritative source is the CSV exports in [`horizon-schema/`](../../horizon-schema/).
They have **no header row**; field order is fixed and documented in
[README.md](README.md).

`all_tables_all_views.csv` fields, in order:

```
1 schema   2 object   3 object_type   4 ord      5 column    6 declared_type
7 base_type   8 len_bytes   9 prec    10 scale   11 nullable 12 is_identity
13 is_computed   14 collation   15 pk   16 pk_ord   17 default_definition
```

**Every column of one table** — the most common lookup:

```bash
grep -E '^dbo,bib_control,' "horizon-schema/all_tables_all_views.csv"
```

```powershell
Import-Csv "horizon-schema\all_tables_all_views.csv" -Header schema,object,object_type,ord,column,declared_type,base_type,len_bytes,prec,scale,nullable,is_identity,is_computed,collation,pk,pk_ord,default_definition |
  Where-Object { $_.object -eq 'bib_control' } |
  Format-Table ord, column, declared_type, base_type, nullable, collation
```

**Which tables contain a given column** — for finding join partners:

```bash
awk -F, '$5=="ibarcode" {print $2}' "horizon-schema/all_tables_all_views.csv"
```

**Does this table/column exist at all?** If `grep` returns nothing, the answer is
no. Do not proceed on the assumption that the export is incomplete — it covers
every table and view in the database.

Markdown pages under [`index/`](index/) are for **orientation** (what exists,
what its grain is). The CSVs are for **lookup** (exact names and types). Use the
right one for the question; do not read a 14,000-row CSV to get oriented, and do
not trust a summary page for an exact column name.

## Rule 3 — Establish grain before writing a join

**Grain** = the column set that is provably one row. It is the single most
important fact about a table here, because getting it wrong silently multiplies
your result set.

Look up both sides in [`index/all-objects.md`](index/all-objects.md) before
joining. Worked example — the classic trap this repo was built around:

| Object | Grain | Meaning |
| --- | --- | --- |
| `bib` | `bib#, tag, tagord` | one row **per MARC tag occurrence** |
| `item` | `item#` | one row **per physical copy** |
| `bib_control` | `bib#` | one row per record |
| `title` | `bib#` | one row per record |

A bib with 2 `590` tags and 3 items produces **6 rows** from a naive
`bib JOIN item`. Neither table is "wrong" — they are simply both children of
`bib#` with no key linking a specific tag row to a specific item row.

**Joining `bib_control` to `bib` is safe in one direction only.** `bib_control`
is one row per `bib#`, so it never multiplies. But `bib` fans out per tag, so
`bib_control JOIN bib` still yields one row per tag. Collapse it:

```sql
-- WRONG: one row per matching 590; a record with two ProQuest notes appears twice
SELECT bc.[bib#] FROM bib_control bc
JOIN bib b ON b.[bib#] = bc.[bib#] AND b.tag = '590'
WHERE b.text LIKE '%ProQuest%';

-- RIGHT: EXISTS collapses the tag side to a boolean — one row per bib, always
SELECT bc.[bib#] FROM bib_control bc
WHERE EXISTS (SELECT 1 FROM bib b
              WHERE b.[bib#] = bc.[bib#] AND b.tag = '590'
                AND b.text LIKE '%ProQuest%');
```

Use `EXISTS` to **test** a child condition, `DISTINCT`/aggregation to **collapse**
one, and a plain join only when you genuinely want the fan-out (a detail report,
one row per tag).

**You cannot aggregate an `EXISTS` directly.** This is the most common way the
idiom above breaks — SQL Server rejects a subquery inside an aggregate:

```sql
-- FAILS: Msg 130 — "Cannot perform an aggregate function on an expression
--        containing an aggregate or a subquery."
SELECT COUNT(*) AS total,
       SUM(CASE WHEN EXISTS (SELECT 1 FROM bib p WHERE p.[bib#] = bc.[bib#]
                               AND p.tag = '590' AND p.text LIKE '%ProQuest%')
                THEN 1 ELSE 0 END) AS matching
FROM bib_control bc WHERE bc.create_user = 'CATALOGER';
```

Compute the flag in a derived table (or CTE), then aggregate the flag:

```sql
-- WORKS
SELECT COUNT(*) AS total, SUM(d.is_match) AS matching
FROM (
    SELECT CASE WHEN EXISTS (SELECT 1 FROM bib p WHERE p.[bib#] = bc.[bib#]
                               AND p.tag = '590' AND p.text LIKE '%ProQuest%')
                THEN 1 ELSE 0 END AS is_match
    FROM bib_control bc WHERE bc.create_user = 'CATALOGER'
) d;
```

This comes up constantly when counting "how many records match" alongside "how
many exist" — exactly the shape of a report's summary line.

`(none)` in the grain column means **no unique index exists** — nothing
constrains that object to one row per key. Treat every join to it as a fan-out
risk. See [`index/no-unique-index.md`](index/no-unique-index.md).

## Rule 4 — Do not trust the `PK_` prefix

The database contains **6 declared primary keys in total** — on `circ`,
`item_circ_renewal`, and a table this repo created. That is all.

Hundreds of indexes are *named* `PK_location`, `PK_BIB_STATUS`,
`PKborrower_barcode`. **Every one of them has `is_primary_key = no`.** They are
unique indexes wearing a primary-key-shaped name.

Consequence: **grain in this database comes from unique indexes, not primary
keys.** A query that looks for declared PKs to find join keys will find almost
nothing and conclude, wrongly, that the tables are unkeyed. The generated
`index/` pages already resolve grain from unique indexes — use them.

## Rule 5 — Dates are integers, not dates

**951 `smallint` date columns across 295 tables** — the most pervasive convention
in the schema. A Horizon date column holds a **day count**, not a SQL `date`.
Time of day, when kept, lives in a **separate paired `_time` column**
(`create_date` / `create_time`). Full list:
[`index/date-columns.md`](index/date-columns.md).

```sql
-- RIGHT: exact, index-friendly, self-documenting
WHERE bc.create_date = DATEDIFF(day, '1970-01-01', '2026-08-25')

-- RIGHT: a range. BETWEEN is safe here precisely because there is no time part.
WHERE bc.create_date BETWEEN DATEDIFF(day, '1970-01-01', '2026-08-25')
                         AND DATEDIFF(day, '1970-01-01', '2026-08-31')

-- WRONG: it is not a datetime
WHERE bc.create_date >= '2026-08-25'
-- WRONG: cannot cast an integer day count to a date
WHERE CAST(bc.create_date AS DATE) = '2026-08-25'
```

Write `DATEDIFF(day, '1970-01-01', '<date>')` rather than the bare day number:
the intent stays readable and the date changes in one place. To display one, use
`DATEADD(day, <col>, CAST('1970-01-01' AS DATE))`.

Because the type is `smallint` (max 32,767), the encoding runs out in 2059.

> **Epoch: `1970-01-01`, verified 2026-08-27** against the live database — a
> daily histogram put every weekend at zero and every populated day on a weekday,
> ruling out the ±1 error that a `MAX(create_date)` check cannot detect. Evidence
> in [conventions.md](conventions.md#epoch--verified-as-1970-01-01-2026-08-27).
> Re-verify after a restore or on a different Horizon database.

## Rule 6 — Read the type, not just the name

Horizon leans heavily on user-defined types. The export gives both the declared
type and its base type; you need both.

| Declared | Base | Read it as |
| --- | --- | --- |
| `name_string` | `varchar(30)` | operator logins, user names |
| `code_type` | `varchar(7)` | a code that joins to a lookup table |
| `tag_type` | `varchar(5)` | MARC tag |
| `zero_bit` | `bit` | flag defaulting to 0 |
| `zero_int` | `int` | counter defaulting to 0 |

`code_type` columns are the giveaway for a lookup join: `item.collection`
(`code_type`) joins to `collection.collection`, `item.location` to
`location.location`.

**Collation matters for correctness.** Character columns are
`SQL_Latin1_General_CP850_CI_AS` — **`CI` = case-insensitive**, so `=` and `LIKE`
ignore case. Usually desirable. When you need exact case, say so explicitly with
`COLLATE Latin1_General_CS_AS` — and know why:

> A case-insensitive `%DDA%` also matched the `dDa` sequence formed where a `$d`
> subfield code abuts content beginning `Da…`, producing false positives. Short
> uppercase acronyms need the case-sensitive collation. Long distinctive literals
> like `ProQuest` do not.

## Rule 7 — Know the engine's limits

This database's **compatibility level is low**. Confirmed unavailable:

- `STRING_AGG` — *"'STRING_AGG' is not a recognized built-in function name."*
  At a slightly higher level it exists but rejects `WITHIN GROUP`.
- Assume `CONCAT`, `IIF`, `FORMAT`, and `OFFSET/FETCH` are likewise unavailable
  unless proven otherwise. Prefer `CASE`, `+`, and `TOP`.
- `FOR XML PATH` is the usual pre-2017 substitute for string aggregation, but it
  **fails on `bib.text`**, which embeds `CHAR(31)`/`CHAR(30)` control characters
  that are illegal in XML. It is safe for clean identifiers.

When you need per-record note text, ship a **second detail query** (one row per
tag) rather than aggregating into one cell.

## Rule 8 — MARC text is not plain text

`bib.text` is `varchar(255)` and stores MARC subfields delimited by control
characters, **not** literal pipes:

- `CHAR(31)` = subfield delimiter (`$a` is `CHAR(31)+'a'`)
- `CHAR(30)` = field terminator

Build values as `CHAR(31)+'a'+@value+CHAR(30)`. Use a readable `'|a'+value`
column **only** for display in audit output, never for what gets written.

Because the column is 255 characters, Horizon **splits long fields across
multiple rows**, incrementing `tagord`. A `245` or `520` may be spread over
several rows; reassembling them means ordering by `tagord`. The `245$a` parser
reused across this repo's reports takes the lowest-`tagord` segment only.

To target one of several same-`tag` rows, isolate it by `tagord` (e.g.
`MAX(tagord)` for the later duplicate). `HAVING COUNT(*) = N AND MIN(text) =
MAX(text)` is the established idiom for "N identical tags".

## Rule 9 — Respect the repo's audit/update contract

From `CLAUDE.md`, restated because it interacts with everything above:

- Ship the audit `SELECT` **first**; its row count must be recorded before any
  `UPDATE` runs.
- The `UPDATE`'s `FROM`/`JOIN` clauses must be **identical** to the audit's, so
  the affected rows provably match what was reviewed. Diverging them defeats the
  point.
- State that a table or full-database backup is required, and wrap the `UPDATE`
  in a transaction so the row count can be checked before commit.
- A read-only report has no audit/update split — it uses a single
  **The Report (Read-Only)** section and says no backup or transaction is needed.

## Rule 10 — Some tables are not Horizon's

Alongside Horizon's own tables sit local scratch and backup tables: 51 `tmp*`,
24 `del*`, plus `borrower_bak`, `ipac_databases_bak`, `ITEM_JUV`,
`ITEM_fix_status`, `temp_circ_longterm_history`, and others. They can look
authoritative and hold stale data.

`ITEM_JUV` is not `item`. `borrower_bak` is not `borrower`. Before querying an
unfamiliar table, check [`index/all-objects.md`](index/all-objects.md) and prefer
the documented core tables in [`core/`](core/). If a table's role is unclear,
**ask** rather than assuming it is current.

---

## Before you ship a query — checklist

1. Every table and column name **looked up**, not recalled or inferred.
2. Grain of every joined object checked; fan-out either intended or collapsed
   with `EXISTS`/`DISTINCT`/aggregation.
3. Date predicates use integer day counts, not date literals or casts.
4. Case sensitivity considered — explicit `COLLATE` where exact case matters.
5. No `STRING_AGG`/`CONCAT`/`IIF`/`FORMAT`.
6. For an `UPDATE`: audit `SELECT` shipped first, identical joins, backup and
   transaction stated.
7. Assumptions you could not verify are **stated in the README**, not left
   silent.

## When the schema changes

Re-run the four export queries in [README.md](README.md), overwrite the CSVs in
`horizon-schema/`, then regenerate:

```powershell
powershell -ExecutionPolicy Bypass -File tools\Generate-SchemaDocs.ps1
```

That rewrites everything under `index/`. Hand-written pages (this file,
`conventions.md`, `core/*.md`) are never touched by the generator and need
manual review.
