# EBK (049) DDA-not-purchased 590 Report — Design

Date: 2026-05-19
Status: Approved (pending written-spec review)

## Goal

Produce a CSV report of the `590` DDA notes on SirsiDynix Horizon ebook
bibliographic records that were **not** purchased, where "ebook" is determined
by the bib's own `049` tag (no item table involved), including the record's
title parsed from `245$a`.

This is a rework of `590-ebk-purchase-dda-report`: the EBK signal moves from
`item_with_title.collection` to the `049` bib tag, the title comes from
`245$a`, and the only emitted notes are the DDA `590`s of bibs that have no
purchase `590`.

## Requirements

1. Query the `bib` table only — **no** `item_with_title` / item join.
2. Emit each `590` row of a qualifying bib whose `text LIKE '%DDA%'`.
3. A bib qualifies only when:
   - it has a `049` tag with `text LIKE '%EBK%'`, **and**
   - it has **no** `590` tag with `text LIKE '%purchase%'`.
4. Output columns, in this exact order: `bib#`, `title`, `text`.
   - `title` = subfield `a` of the bib's `245`, cleaned/trimmed.
   - `text` = the DDA `590` note text.
5. A qualifying bib with no parseable `245$a` still appears, with `title` NULL
   (`OUTER APPLY`).
6. Deliver as a CSV file.

## Decisions (from brainstorming)

- **Output columns:** `bib#, title, text` only (drop `processed` and `tag`).
- **NOT-purchase:** carried forward — qualify only if no purchase `590` exists.
- **EBK source:** the `049` tag (`LIKE '%EBK%'`), not item collection.
- **Title:** clean `245$a` only, with one trailing ISBD punctuation mark
  (`/ : ; , = .`) and surrounding spaces stripped.
- **Missing title:** `OUTER APPLY` — keep the row, NULL title; never hide a
  matching record.
- **CSV method:** deliver the `SELECT` only; run in SSMS, *Save Results As…
  → CSV*. Matches this repo's documentation-first convention.
- **Match strictness:** case-insensitive substring, default collation.
- **`tagord`:** order-only (stable ordering of multiple DDA `590`s per bib);
  not a displayed column.

## MARC parsing notes

`bib.text` stores a MARC field's subfields delimited by `CHAR(31)` (subfield
delimiter); a field may end with `CHAR(30)` (field terminator). The `245`
field's content looks like `CHAR(31)+'a'+<title>+CHAR(31)+'c'+<author>…`.

Title extraction:

1. `pa = CHARINDEX(CHAR(31)+'a', text)` — locate the `$a` delimiter. If `pa = 0`
   there is no subfield a; that `245` row is skipped.
2. Value starts at `pa + 2` (past the `CHAR(31)` and the `'a'` code).
3. Value ends at the earliest of: the next `CHAR(31)` at/after `pa+2`, the next
   `CHAR(30)` at/after `pa+2`, or end of string.
4. Strip one trailing ISBD punctuation char in `(/ : ; , = .)` plus surrounding
   spaces (`RTRIM`).

Multi-row `245`: Horizon splits MARC fields longer than `varchar(255)` across
multiple `bib` rows sharing the tag with incrementing `tagord`. This report
uses the lowest-`tagord` `245` segment (`TOP 1 … ORDER BY tagord`). Titles that
overflow 255 chars are therefore truncated to the first segment — rare for
`245`, documented as a known limit.

## The query

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

## Verification against the sample record (bib 5401878)

The sample is an EBK record with both a purchase 590 and a DDA 590:

- `049` text `aEBK` → matches `%EBK%`, EBK `EXISTS` satisfied.
- `590` tagord 31 = "…ebook **purchase**…" → `NOT EXISTS (purchase)` is
  **FALSE** → bib 5401878 is **excluded**. Correct: it *was* purchased, so it
  must not appear in a "DDA not purchased" report.

So bib 5401878 returns **0 rows** — the intended behavior for this report. (A
record that would appear is one with a `049` EBK, a DDA `590`, and no purchase
`590`; its `245$a` "…aSome title /c…" would render as `Some title`.)

## Assumptions / edge cases

1. **Empty/odd `245$a`:** if `245` has a `$a` delimiter immediately followed by
   the next subfield, `title` is an empty string. If no `$a` delimiter at all,
   the row still appears with `title` NULL (`OUTER APPLY`).
2. **`049` containing EBK as a substring:** `LIKE '%EBK%'` matches `EBK`
   anywhere in the `049` text (e.g. `aEBK`), consistent with how Horizon stores
   the collection code in `049$a`.
3. **Multi-row `245`:** lowest-`tagord` segment only (see MARC parsing notes).
4. **Single 590 containing both "DDA" and "purchase":** `NOT EXISTS (purchase)`
   fails → bib excluded. Consistent with "no purchase 590 anywhere."
5. Read-only `SELECT`; no backup or transaction wrapper needed.

## Deliverable / repo placement

Per repo convention, a new directory `590-ebk-049-dda-not-purchased-report/`
containing a `README.md` (Problem → MARC-parsing explanation → the report
query → CSV-export note), linked from the top-level `README.md` "Repository
Structure" index. Read-only report — uses the **The Report (Read-Only)**
section pattern documented in `CLAUDE.md`'s read-only report exception. No
`UPDATE`, so audit/backup/transaction conventions do not apply.
