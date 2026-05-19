# EBK (049) DDA-not-purchased 590 Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a documented read-only T-SQL report query listing the DDA `590` notes (with title from `245$a`) of EBK bib records — EBK detected via the `049` tag — that have no purchase `590`, exported as CSV.

**Architecture:** Documentation-first repo: the deliverable is a new solution directory `590-ebk-049-dda-not-purchased-report/` whose `README.md` carries the Problem write-up, the MARC-parsing explanation, and the report query, linked from the top-level `README.md` index. No code build; "verification" is tracing the query against the spec's sample record (bib 5401878 → 0 rows, since it was purchased) plus a constructed positive example, since no live Horizon DB is reachable.

**Tech Stack:** T-SQL (SQL Server / SirsiDynix Horizon `Horizon` database); Markdown; Git.

**Reference spec:** `docs/superpowers/specs/2026-05-19-ebk-049-dda-not-purchased-590-report-design.md`

---

### Task 1: Create the solution README with the report query

**Files:**
- Create: `590-ebk-049-dda-not-purchased-report/README.md`

- [ ] **Step 1: Write the solution README**

Create `590-ebk-049-dda-not-purchased-report/README.md` (repo root: `c:\Users\milesm\Documents\repos\SirsiDynix Horizon SQL Data Queries`) with EXACTLY this content. Use the Write tool (not a shell heredoc). The ```` ```sql ```` block must be preserved verbatim, including every `CHAR(31)`/`CHAR(30)`, the `OUTER APPLY`/`CROSS APPLY` chain, and the `ORDER BY`:

````
# EBK (049) DDA-not-purchased 590 Report

## The Problem
SirsiDynix Horizon ebook titles (identified by an `049` tag containing
`EBK`) may carry a Demand-Driven Acquisition (`DDA`) `590` note. Acquisitions
staff need a CSV of the DDA notes on ebook records that were **never
purchased** — i.e. the bib has a `DDA` `590` but no `purchase` `590` — along
with each record's title.

### MARC subfield parsing for the title
The title comes from subfield `a` of the `245` field. Horizon stores a MARC
field's subfields in `bib.text` delimited by `CHAR(31)` (the subfield
delimiter), with an optional trailing `CHAR(30)` (field terminator):
`CHAR(31)+'a'+<title>+CHAR(31)+'c'+<author>…`. The query locates the `$a`
delimiter, takes the text up to the next `CHAR(31)`/`CHAR(30)` (or end of
string), and strips one trailing ISBD punctuation mark (`/ : ; , = .`) plus
spaces. Horizon also splits MARC fields longer than 255 characters across
multiple `bib` rows (same tag, incrementing `tagord`); this report uses the
lowest-`tagord` `245` segment, so titles over 255 chars are truncated to the
first segment (rare for `245`).

### Why no item join
EBK status is read from the bib's own `049` tag, so this report queries only
the `bib` table — there is no `item` / `item_with_title` join and therefore no
Cartesian product to manage. The purchase/DDA conditions are evaluated per bib
with `EXISTS` / `NOT EXISTS`.

---

## The Report (Read-Only)
This is a read-only `SELECT`; no backup or transaction is required. Run it in
SSMS, then right-click the results grid and choose **Save Results As… → CSV**.

```sql
SELECT
    b.[bib#] AS [bib#],
    t.title  AS [title],
    b.text   AS [text]
FROM bib b
OUTER APPLY (
    SELECT TOP 1
        -- strip one trailing ISBD punctuation mark (e.g. " /", " :") + spaces
        RTRIM(CASE WHEN RIGHT(RTRIM(raw.sa), 1) IN ('/',':',';',',','=','.')
                   THEN RTRIM(LEFT(RTRIM(raw.sa), LEN(RTRIM(raw.sa)) - 1))
                   ELSE RTRIM(raw.sa) END) AS title
    FROM bib t245
    CROSS APPLY (SELECT CHARINDEX(CHAR(31) + 'a', t245.text) AS pa) m
    CROSS APPLY (SELECT NULLIF(CHARINDEX(CHAR(31), t245.text, m.pa + 2), 0) AS nxt,
                        NULLIF(CHARINDEX(CHAR(30), t245.text, m.pa + 2), 0) AS fend) e
    CROSS APPLY (SELECT SUBSTRING(
                     t245.text, m.pa + 2,
                     COALESCE((SELECT MIN(v) FROM (VALUES (e.nxt),(e.fend)) x(v)),
                              LEN(t245.text) + 1) - (m.pa + 2)) AS sa) raw
    WHERE t245.[bib#] = b.[bib#]
      AND t245.tag = '245'
      AND m.pa > 0
    ORDER BY t245.tagord            -- lowest-tagord 245 segment
) t
WHERE b.tag = '590'
  AND b.text LIKE '%DDA%'
  AND EXISTS (                       -- bib has a 049 marking it EBK
        SELECT 1 FROM bib e049
        WHERE e049.[bib#] = b.[bib#]
          AND e049.tag = '049'
          AND e049.text LIKE '%EBK%'
      )
  AND NOT EXISTS (                   -- bib has NO 590 containing 'purchase'
        SELECT 1 FROM bib bp
        WHERE bp.[bib#] = b.[bib#]
          AND bp.tag = '590'
          AND bp.text LIKE '%purchase%'
      )
ORDER BY b.[bib#], b.tagord;
```

### Notes
- Output columns are exactly `bib#, title, text`. `text` is the DDA `590`
  note; `tagord` is used only in `ORDER BY` (stable order of multiple DDA
  `590`s per bib) and is intentionally not displayed.
- Matching is case-insensitive substring, relying on the database's default
  collation (`%DDA%`, `%EBK%`, `%purchase%`).
- A bib qualifies only when it has a `049` containing `EBK`, a `590`
  containing `DDA`, and **no** `590` containing `purchase`. A record that was
  purchased (has a purchase `590`) is intentionally excluded.
- `OUTER APPLY` keeps a qualifying bib in the report even when its `245$a`
  cannot be parsed; `title` is then NULL — the report never silently hides a
  matching record.
- Edge case: a single `590` containing both `DDA` and `purchase` excludes the
  bib (the `NOT EXISTS` purchase test fails).
````

- [ ] **Step 2: Verify the SQL block matches the approved spec**

Run: `git --no-pager diff --no-index docs/superpowers/specs/2026-05-19-ebk-049-dda-not-purchased-590-report-design.md 590-ebk-049-dda-not-purchased-report/README.md`

By inspection, confirm the ```` ```sql ```` block in
`590-ebk-049-dda-not-purchased-report/README.md` is **character-identical** to
the "The query" code block in
`docs/superpowers/specs/2026-05-19-ebk-049-dda-not-purchased-590-report-design.md`
(same `OUTER APPLY`/three `CROSS APPLY`/`SUBSTRING`/`COALESCE`/`VALUES`
expression, same `EXISTS` and `NOT EXISTS`, columns `bib#, title, text`, same
`ORDER BY b.[bib#], b.tagord`). Expected: the SQL fenced block is identical in
both files.

- [ ] **Step 3: Trace the query against the spec's sample record (negative case)**

No live Horizon DB is reachable; hand-trace bib `5401878` from the spec's
sample data:
- `049` text `aEBK` → `EXISTS` EBK satisfied.
- `590` tagord 31 = "Perpetual access ebook **purchase**…" → `NOT EXISTS
  (purchase)` is FALSE → bib `5401878` is **excluded**.
- Therefore the query returns **0 rows** for bib `5401878`.

Expected: 0 rows for the sample. This is correct — the sample record *was*
purchased, so a "DDA not purchased" report must exclude it. If your trace
returns any rows for 5401878, stop and re-open the spec.

- [ ] **Step 4: Trace a constructed positive case (title parse)**

Construct a bib `9000001` with these `bib` rows (`<US>` = `CHAR(31)`,
`<RS>` = `CHAR(30)`):
- `049` / tagord 1 / text = `<US>aEBK<RS>`
- `245` / tagord 2 / text = `<US>aQuiet leadership /<US>cDavid Rock.<RS>`
- `590` / tagord 3 / text = `<US>aProQuest Ebook Central DDA record; dda20240101.mrk<RS>`
- (no `590` containing "purchase")

Trace:
- EBK `EXISTS`: `049` contains `EBK` → TRUE.
- `NOT EXISTS (purchase)`: no `590` with "purchase" → TRUE.
- Emitted row: `590` tagord 3, `text LIKE '%DDA%'` → TRUE → emitted.
- Title: `pa = CHARINDEX(CHAR(31)+'a', …)` = 1; value starts at 3; next
  `CHAR(31)` is the one before `c` → substring = `Quiet leadership /`;
  `RIGHT(RTRIM(...),1)` = `/` ∈ set → drop it → `RTRIM('Quiet leadership ')`
  = `Quiet leadership`.
- Result: one row → `bib# = 9000001`, `title = 'Quiet leadership'`,
  `text = '…DDA record; dda20240101.mrk'`.

Expected: exactly that one row. If the trace yields a different title or row
count, stop and re-open the spec.

- [ ] **Step 5: Commit**

```bash
git add 590-ebk-049-dda-not-purchased-report/README.md
git commit -m "Add EBK (049) DDA-not-purchased 590 report query solution"
```

---

### Task 2: Link the new solution from the top-level README index

**Files:**
- Modify: `README.md` (the "Repository Structure" bullet list)

- [ ] **Step 1: Add the index entry**

In `README.md`, the Repository Structure list currently contains exactly these
two bullets:

```markdown
* **[049-duplicate-cleanup](./049-duplicate-cleanup)**: Fixes redundant 049 tags where multiple collections exist in the item table but are not represented in the bib record.
* **[590-ebk-purchase-dda-report](./590-ebk-purchase-dda-report)**: Read-only CSV report of the purchase and DDA `590` note tags on EBK-collection bib records.
```

Add a third bullet immediately after the second, so the list reads:

```markdown
* **[049-duplicate-cleanup](./049-duplicate-cleanup)**: Fixes redundant 049 tags where multiple collections exist in the item table but are not represented in the bib record.
* **[590-ebk-purchase-dda-report](./590-ebk-purchase-dda-report)**: Read-only CSV report of the purchase and DDA `590` note tags on EBK-collection bib records.
* **[590-ebk-049-dda-not-purchased-report](./590-ebk-049-dda-not-purchased-report)**: Read-only CSV report of DDA `590` notes (with title from `245$a`) on EBK bibs (via the `049` tag) that have no purchase `590`.
```

Use the Edit tool. Change ONLY the Repository Structure list — no other part of `README.md`.

- [ ] **Step 2: Verify the link target exists**

Run: `git --no-pager status --porcelain && git ls-files 590-ebk-049-dda-not-purchased-report/`

Expected: `590-ebk-049-dda-not-purchased-report/README.md` is listed (committed
in Task 1), and `README.md` shows as modified. Confirms the new index link
points at a real, tracked directory.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Link EBK (049) DDA-not-purchased 590 report from repository index"
```

---

## Self-Review

**Spec coverage:**
- Query `bib` only, no item join → Task 1 query has no `item`/`item_with_title` reference. ✓
- Emit `590` rows where `text LIKE '%DDA%'` → outer `WHERE b.tag = '590' AND b.text LIKE '%DDA%'`. ✓
- Qualify: `049` LIKE `%EBK%` → `EXISTS (… e049 … LIKE '%EBK%')`. ✓
- Qualify: no `590` LIKE `%purchase%` → `NOT EXISTS (… bp … LIKE '%purchase%')`. ✓
- Output columns `bib#, title, text` → SELECT list. ✓
- `title` = trimmed `245$a` → `OUTER APPLY` parse chain + ISBD trim CASE. ✓
- Missing `245$a` keeps row, NULL title → `OUTER APPLY` (not `CROSS APPLY`). ✓
- MARC `CHAR(31)`/`CHAR(30)` parsing + lowest-`tagord` 245 → documented in README "MARC subfield parsing" + `ORDER BY t245.tagord`. ✓
- Case-insensitive matching → stated in Notes. ✓
- CSV via SSMS, read-only/no backup → "The Report (Read-Only)" section. ✓
- Repo convention: new directory + README, linked from index, read-only pattern per CLAUDE.md carve-out → Task 1 + Task 2. ✓
- Sample record returns 0 rows (was purchased) → Task 1 Step 3 trace. ✓

No spec requirement is left without a task.

**Placeholder scan:** No TBD/TODO/"similar to"/"handle edge cases" — full
README content and the exact index bullet are written verbatim; both trace
cases give concrete expected outputs. ✓

**Type/name consistency:** Aliases and identifiers (`b`, `t`, `t245`, `m`,
`e`, `raw`, `e049`, `bp`; `pa`, `nxt`, `fend`, `sa`; columns `bib#`, `title`,
`text`) are identical across the spec, the Task 1 query, both trace steps, and
the index description. ✓
