# `collection` — collection codes

**Grain: `collection` — one row per code.** 17 columns. A lookup table;
`item.collection` (`code_type`) joins to it.

| Ord | Column | Type | Notes |
| --- | --- | --- | --- |
| 1 | `collection` | `code_type` → `varchar(7)` | The code — the grain |
| 2 | `descr` | `varchar(255)` | Staff-facing description |
| 3 | `pac_descr` | `varchar(255)` | Public catalogue description |
| 5 | `call_type` | `code_type` | |
| 7 | `avg_repl_cost` | `int` | |
| 8 | `n_items` | `zero_int` | Cached item count |
| 15 | `floating` | `zero_bit` | Floating collection flag |

`EBK` is the ebook collection code used throughout this repo's ProQuest work.

## Joining safely

`collection` is one row per code, so joining `item` to it never multiplies —
it is a pure lookup:

```sql
SELECT i.[item#], i.collection, c.descr
FROM item i
LEFT JOIN collection c ON c.collection = i.collection
```

Use `LEFT JOIN`, not `INNER`. An item can carry a collection code that is absent
from this table — that is exactly the class of orphaned-code problem that broke
the `killbib` run documented in `590-proquest-purchase-removal-report`, where an
item's `location` code was missing from `location`. An `INNER JOIN` would hide
those items instead of showing you the problem.

Finding orphaned codes:

```sql
SELECT i.collection AS missing_code, COUNT(*) AS items
FROM item i
LEFT JOIN collection c ON c.collection = i.collection
WHERE c.collection IS NULL
GROUP BY i.collection;
```

## Case sensitivity

`collection` is `SQL_Latin1_General_CP850_CI_AS`, so `= 'EBK'` also matches
`ebk`. Fine in practice; codes are conventionally uppercase.

## Related

- [`item.md`](item.md) — the child that carries the code
- [`location.md`](location.md) — same lookup pattern
