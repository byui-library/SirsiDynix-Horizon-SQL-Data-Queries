# `title` — normalised title text

**Grain: `bib#` — one row per record.** Only 4 columns, but it joins to `bib`
without fanning out, which makes it the safe way to attach a title.

| Ord | Column | Type | Notes |
| --- | --- | --- | --- |
| 1 | `bib#` | `int` | The grain |
| 2 | `processed` | `processed_type` → `varchar(250)` | Normalised title for indexing/matching |
| 3 | `reconst` | `reconst_type` → `varchar(250)` | Reconstructed display form |
| 4 | `backlink` | `zero_int` → `int` | |

`processed` is the column surfaced through `item_with_title` and used in this
repo's earlier reports. It is normalised text — useful for matching and for a
quick human-readable label, but it is **not** the MARC `245$a`.

## Choosing between `title.processed` and parsing `245$a`

| Need | Use |
| --- | --- |
| A quick readable label, one row per bib, no fan-out | `title.processed` |
| The exact MARC `245$a` as catalogued | Parse `bib.text` where `tag = '245'` |

Parsing `245$a` is more faithful but costs an `OUTER APPLY` and inherits the
255-character split problem described in [`bib.md`](bib.md). `title.processed`
is one clean join. Pick according to whether the report is about *the MARC data*
or *identifying the record to a human*.

## Related

- [`bib.md`](bib.md) — where `245$a` actually lives
- [`bib_control.md`](bib_control.md) — the other one-row-per-`bib#` table
