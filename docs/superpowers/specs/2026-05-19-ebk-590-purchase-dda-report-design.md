# EBK Purchase/DDA 590 Report — Design

Date: 2026-05-19
Status: Approved (pending written-spec review)

## Goal

Produce a CSV report of bibliographic `590` (local note) tags for SirsiDynix
Horizon ebook records that carry **both** a vendor "purchase" note and a "DDA"
(Demand-Driven Acquisition) note, where the title has at least one item in the
`EBK` collection.

## Requirements

1. Relate the `bib` table to the `item_with_title` view by `bib#`.
2. Qualify a bib only when it has at least one `item_with_title` row with
   `collection = 'EBK'`.
3. Qualify a bib only when it has **at least two** `590` tags: one whose `text`
   contains `purchase`, and a (separate) one whose `text` contains `DDA`.
4. Emit only the matching `590` rows — the `%purchase%` row and the `%DDA%` row —
   not every `590` on the bib.
5. Display the `processed` field (from the `title` table, surfaced by the
   `item_with_title` view).
6. Output columns, in this exact order: `bib#`, `processed`, `text`, `tag`.
7. Deliver as a CSV file.

## Decisions (from brainstorming)

- **Output rows:** only the two matching `590` rows per qualifying bib.
- **CSV method:** deliver the `SELECT` only; the operator runs it in SSMS and uses
  *Save Results As… → CSV*. Matches this repo's documentation-first convention.
- **Match strictness:** case-insensitive substring (`LIKE '%purchase%'`,
  `LIKE '%DDA%'`), relying on the database's default case-insensitive collation.
- **Approach:** qualify with correlated `EXISTS` (the self-join idea, expressed as
  `EXISTS` to avoid row multiplication). Accuracy is the priority.
- **`tagord`:** used only in `ORDER BY` for stable row order (purchase row before
  DDA row); not a displayed/CSV column.

## The Cartesian-product problem and its resolution

`bib` and `item_with_title` are both keyed by `bib#` with a one-to-many (often
many-to-many) relationship: a bib can have multiple `590` tag rows and multiple
item rows. A raw join multiplies every `590` row by the EBK-item count, producing
duplicate report lines.

Resolution:

- EBK qualification uses an `INNER JOIN` to a **deduplicated derived table**,
  `SELECT DISTINCT [bib#], processed FROM item_with_title WHERE collection = 'EBK'`.
  `processed` originates in the `title` table (one row per `bib#` in the view), so
  it is constant per bib; `DISTINCT [bib#], processed` yields exactly one row per
  qualifying bib. This is still "a join on `item_with_title` by `bib#`", just
  collapsed so it cannot multiply rows.
- Purchase / DDA presence is tested with correlated `EXISTS` subqueries against
  `bib`, computed per bib, so they qualify without multiplying rows.

## The query

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

## Verification against the sample record (bib 5401878)

- `item_with_title` collection = `EBK` → join qualifies, `processed` surfaced.
- `590` / tagord 31: "Perpetual access ebook **purchase**; SUPO; autopurchase
  3/27/26." → matches `%purchase%`, `EXISTS` purchase satisfied.
- `590` / tagord 32: "ProQuest Ebook Central **DDA** record;
  dda20210916_20210917-SH.mrk" → matches `%DDA%`, `EXISTS` DDA satisfied.
- Output: exactly 2 rows (tagord 31 then 32), columns `bib#, processed, text, tag`.

## Assumptions / edge cases

1. **Single 590 containing both words:** if one `590` row contains both
   "purchase" and "DDA", it qualifies the bib and appears once. Stated intent is
   two distinct tags; the representative sample has two distinct tags. Left simple
   and documented rather than adding a distinct-`tagord` guard for an unlikely
   case.
2. **`collection = 'EBK'`** is an exact match; SQL Server `=` ignores trailing
   spaces, so `char` padding is a non-issue.
3. **`processed` is title-level** (one row per `bib#` via the view), so the
   `DISTINCT` collapse yields one row per bib. If a bib ever had divergent
   `processed` values across item rows, the bib could appear with multiple
   `processed` values — not expected given the view's `title` join.
4. Read-only `SELECT`; no backup or transaction wrapper needed.

## Deliverable / repo placement

Per repo convention, a new directory `590-ebk-purchase-dda-report/` containing a
`README.md` (Problem → the report query → CSV-export note), linked from the
top-level `README.md` "Repository Structure" index. No `UPDATE`, so the
audit/backup/transaction conventions for destructive scripts do not apply.
