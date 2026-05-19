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
