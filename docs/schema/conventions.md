# Horizon schema conventions

Background reference for the patterns that repeat across the whole database. The
enforceable rules are in [AGENTS.md](AGENTS.md); this page explains *why* they
are what they are, and holds the verification queries.

Everything here is derived from the exports in
[`horizon-schema/`](../../horizon-schema/), captured 2026-08-27.

---

## Dates

### The convention
A Horizon date column is a **`smallint` day count**, not a SQL `date`. Time of
day, where kept at all, is a **separate paired `_time` column**. There are
**951 such date columns across 295 tables** — nearly a third of the database —
and 253 paired time columns.

This is why the pattern matters so much: get the decoding wrong once and every
dated query in the repo is wrong by the same constant, which is the hardest kind
of error to spot. Nothing looks broken; the numbers are just quietly incorrect.

Full inventory: [`index/date-columns.md`](index/date-columns.md).

### Consequences for query writing
- **`=` on a single day is exact and complete.** There is no time component to
  fall outside a range, so no `>= / <` half-open pattern is needed.
- **`BETWEEN` is safe for ranges.** The usual "`BETWEEN` misses the last day's
  afternoon" bug cannot occur, because there is no afternoon in the column.
- **Never cast.** `CAST(create_date AS DATE)` is meaningless on an integer, and
  wrapping a column in a function prevents an index seek regardless.
- **`smallint` caps at 32,767**, so a 1970-anchored encoding runs out in 2059.

### Epoch — VERIFIED as `1970-01-01` (2026-08-27)

`create_date` counts days from **`1970-01-01`**. Confirmed against the live
database; the evidence is recorded below so it does not have to be re-derived.

**How it was proven.** `MAX(create_date)` alone was not enough — it returned
20691 → 2026-08-26, which fits the assumed epoch *and* fits a 1969-12-31 anchor
equally well (last record yesterday, versus last record today). A one-day error
would have been invisible and would have shifted every dated query by a day.

A daily histogram settled it, because weekends are a calendar fingerprint —
cataloging stops on Saturday and Sunday:

| Day number | Decodes to | Weekday | Bibs created |
| ---: | --- | --- | ---: |
| 20679 | 2026-08-14 | Friday | 1 |
| 20680, 20681 | 2026-08-15/16 | **Sat, Sun** | **absent** |
| 20682 | 2026-08-17 | Monday | 20 |
| 20683 | 2026-08-18 | Tuesday | 22 |
| 20685 | 2026-08-20 | Thursday | 13 |
| 20687, 20688 | 2026-08-22/23 | **Sat, Sun** | **absent** |
| 20689 | 2026-08-24 | Monday | 18 |
| 20690 | 2026-08-25 | Tuesday | 6,797 ← ProQuest bulk load |
| 20691 | 2026-08-26 | Wednesday | 22 |

All four weekend days are empty and every populated day is a weekday. Under a
one-day-later anchor the same data would put **two Mondays at zero** and a
Saturday at 1 — a poor fit. The 6,797 on day 20690 is independently corroborated:
it splits as 6,790 (`CATALOGER`) + 7 (`OTHERUSER`), matching a separate per-operator
count for that day.

Reference: `DATEDIFF(day, '1970-01-01', '2026-08-25')` = **20690**.

### Re-verifying after a restore or on another Horizon database

Do not assume this carries over. Use **both** steps — step 1 alone is not proof.

**Step 1 — order-of-magnitude sanity check.**

```sql
SELECT MIN(create_date) AS [min_day],
       DATEADD(day, MIN(create_date), CAST('1970-01-01' AS DATE)) AS [min_decodes_to],
       MAX(create_date) AS [max_day],
       DATEADD(day, MAX(create_date), CAST('1970-01-01' AS DATE)) AS [max_decodes_to]
FROM bib_control;
```

| Result | Meaning |
| --- | --- |
| `max_decodes_to` on or near today | Consistent — but **not yet proof**. Go to step 2. |
| Off by weeks or more | Different anchor. Shift `'1970-01-01'` by the difference. |
| A 1970s or far-future date | Not a day count at all. Stop and re-derive the encoding. |

> This step **cannot detect a one-day error**. "Newest record is yesterday" and
> "newest record is today" are both ordinary, so a ±1 anchor passes it. That is
> precisely the error worth catching: it is invisible and it silently shifts
> every dated query by a day.

**Step 2 — the weekend fingerprint (decisive).**

```sql
SELECT bc.create_date AS [day_number],
       DATEADD(day, bc.create_date, CAST('1970-01-01' AS DATE)) AS [decodes_to],
       DATENAME(weekday,
                DATEADD(day, bc.create_date, CAST('1970-01-01' AS DATE))) AS [weekday],
       COUNT(*) AS [bibs_created]
FROM bib_control bc
WHERE bc.create_date >= DATEDIFF(day, '1970-01-01', '<a date ~2 weeks back>')
GROUP BY bc.create_date
ORDER BY bc.create_date;
```

Cataloging stops at weekends, so Saturdays and Sundays should be absent or
near-zero while weekdays are populated. If activity lands on a weekend, or
Mondays come back empty, the anchor is off — shift it until the quiet days line
up with the weekends. A one-day error is obvious here and invisible in step 1.

Corroborate with a date you independently know, such as when a bulk load ran.

### Time columns
`create_time` and its 252 siblings are `smallint`, but their **encoding is not
verified** — minutes since midnight and an `hhmm` integer are both plausible and
both fit. Do not put a time column in a predicate until it has been checked
against a record whose creation time is independently known.

---

## User-defined types

Horizon declares most columns through UDTs. The export records both the declared
type and the underlying base type; both matter. Declared type tells you the
column's *role*, base type tells you how it *behaves*.

| Declared type | Base type | Uses | Role |
| --- | --- | ---: | --- |
| `code_type` | `varchar(7)` | 1,833 | A short code that joins to a lookup table |
| `zero_bit` | `bit` | 925 | Flag, defaults to 0 |
| `null_string` | `varchar(80)` | 664 | General short text |
| `name_string` | `varchar(30)` | 484 | Operator logins, user and person names |
| `null_string_mlui` | `varchar(255)` | 450 | Longer text, multi-language UI |
| `enum_type` | `tinyint` | 369 | Small enumerated value |
| `zero_int` | `int` | 271 | Counter, defaults to 0 |
| `ord_type` | `tinyint` | 159 | Ordinal within a parent |
| `key#` | `int` | 93 | Surrogate key reference |
| `reconst_type` | `varchar(250)` | 80 | Reconstructed display string |
| `processed_type` | `varchar(250)` | 75 | Normalised/processed text for indexing |
| `zero_money` | `money` | 54 | Currency, defaults to 0 |
| `tag_type` | `varchar(5)` | 30 | MARC tag |
| `tagord_type` | `int` | 22 | Ordinal among repeated tags |

**`code_type` is the strongest signal in the schema.** A `code_type` column
almost always joins to a same-named lookup table: `item.collection` →
`collection.collection`, `item.location` → `location.location`,
`item.itype` → `itype.itype`. That convention is how most of the database's
relationships are expressed, since they are not declared as foreign keys.

---

## Keys, grain, and the `PK_` trap

### Only 6 declared primary keys exist
Across 969 tables, exactly **6 columns** carry a declared `PRIMARY KEY`
constraint:

| Table | Key |
| --- | --- |
| `circ` | `borrower#, item#` |
| `item_circ_renewal` | `borrower#, item#, renewal#` |
| `ProQuest_Purchase_DeleteList` | `bib#` — created by this repo, not Horizon |

So five of the six belong to two circulation tables, and the sixth is ours.
Horizon's own schema is, for practical purposes, primary-key-free.

### The naming trap
Hundreds of indexes are **named** like primary keys — `PK_location`,
`PK_BIB_STATUS`, `PKborrower_barcode`, `PK_acq_parameter` — and **none of them
is one**. Every such index reports `is_primary_key = no`. They are unique
indexes with a misleading name, presumably a naming habit carried over from
whatever tool created them.

Two consequences:

1. **Grain comes from unique indexes**, not from primary keys. Any tool or query
   that looks for declared PKs to discover keys will find six and conclude the
   database is unkeyed. It is not — the information is in the indexes.
2. **Never infer a constraint from an index name.** Check `is_unique` in
   `indexes_and_keys.csv`, or read the grain column in
   [`index/all-objects.md`](index/all-objects.md), which already resolves this.

### Grain of the core tables

| Object | Grain | One row per |
| --- | --- | --- |
| `bib` | `bib#, tag, tagord` | MARC tag occurrence |
| `bib_control` | `bib#` | record |
| `title` | `bib#` | record |
| `item` | `item#` (also unique on `ibarcode`) | physical copy |
| `collection` | `collection` | collection code |
| `location` | `location` | location code |
| `borrower` | `borrower#` (also unique on `second_id`) | patron |
| `circ` | `borrower#, item#` | current checkout |

`bib` fanning out per tag while `item` fans out per copy — with no key relating a
specific tag to a specific copy — is the Cartesian product this entire repository
is built to guard against. Two `590`s and three items give six rows.

---

## Foreign keys are the exception, not the rule

The database declares **166 foreign key columns**
([`index/joins.md`](index/joins.md)) — a small number for 969 tables. Most
relationships, including `bib` → `item`, are undeclared and held together by
convention alone.

Treat the FK list as a reliable record of what *is* enforced, never as a map of
how the data relates. An absent FK is not evidence that two tables are unrelated.

The FKs that do exist can still bite: the `killbib` batch delete documented in
`590-proquest-purchase-removal-report` failed on `FK_stat_data_location` because
an item carried a `location` code missing from the `location` parent table.

---

## MARC storage in `bib.text`

`bib.text` is `varchar(255)` and holds MARC subfields separated by **control
characters**, not literal pipes:

- `CHAR(31)` — subfield delimiter, so `$a` is `CHAR(31)+'a'`
- `CHAR(30)` — field terminator

Write values as `CHAR(31)+'a'+@value+CHAR(30)`. A readable `'|a'+value` column is
for **display in audit output only** — never for the value actually stored.

Two practical consequences of the 255-character limit and the control characters:

1. **Long fields split across rows.** Horizon continues a long `245`, `520`, or
   `590` into additional rows with an incremented `tagord`. Reassembly means
   ordering by `tagord`; the `245$a` parser used across this repo deliberately
   takes only the lowest-`tagord` segment, which truncates the rare long title.
2. **`FOR XML PATH` fails on this column.** `CHAR(31)`/`CHAR(30)` are illegal in
   XML, so the usual pre-2017 string-aggregation workaround throws. Combined with
   `STRING_AGG` being unavailable at this compatibility level, the practical
   answer is to ship a separate detail query with one row per tag.

---

## Engine limitations

Confirmed against this database:

| Feature | Status |
| --- | --- |
| `STRING_AGG` | **Unavailable** — *"not a recognized built-in function name"* |
| `STRING_AGG ... WITHIN GROUP` | Rejected even where the function exists |
| `FOR XML PATH` on `bib.text` | Throws — illegal XML characters |
| `CONCAT`, `IIF`, `FORMAT`, `OFFSET/FETCH` | Assume unavailable unless proven |

Write to the lowest common denominator: `CASE` instead of `IIF`, `+` instead of
`CONCAT`, `TOP` instead of `OFFSET/FETCH`. The `sys` catalog views used by the
schema exports are SQL Server 2005+ and are unaffected by compatibility level.

---

## Local tables mixed in with Horizon's

The 969 tables include local additions — scratch tables, backups, and one-off
working sets — which are not part of Horizon and may hold stale data:

- 51 `tmp*` tables
- 24 `del*` tables
- `borrower_bak`, `ipac_databases_bak`, `borrower_bak`
- `ITEM_JUV`, `ITEM_fix_status`, `temp_circ_longterm_history`
- `ProQuest_Purchase_DeleteList` (created by this repo)

`ITEM_JUV` is not `item`; `borrower_bak` is not `borrower`. The naming is
suggestive but not authoritative — confirm a table's role before querying it.

> Running the origin-and-row-count export described in [README.md](README.md)
> separates these definitively: tables sharing the install `create_date` are
> Horizon-native, later ones are local, and row counts show which are populated
> at all. Until then this list is a naming heuristic, not a verified inventory.
