# ProQuest Purchase 590 Removal Report

## The Problem
The catalog holds a large body of ProQuest (Ebook Central) ebook records whose
`590` (local note) tags mark them as **purchased**. These records are being
replaced wholesale: a fresh export of all owned ProQuest titles will be ingested
into Horizon, which both refreshes the existing records and adds owned titles
that were never in the catalog. Before that ingest, the existing ProQuest
purchase records must be pulled from the collection.

This report identifies exactly those records and emits the `bib#` list to remove.

### This report does not delete anything
Horizon spreads a single record across `bib`, `item`, and several dependent
index/control tables. A raw SQL `DELETE` would orphan rows in tables this script
does not touch. **The deliverable is a read-only `bib#` list**, to be handed to
Horizon's own batch-delete utility, which performs the referential cleanup
correctly.

Because this is a read-only `SELECT`, **no backup or transaction is required**
(see the read-only report exception in `CLAUDE.md`). The backup discipline
applies to whatever tool consumes the list, not to this report.

### The "Cartesian Product" Challenge
`bib` and the `item_with_title` view are both keyed by `bib#` with a one-to-many
relationship — a bib has many `590` tag rows and may have many item rows. A raw
join multiplies every `590` row by the EBK-item count, inflating the row count
and corrupting the record count. Both queries below collapse the item side to a
**`DISTINCT [bib#]` derived table** and test the `590` conditions with per-bib
`EXISTS` subqueries, so the item table can never multiply the output.

---

## Match rule and `match_type`

A bib qualifies when it has an **EBK item** and some `590` containing
`ProQuest` **and** some `590` containing `purchase` — the broad "any 590" rule.
Each qualifying bib is then labelled so the strict rule can be counted
separately without a second query:

| `match_type` | Meaning |
| --- | --- |
| `SAME_ROW` | At least one single `590` contains **both** words (e.g. `Purchased from ProQuest Ebook Central.`) |
| `CROSS_ROW_ONLY` | The two words appear only in **separate** `590` rows on the same bib |

- Count of `SAME_ROW` rows = the **strict** rule's record count.
- Count of all rows = the **broad** rule's record count.

Compare both against the expected magnitude (~2,400) **before** feeding any list
to batch delete. `CROSS_ROW_ONLY` records are the ambiguous ones — a bib holding
a ProQuest DDA note *and* an unrelated purchase note from another vendor lands
here. Review them rather than deleting them blind.

### Case sensitivity
`%ProQuest%` and `%purchase%` are both **case-insensitive** (database default
collation).

- `purchase` **must** stay case-insensitive so a note written `Purchased…` /
  `Purchase…` with a leading capital is still caught.
- Neither string is exposed to the false-positive trap that forced
  `COLLATE Latin1_General_CS_AS` on `%DDA%` in
  `590-ebk-049-dda-not-purchased-report`. That bug needed a lowercase MARC
  subfield **code** abutting content to forge the acronym (`$d` + `Da…` → `dDa`).
  MARC subfield codes are a single character, so no code/content boundary can
  manufacture `proquest` or `purchase`.

---

## Query A — The Removal List (Read-Only)
**One row per bib. Row count == record count.** This is the list handed to batch
delete. Run it in SSMS, then right-click the results grid and choose
**Save Results As… → CSV**.

```sql
WITH ebk AS (                       -- collapse the item side: one row per bib
        SELECT DISTINCT [bib#]
        FROM item_with_title
        WHERE collection = 'EBK'
),
qual AS (                           -- qualifying bibs, labelled
        SELECT
            e.[bib#],
            CASE WHEN EXISTS (      -- one 590 holding BOTH words
                     SELECT 1 FROM bib s
                     WHERE s.[bib#] = e.[bib#]
                       AND s.tag = '590'
                       AND s.text LIKE '%ProQuest%'
                       AND s.text LIKE '%purchase%')
                 THEN 'SAME_ROW'
                 ELSE 'CROSS_ROW_ONLY'
            END AS match_type
        FROM ebk e
        WHERE EXISTS (              -- bib has a 590 containing 'ProQuest'
                SELECT 1 FROM bib p
                WHERE p.[bib#] = e.[bib#]
                  AND p.tag = '590'
                  AND p.text LIKE '%ProQuest%')
          AND EXISTS (              -- bib has a 590 containing 'purchase'
                SELECT 1 FROM bib u
                WHERE u.[bib#] = e.[bib#]
                  AND u.tag = '590'
                  AND u.text LIKE '%purchase%')
)
SELECT
    q.[bib#]      AS [bib#],
    t.title       AS [title],
    q.match_type  AS [match_type],
    n.notes_590   AS [notes_590]
FROM qual q
OUTER APPLY (                       -- 245$a title (see "Title parsing" below)
    SELECT TOP 1
        RTRIM(CASE WHEN RIGHT(RTRIM(raw.sa), 1) IN ('/',':',';',',','=','.')
                   THEN RTRIM(LEFT(RTRIM(raw.sa), LEN(RTRIM(raw.sa)) - 1))
                   ELSE RTRIM(raw.sa) END) AS title
    FROM bib t245
    CROSS APPLY (SELECT CHARINDEX(CHAR(31) + 'a', t245.text) AS pa) m
    CROSS APPLY (SELECT NULLIF(CHARINDEX(CHAR(31), t245.text, m.pa + 2), 0) AS nxt,
                        NULLIF(CHARINDEX(CHAR(30), t245.text, m.pa + 2), 0) AS fend) d
    CROSS APPLY (SELECT SUBSTRING(
                     t245.text, m.pa + 2,
                     COALESCE((SELECT MIN(v) FROM (VALUES (d.nxt),(d.fend)) x(v)),
                              LEN(t245.text) + 1) - (m.pa + 2)) AS sa) raw
    WHERE t245.[bib#] = q.[bib#]
      AND t245.tag = '245'
      AND m.pa > 0
    ORDER BY t245.tagord            -- lowest-tagord 245 segment
) t
OUTER APPLY (                       -- collapse the matching 590s into one cell
    SELECT STRING_AGG(x590.text, ' | ')
               WITHIN GROUP (ORDER BY x590.tagord) AS notes_590
    FROM bib x590
    WHERE x590.[bib#] = q.[bib#]
      AND x590.tag = '590'
      AND (x590.text LIKE '%ProQuest%' OR x590.text LIKE '%purchase%')
) n
ORDER BY q.match_type, q.[bib#];
```

### If `STRING_AGG` is unavailable
`STRING_AGG` requires **SQL Server 2017+**. On an older engine, replace the
second `OUTER APPLY` block with this `FOR XML PATH` equivalent — everything else
in the query is unchanged:

```sql
OUTER APPLY (
    SELECT STUFF((
        SELECT ' | ' + x590.text
        FROM bib x590
        WHERE x590.[bib#] = q.[bib#]
          AND x590.tag = '590'
          AND (x590.text LIKE '%ProQuest%' OR x590.text LIKE '%purchase%')
        ORDER BY x590.tagord
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, '') AS notes_590
) n
```

`notes_590` is a convenience column for eyeballing what matched; it is not used
by the delete. If the `FOR XML PATH` form chokes on the control characters
embedded in `bib.text` (`CHAR(30)` / `CHAR(31)` are not legal XML 1.0
characters), simply drop the `notes_590` column and use **Query B** for
verification instead.

---

## Query B — The Detail / Verification Report (Read-Only)
**One row per matching `590` tag.** A bib with two matching `590`s appears twice,
so this row count will exceed the record count — that is expected. Use this to
verify *what actually matched* before trusting Query A's list.

```sql
WITH ebk AS (
        SELECT DISTINCT [bib#]
        FROM item_with_title
        WHERE collection = 'EBK'
),
qual AS (
        SELECT
            e.[bib#],
            CASE WHEN EXISTS (
                     SELECT 1 FROM bib s
                     WHERE s.[bib#] = e.[bib#]
                       AND s.tag = '590'
                       AND s.text LIKE '%ProQuest%'
                       AND s.text LIKE '%purchase%')
                 THEN 'SAME_ROW'
                 ELSE 'CROSS_ROW_ONLY'
            END AS match_type
        FROM ebk e
        WHERE EXISTS (
                SELECT 1 FROM bib p
                WHERE p.[bib#] = e.[bib#]
                  AND p.tag = '590'
                  AND p.text LIKE '%ProQuest%')
          AND EXISTS (
                SELECT 1 FROM bib u
                WHERE u.[bib#] = e.[bib#]
                  AND u.tag = '590'
                  AND u.text LIKE '%purchase%')
)
SELECT
    q.[bib#]     AS [bib#],
    t.title      AS [title],
    q.match_type AS [match_type],
    b.tag        AS [tag],
    b.text       AS [text]
FROM qual q
INNER JOIN bib b
        ON b.[bib#] = q.[bib#]
       AND b.tag = '590'
       AND (b.text LIKE '%ProQuest%' OR b.text LIKE '%purchase%')
OUTER APPLY (
    SELECT TOP 1
        RTRIM(CASE WHEN RIGHT(RTRIM(raw.sa), 1) IN ('/',':',';',',','=','.')
                   THEN RTRIM(LEFT(RTRIM(raw.sa), LEN(RTRIM(raw.sa)) - 1))
                   ELSE RTRIM(raw.sa) END) AS title
    FROM bib t245
    CROSS APPLY (SELECT CHARINDEX(CHAR(31) + 'a', t245.text) AS pa) m
    CROSS APPLY (SELECT NULLIF(CHARINDEX(CHAR(31), t245.text, m.pa + 2), 0) AS nxt,
                        NULLIF(CHARINDEX(CHAR(30), t245.text, m.pa + 2), 0) AS fend) d
    CROSS APPLY (SELECT SUBSTRING(
                     t245.text, m.pa + 2,
                     COALESCE((SELECT MIN(v) FROM (VALUES (d.nxt),(d.fend)) x(v)),
                              LEN(t245.text) + 1) - (m.pa + 2)) AS sa) raw
    WHERE t245.[bib#] = q.[bib#]
      AND t245.tag = '245'
      AND m.pa > 0
    ORDER BY t245.tagord
) t
ORDER BY q.[bib#], b.tagord;
```

---

## Query C — Coverage Sanity Check (Read-Only, run once)
Queries A and B decide "is EBK" from the **item** side (`item_with_title`).
A bib that has lost its item rows therefore **will not appear** in the removal
list — it would survive the purge and then collide with the freshly-ingested
records.

This query counts records that the `590` rule matches and whose own `049` tag
says `EBK`, but which have **no EBK item**. It is a count only; it changes
nothing.

```sql
SELECT COUNT(*) AS [ebk_049_bibs_with_no_ebk_item]
FROM (
    SELECT DISTINCT b049.[bib#]
    FROM bib b049
    WHERE b049.tag = '049'
      AND b049.text LIKE '%EBK%'
      AND EXISTS (SELECT 1 FROM bib p
                  WHERE p.[bib#] = b049.[bib#]
                    AND p.tag = '590'
                    AND p.text LIKE '%ProQuest%')
      AND EXISTS (SELECT 1 FROM bib u
                  WHERE u.[bib#] = b049.[bib#]
                    AND u.tag = '590'
                    AND u.text LIKE '%purchase%')
) z
WHERE NOT EXISTS (
    SELECT 1 FROM item_with_title i
    WHERE i.[bib#] = z.[bib#]
      AND i.collection = 'EBK'
);
```

**Interpreting the result:**
- **`0`** — every ProQuest purchase record has an EBK item. The item-side
  definition is provably complete; proceed with Query A.
- **`> 0`** — that many records are invisible to Query A. Decide whether to widen
  the rule to `EBK 049 tag OR EBK item` before deleting, or the missed records
  will remain in the catalog after ingest.

---

## Title parsing (`245$a`)
The title column is lifted from `590-ebk-049-dda-not-purchased-report`. Horizon
stores a MARC field's subfields in `bib.text` delimited by `CHAR(31)` (subfield
delimiter), with an optional trailing `CHAR(30)` (field terminator):
`CHAR(31)+'a'+<title>+CHAR(31)+'c'+<author>…`. The `OUTER APPLY` locates the `$a`
delimiter, takes the text up to the next `CHAR(31)`/`CHAR(30)` (or end of
string), and strips one trailing ISBD punctuation mark (`/ : ; , = .`) plus
spaces.

Horizon splits MARC fields longer than 255 characters across multiple `bib` rows
(same tag, incrementing `tagord`); these queries use the lowest-`tagord` `245`
segment, so titles over 255 chars are truncated to the first segment (rare for
`245`).

`OUTER APPLY` (not `CROSS APPLY`) keeps a qualifying bib in the report even when
its `245$a` cannot be parsed; `title` is then `NULL`. **The report never silently
hides a matching record** — critical when the output drives a deletion.

---

## Notes and edge cases
- A single `590` containing both words qualifies the bib as `SAME_ROW` and the
  bib still appears exactly once in Query A.
- `ORDER BY q.match_type, q.[bib#]` in Query A groups the two match types, so
  the `CROSS_ROW_ONLY` block can be reviewed (or sliced off) as a contiguous
  run in the CSV.
- Query A's row count is the authoritative record count. Do not use Query B's
  row count for that purpose.
- `tagord` is used only for ordering and in the title parser; it is not an
  output column.

---

## Appendix: where MUPO / SUPO live (for the duplicate-record cleanup)
A separate, related problem: the catalog holds **duplicate ProQuest records** for
the same title — typically a **subscription** record (`MUPO`) alongside an
**owned** record (`SUPO`). The subscription (`MUPO`) record is the one to remove.

A discovery query established which MARC tag actually carries these values:

```sql
SELECT tag, COUNT(*) AS hits
FROM bib
WHERE text LIKE '%MUPO%' OR text LIKE '%SUPO%'
GROUP BY tag
ORDER BY hits DESC;
```

Result:

| tag | hits |
| --- | --- |
| **590** | **360,302** |
| 245 | 9 |
| 264 | 5 |
| 536 | 3 |
| 776 | 1 |
| 520 | 1 |
| 500 | 1 |
| 246 | 1 |

**Conclusion: `MUPO`/`SUPO` are carried in the `590` tag**, the same local-note
tag used by every query above, so the eventual dedup can reuse the per-bib
`EXISTS` pattern.

**Two cautions for whoever designs that cleanup:**

1. **The long tail is a false-positive warning.** `245` (title), `264`
   (publication), `520` (summary) and `246` cannot hold a license code — those
   14 hits are incidental substring matches. This is the same class of bug that
   forced a case-sensitive collation on `%DDA%` in
   `590-ebk-049-dda-not-purchased-report`. A bare `%MUPO%` / `%SUPO%` substring
   test is therefore **not self-validating**; the dedup must anchor on ProQuest
   `590` context rather than trust the substring alone.
2. **360,302 is a count of `590` *rows*, not bibs**, and it combines `MUPO` and
   `SUPO`. The dedup needs the `MUPO`/`SUPO` split **per bib**, plus a decided
   key for "same title" (ISBN `020`? OCLC `035`? `245$a` + author?), neither of
   which this count provides.

This appendix records the field location only. **No dedup query is specified or
endorsed here.**
