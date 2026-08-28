# Schema: `bib_control`

Verified column list, captured from `sp_help bib_control` against the live
Horizon database on **2026-08-27**. One row per `bib#` — this table holds the
record's *creation and modification metadata*, not its MARC content (that is in
`bib`, one row per tag).

**Use these names verbatim. Do not infer column names from convention** — this
table's creating-operator column is `create_user`, **not** `creator`, `created_by`,
or `cataloger`.

| Column | Type | Len | Nullable | Collation |
| --- | --- | --- | --- | --- |
| `bib#` | `int` | 4 | yes | — |
| `create_date` | `smallint` | 2 | yes | — |
| `create_time` | `smallint` | 2 | yes | — |
| `create_user` | `name_string` | 30 | yes | `SQL_Latin1_General_CP850_CI_AS` |
| `change_date` | `smallint` | 2 | yes | — |
| `change_time` | `smallint` | 2 | yes | — |
| `change_user` | `name_string` | 30 | yes | `SQL_Latin1_General_CP850_CI_AS` |
| `status` | `code_type` | 7 | **no** | `SQL_Latin1_General_CP850_CI_AS` |
| `status_change_date` | `smallint` | 2 | yes | — |
| `status_change_time` | `smallint` | 2 | yes | — |
| `status_change_user` | `name_string` | 30 | yes | `SQL_Latin1_General_CP850_CI_AS` |
| `staff_only` | `zero_bit` | 1 | **no** | — |
| `timestamp` | `timestamp` | 8 | yes | — |
| `acq_controlled` | `tinyint` | 1 | yes | — |
| `bib_subfield_controlled` | `tinyint` | 1 | yes | — |
| `selection` | `name_string` | 30 | yes | `SQL_Latin1_General_CP850_CI_AS` |
| `owner#` | `int` | 4 | yes | — |
| `cat_type_id` | `int` | 4 | yes | — |

## What the types tell you

### Date and time are separate columns
`create_date` and `create_time` are two distinct `smallint`s. `create_date`
therefore carries **no time component**, which means:

- Filtering one calendar day is an exact `=` against a single integer. No
  `>= / <` half-open range is needed, and none should be written.
- `BETWEEN` across a date range is safe and inclusive of both endpoints — the
  usual `BETWEEN`-on-`datetime` end-of-day bug cannot occur here.
- Never write `CAST(create_date AS DATE) = '2026-08-25'`. Besides being wrong
  for an integer column, wrapping a column in a function prevents an index seek.

`create_time`'s **encoding is not verified** — it may be minutes since midnight,
or an `hhmm` integer. Do not use it in a predicate until it has been confirmed
against a record with a known creation time.

### `smallint` bounds the date encoding
`smallint` is signed 16-bit: max **32,767**. A days-since-`1970-01-01` encoding
(the Horizon convention) puts 2026-08-25 at **20,690** — comfortably inside the
range, and consistent with the type. That same ceiling is reached in **2059**,
so the encoding is plausible but the column has a finite life.

Because `smallint` widens to `int` implicitly, comparing it against
`DATEDIFF(day, '1970-01-01', <date>)` (which returns `int`) needs no cast.

**The epoch itself is convention, not confirmed by this dump.** Prove it before
relying on it — see the verification query below.

### `name_string` is case-insensitive
The `CI` in `SQL_Latin1_General_CP850_CI_AS` means `create_user = 'CATALOGER'` also
matches a stored `CATALOGER` or `Cataloger`. That is normally what you want for an
operator login. To force an exact-case match, append
`COLLATE Latin1_General_CS_AS` to that predicate specifically.

`TrimTrailingBlanks` is `no`, so trailing spaces are stored — but SQL Server's
`=` ignores trailing blanks when comparing character data, so `create_user =
'CATALOGER'` still matches `'CATALOGER   '`. No `RTRIM` is required.

## Verifying the date epoch

Run this before trusting any date arithmetic against this table. It converts the
largest `create_date` present back to a calendar date under the assumed epoch:

```sql
SELECT
    MAX(create_date) AS [max_day_number],
    DATEADD(day, MAX(create_date), CAST('1970-01-01' AS DATE)) AS [decodes_to],
    MIN(create_date) AS [min_day_number],
    DATEADD(day, MIN(create_date), CAST('1970-01-01' AS DATE)) AS [min_decodes_to]
FROM bib_control;
```

`decodes_to` should land on or near **today**, and `min_decodes_to` on the
catalog's oldest load. If `decodes_to` is off by a constant, the epoch differs;
shift the `'1970-01-01'` anchor by that difference everywhere. If it is
nonsensical (a 1970s or far-future date), the column is not a day count at all —
stop and re-derive the encoding before writing any dated query.

## Related tables

- `bib` — MARC content, **many rows per `bib#`** (one per tag/`tagord`). Joining
  `bib_control` to `bib` fans out; collapse with `EXISTS` when you want one row
  per record. See the Cartesian product note in `CLAUDE.md`.
- `item` / `item_with_title` — copy-level data, also many rows per `bib#`.
- `title` — supplies `processed`; one row per `bib#`.
