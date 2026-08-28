# `bib` — MARC record content

**Grain: `bib#, tag, tagord` — one row per MARC tag occurrence.**
12 columns. This is the most-queried table in the repository and the source of
its signature hazard.

A bibliographic record is not a row here. It is a *set* of rows — one per MARC
field, and more than one per field when the field is long.

## Columns

| Ord | Column | Type | Notes |
| --- | --- | --- | --- |
| 1 | `bib#` | `int` | Record number. Not unique in this table. |
| 4 | `indicators` | `char(2)` | MARC indicators |
| 5 | `text` | `varchar(255)` | Subfield content — **control-character encoded** |
| 6 | `cat_link_xref#` | `int` | Authority/link cross-reference |
| 9 | `link_type` | `tinyint` | |
| 10 | `tag` | `tag_type` → `varchar(5)` | MARC tag: `'245'`, `'590'`, `'049'` |
| 11 | `tagord` | `tagord_type` → `int` | Ordinal among repeated tags |
| 12 | `cat_link_type#` | `key#` → `int` | |

Columns 2, 3, and 8 are named `unused_smallint`, `unused_ord_type`, and
`unused_int`. They are exactly what they say — do not read meaning into them.

## The fan-out

`bib` has many rows per `bib#`, and so does `item`. Nothing links a specific tag
row to a specific item row, because no such relationship exists — they are
independent children of the same record.

> A bib with **2** `590` tags and **3** items yields **6 rows** from
> `bib JOIN item`. The count is not a bug in the join; it is what the join means.

Collapse the tag side whenever you want one row per record:

```sql
-- Test a condition on the record without multiplying it
WHERE EXISTS (SELECT 1 FROM bib b
              WHERE b.[bib#] = x.[bib#] AND b.tag = '590'
                AND b.text LIKE '%ProQuest%')
```

Use a plain `JOIN` only when the fan-out is the point — a detail report showing
one row per tag.

## `text` is control-character encoded

Subfields are separated by `CHAR(31)`; `CHAR(30)` terminates the field. `$a` is
`CHAR(31)+'a'`. There are no literal pipes in the stored data.

```sql
-- Writing a value
SET text = CHAR(31)+'a'+@value+CHAR(30)

-- Displaying one in audit output only
SELECT '|a' + <parsed value> AS [readable]
```

Because `text` is `varchar(255)`, **long fields are split across multiple rows**
with an incremented `tagord`. A `520` summary routinely spans several rows; a
`245` occasionally does. Reassembly means ordering by `tagord` — and note that
`FOR XML PATH` cannot do it, because `CHAR(31)`/`CHAR(30)` are illegal in XML,
while `STRING_AGG` is unavailable at this compatibility level. Ship a detail
query instead.

## Targeting one of several same-`tag` rows

Isolate by `tagord`:

```sql
-- The later of two duplicate tags, preserving the first
AND b.tagord = (SELECT MAX(tagord) FROM bib
                WHERE [bib#] = b.[bib#] AND tag = '049')
```

For "this record has exactly N identical tags", the established idiom is:

```sql
HAVING COUNT(*) = 2 AND MIN(text) = MAX(text)
```

## Extracting `245$a`

The title parser reused across this repo's reports locates the `$a` delimiter,
takes text up to the next `CHAR(31)`/`CHAR(30)` or end of string, then strips one
trailing ISBD punctuation mark (`/ : ; , = .`). It uses the **lowest `tagord`**
segment, so a `245` split across rows truncates to its first segment.

Always attach it with `OUTER APPLY`, never `CROSS APPLY` — a record whose `245$a`
cannot be parsed must still appear in the report rather than silently vanishing.
See `590-proquest-purchase-removal-report/README.md` for the full expression.

## Case sensitivity when matching `text`

`text` is `SQL_Latin1_General_CP850_CI_AS` — case-insensitive. Usually right:
`%ProQuest%` should match `PROQUEST` and `Proquest`.

But short uppercase acronyms need care. A case-insensitive `%DDA%` also matches
the `dDa` sequence produced where a `$d` subfield code abuts content beginning
`Da…`, generating false positives. Add `COLLATE Latin1_General_CS_AS` for those:

```sql
AND b.text COLLATE Latin1_General_CS_AS LIKE '%DDA%'
```

Long distinctive literals like `ProQuest` cannot be forged at a code/content
boundary and need no guard.

## Related

- [`bib_control.md`](bib_control.md) — one row per `bib#`; creation metadata
- [`title.md`](title.md) — one row per `bib#`; normalised title text
- [`item.md`](item.md) — copies; the other half of the Cartesian product
