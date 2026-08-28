# `location` — branch / shelving locations

**Grain: `location` — one row per code.** 89 columns, the widest table in the
database. Almost all of that width is circulation policy configuration
(loan periods, barcode prefixes, timeouts, closed-day charging rules), not
descriptive data.

| Ord | Column | Type | Notes |
| --- | --- | --- | --- |
| 1 | `location` | `code_type` → `varchar(7)` | The code — the grain |
| 2 | `name` | | Display name |
| 3 | `max_due_date` | `smallint` | Horizon day count |
| 7 | `bbarcode_prefix` / 8 `bbarcode_length` | | Borrower barcode format |
| 9 | `ibarcode_prefix` / 10 `ibarcode_length` | | Item barcode format |
| 6 | `fiscal_year_date` | `smallint` | Horizon day count |

For anything beyond these, look the column up in the CSV rather than guessing —
with 89 columns, several have similar names and different meanings.

Note the index on this table is named `PK_location` but is **not** a primary key;
it is a unique index. See the `PK_` trap in
[conventions.md](../conventions.md#keys-grain-and-the-pk_-trap).

## Orphaned location codes — a known operational failure

`item.location` joins here, and the codes are not always present:

```sql
SELECT i.location AS missing_location_code,
       COUNT(*) AS item_count, COUNT(DISTINCT i.[bib#]) AS bib_count
FROM item i
LEFT JOIN location l ON l.location = i.location
WHERE l.location IS NULL
GROUP BY i.location;
```

This is the query that diagnoses a `killbib` failure on `FK_stat_data_location`:
an item carries a location code missing from this table, so Horizon's statistics
insert fails and the delete rolls back. The fix is to restore the legitimate code
or correct the offending items — **never** to drop or disable the constraint,
which would write statistics rows pointing at a non-existent location.

Full context: `590-proquest-purchase-removal-report/README.md`.

## Related

- [`item.md`](item.md) · [`collection.md`](collection.md)
