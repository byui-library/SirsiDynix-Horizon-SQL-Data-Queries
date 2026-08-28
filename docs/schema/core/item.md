# `item` — physical copies

**Grain: `item#` — one row per copy.** Also uniquely indexed on `ibarcode`.
66 columns, the widest table in active cataloging use.

One bib record has many items. `item.bib#` is the link, and it is **not** a
declared foreign key — nothing at the database level enforces that an item's
`bib#` exists.

## Key columns

| Ord | Column | Type | Notes |
| --- | --- | --- | --- |
| 1 | `item#` | `int` | Item number — the grain |
| 2 | `ibarcode` | `varchar(15)` | Barcode, also unique |
| 3 | `bib#` | `int` | Parent record. No FK. |
| 4 | `location` | `code_type` | → [`location.md`](location.md) |
| 5 | `collection` | `code_type` | → [`collection.md`](collection.md) |
| 6 | `call` | | Call number |
| 8 | `copy` | | Copy statement |
| 13 | `creation_date` | `smallint` | Horizon day count |
| 18 | `delete_flag` | | **Check this** — see below |
| 19 | `itype` | `code_type` | Item type |
| 20 | `item_status` | | Circulation status |
| 24 | `borrower#` | `int` | Current borrower, if out |
| 25 | `due_date` / 26 `due_time` | `smallint` | Day count + separate time |
| 45 | `staff_only` | | Suppressed from public view |
| 57 | `call_reconstructed` | `varchar(80)` | Display-ready call number |

The `saved_*` block (columns 32–38) holds prior values retained across certain
operations — `saved_location`, `saved_collection`, `saved_call` and so on. They
are **history, not current state**. Reading `saved_collection` when you meant
`collection` yields a stale answer that looks perfectly valid.

## Traps

**`delete_flag`.** Items can be flagged deleted while still present in the table.
A query that omits this predicate counts records the catalog considers gone.
Decide deliberately whether your report includes them, and say which in the
README.

**`ITEM_JUV` and `ITEM_fix_status` are not this table.** They are local
additions, not Horizon's, and may hold stale data. See Rule 10 in
[AGENTS.md](../AGENTS.md).

**Joining `item` to `bib` multiplies.** `item` is one row per copy, `bib` is one
row per tag. Neither collapses the other. This is the Cartesian product the repo
exists to prevent — see [`bib.md`](bib.md).

## `item_with_title`

A view (58 columns) joining item data to title text, used throughout this repo's
reports. Being a view it carries no index of its own, so it appears in
[`index/no-unique-index.md`](../index/no-unique-index.md); that does **not** mean
it fans out. Its grain follows its underlying tables — one row per item.

The established idiom for "bibs having an EBK item", which collapses the item
side before it can multiply anything:

```sql
WITH ebk AS (
    SELECT DISTINCT [bib#] FROM item_with_title WHERE collection = 'EBK'
)
```

Defining "is EBK" from the item side means a bib that has lost all its item rows
will not appear. A sanity count for that case is recorded in
`590-proquest-purchase-removal-report/README.md` and returned 0.

## Related

- [`bib.md`](bib.md) · [`collection.md`](collection.md) · [`location.md`](location.md)
