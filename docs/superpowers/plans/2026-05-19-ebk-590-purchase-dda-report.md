# EBK Purchase/DDA 590 Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a documented T-SQL report query that lists the `590` purchase/DDA note tags for Horizon EBK-collection bib records, exported as CSV.

**Architecture:** Documentation-first repo: the deliverable is a new solution directory `590-ebk-purchase-dda-report/` whose `README.md` carries the Problem write-up and the report query, linked from the top-level `README.md` index. No code build; "verification" is tracing the query against the spec's sample record (bib 5401878) and a SQL syntax sanity check, since no live Horizon DB is reachable.

**Tech Stack:** T-SQL (SQL Server / SirsiDynix Horizon `Horizon` database); Markdown; Git.

**Reference spec:** `docs/superpowers/specs/2026-05-19-ebk-590-purchase-dda-report-design.md`

---

### Task 1: Create the solution README with the report query

**Files:**
- Create: `590-ebk-purchase-dda-report/README.md`

- [ ] **Step 1: Write the solution README**

Create `590-ebk-purchase-dda-report/README.md` with exactly this content:

````markdown
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
````

- [ ] **Step 2: Verify the README content matches the approved spec**

Run: `git --no-pager diff --no-index docs/superpowers/specs/2026-05-19-ebk-590-purchase-dda-report-design.md 590-ebk-purchase-dda-report/README.md`

This is only to eyeball the SQL block. Confirm by inspection that the SQL in
`590-ebk-purchase-dda-report/README.md` is **character-identical** to the
"The query" code block in the spec (same joins, same `EXISTS`, same `ORDER BY`,
columns `bib#, processed, text, tag`). Expected: the SQL fenced block is the
same in both files.

- [ ] **Step 3: Trace the query against the spec's sample record**

No live Horizon DB is reachable, so verify by hand-tracing bib `5401878` from
the spec's sample data:
- `item_with_title` row for 5401878 has `collection = 'EBK'` → the
  `DISTINCT [bib#], processed` derived table yields one row for 5401878 →
  `INNER JOIN` matches, `processed` surfaced. PASS.
- `590` tagord 31 text contains "purchase" → `EXISTS` purchase TRUE; outer
  predicate `text LIKE '%purchase%'` TRUE → row emitted. PASS.
- `590` tagord 32 text contains "DDA" → `EXISTS` DDA TRUE; outer predicate
  `text LIKE '%DDA%'` TRUE → row emitted. PASS.
- No other `590` rows match purchase/DDA → exactly 2 rows for 5401878,
  ordered tagord 31 then 32, columns `bib#, processed, text, tag`. PASS.

Expected: all four checks PASS. If any fails, stop and re-open the spec.

- [ ] **Step 4: Commit**

```bash
git add 590-ebk-purchase-dda-report/README.md
git commit -m "Add EBK purchase/DDA 590 report query solution"
```

---

### Task 2: Link the new solution from the top-level README index

**Files:**
- Modify: `README.md` (the "Repository Structure" bullet list)

- [ ] **Step 1: Add the index entry**

In `README.md`, the Repository Structure list currently contains exactly one
bullet:

```markdown
* **[049-duplicate-cleanup](./049-duplicate-cleanup)**: Fixes redundant 049 tags where multiple collections exist in the item table but are not represented in the bib record.
```

Add a second bullet immediately after it, so the list reads:

```markdown
* **[049-duplicate-cleanup](./049-duplicate-cleanup)**: Fixes redundant 049 tags where multiple collections exist in the item table but are not represented in the bib record.
* **[590-ebk-purchase-dda-report](./590-ebk-purchase-dda-report)**: Read-only CSV report of the purchase and DDA `590` note tags on EBK-collection bib records.
```

- [ ] **Step 2: Verify the link target exists**

Run: `git --no-pager status --porcelain && git ls-files 590-ebk-purchase-dda-report/`

Expected: `590-ebk-purchase-dda-report/README.md` is listed (committed in
Task 1), and `README.md` shows as modified. Confirms the new index link points
at a real, tracked directory.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Link EBK purchase/DDA 590 report from repository index"
```

---

## Self-Review

**Spec coverage:**
- Relate `bib` to `item_with_title` by `bib#` → Task 1 query `INNER JOIN ... ON ebk.[bib#] = b.[bib#]`. ✓
- EBK-collection qualification → derived table `WHERE collection = 'EBK'`. ✓
- Two 590s (purchase + DDA) → two `EXISTS` subqueries. ✓
- Emit only matching 590 rows → outer `b.tag = '590' AND (text LIKE '%purchase%' OR text LIKE '%DDA%')`. ✓
- Display `processed` → `ebk.processed AS [processed]`. ✓
- Column order `bib#, processed, text, tag` → SELECT list. ✓
- `tagord` order-only, not displayed → `ORDER BY b.[bib#], b.tagord`, absent from SELECT. ✓
- CSV delivery (SELECT only, SSMS Save Results As) → documented in README "The Report" section. ✓
- Repo convention: new directory + README, linked from index → Task 1 + Task 2. ✓
- Read-only, no backup/transaction → stated in README. ✓

No spec requirement is left without a task.

**Placeholder scan:** No TBD/TODO/"similar to"/"handle edge cases" — the full
README content and the exact index bullet are written out verbatim. ✓

**Type/name consistency:** Column aliases (`bib#`, `processed`, `text`, `tag`),
table/view names (`bib`, `item_with_title`), derived-table alias (`ebk`), and
subquery aliases (`bp`, `bd`) are identical across the spec, Task 1 query, and
the index description. ✓
