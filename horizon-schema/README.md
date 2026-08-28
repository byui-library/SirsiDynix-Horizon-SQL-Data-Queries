# Raw schema exports

Machine-generated CSV dumps of this Horizon database's schema. **These are the
source of truth** for every table and column name used in this repository.

First captured **2026-08-27**; refreshed **2026-08-28** after the scratch-table
cleanup dropped 42 tables. These files match the live database as of that date.

| File | Rows | Contents |
| --- | ---: | --- |
| `all_tables_all_views.csv` | 13,949 | Every column of every table and view |
| `indexes_and_keys.csv` | 1,868 | Every index, its columns, uniqueness |
| `foreign_keys.csv` | 166 | Every declared foreign key column |

## No header row

These are saved from SSMS with **Results to Grid → Save Results As… → CSV**,
which omits headers. Field order is fixed by the export query and is documented
in [`docs/schema/README.md`](../docs/schema/README.md).

`all_tables_all_views.csv`:

```
1 schema        2 object      3 object_type   4 ord        5 column
6 declared_type 7 base_type   8 len_bytes     9 prec      10 scale
11 nullable    12 is_identity 13 is_computed 14 collation 15 pk
16 pk_ord      17 default_definition
```

`indexes_and_keys.csv`:

```
1 schema  2 object  3 index_name  4 index_type  5 is_pk
6 is_unique  7 key_ord  8 column  9 direction  10 part
```

`foreign_keys.csv`:

```
1 fk_name  2 parent_schema  3 parent_table  4 parent_column
5 referenced_schema  6 referenced_table  7 referenced_column
8 col_ord  9 on_delete  10 on_update  11 disabled
```

The files carry a UTF-8 BOM. `Import-Csv` and `grep` both handle it; strip it
with `sed '1s/^\xEF\xBB\xBF//'` if a tool chokes.

## Reading them

Lookup recipes are in [`docs/schema/AGENTS.md`](../docs/schema/AGENTS.md#rule-2--look-it-up-like-this).
The short version:

```bash
grep -E '^dbo,bib_control,' "horizon-schema/all_tables_all_views.csv"
```

## Refreshing

The four export queries are in [`docs/schema/README.md`](../docs/schema/README.md).
After overwriting these files, regenerate the derived pages:

```powershell
powershell -ExecutionPolicy Bypass -File tools\Generate-SchemaDocs.ps1
```

## Why these CSVs are committed

`.gitignore` blocks `*.csv` to keep catalog and patron data out of this public
repo. These files are schema **metadata** — names, types, collations, index and
FK definitions. No catalog records, no patron data, no credentials. A narrow
`!horizon-schema/*.csv` exception keeps them tracked while the blanket rule
continues to protect everything else.

**Do not add exceptions for query output.** Results from `borrower`, `circ`, or
any patron-bearing table must never be committed.
