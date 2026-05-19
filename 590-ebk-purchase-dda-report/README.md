# EBK Purchase/DDA 590 Report

## The Problem
SirsiDynix Horizon ebook titles often carry two distinct `590` (local note)
tags: a vendor **purchase** note and a **DDA** (Demand-Driven Acquisition)
note. Acquisitions staff need a CSV of these note pairs, limited to titles
that have at least one item in the `EBK` collection, alongside the title's
`processed` value.

### The "Cartesian Product" Challenge
`bib` and the `item_with_title` view are both keyed by `bib#` with a
one-to-many relationship — a bib has many `590` tag rows and may have many
item rows. A raw join multiplies every `590` row by the EBK-item count,
producing duplicate report lines. This report avoids that by joining to a
**deduplicated** `DISTINCT [bib#], processed` derived table (one row per bib,
since `processed` is title-level) and testing purchase/DDA presence with
per-bib `EXISTS` subqueries.

---

## The Report (Read-Only)
This is a read-only `SELECT`; no backup or transaction is required. Run it in
SSMS, then right-click the results grid and choose **Save Results As… → CSV**.

```sql
SELECT
    b.[bib#]      AS [bib#],
    ebk.processed AS [processed],
    b.text        AS [text],
    b.tag         AS [tag]
FROM bib b
INNER JOIN (
        SELECT DISTINCT [bib#], processed
        FROM item_with_title
        WHERE collection = 'EBK'
    ) ebk
    ON ebk.[bib#] = b.[bib#]
WHERE b.tag = '590'
  AND (b.text LIKE '%purchase%' OR b.text LIKE '%DDA%')
  AND EXISTS (                       -- bib has a 590 containing 'purchase'
        SELECT 1 FROM bib bp
        WHERE bp.[bib#] = b.[bib#]
          AND bp.tag = '590'
          AND bp.text LIKE '%purchase%'
      )
  AND EXISTS (                       -- bib has a 590 containing 'DDA'
        SELECT 1 FROM bib bd
        WHERE bd.[bib#] = b.[bib#]
          AND bd.tag = '590'
          AND bd.text LIKE '%DDA%'
      )
ORDER BY b.[bib#], b.tagord;
```

### Notes
- Matching is case-insensitive substring, relying on the database's default
  collation (`%purchase%`, `%DDA%`).
- Output columns are exactly `bib#, processed, text, tag`. `tagord` is used
  only in `ORDER BY` (purchase row sorts above DDA row) and is intentionally
  not displayed.
- A bib qualifies only when it has an `EBK` item **and** a `%purchase%` 590
  **and** a `%DDA%` 590; only the matching 590 rows are emitted.
- Edge case: a single `590` containing both words qualifies the bib and
  appears once.
