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
correctly. Because this is a read-only `SELECT`, **no backup or transaction is
required** (see the read-only report exception in `CLAUDE.md`).

### The "Cartesian Product" Challenge
`bib` and the `item_with_title` view are both keyed by `bib#` with a one-to-many
relationship — a bib has many `590` tag rows and may have many item rows. A raw
join multiplies every `590` row by the EBK-item count, inflating the row count
and corrupting the record count that drives the deletion. Every query below
collapses the item side to a `DISTINCT [bib#]` derived table (`ebk` CTE) and
tests the `590` conditions with per-bib `EXISTS` subqueries, so the item table
can never multiply the output.

---

## Match rule

A record qualifies for removal when **all** of the following hold:

1. It has an **EBK item** (`item_with_title.collection = 'EBK'`).
2. It has a `590` that is a **ProQuest purchase note** — see the two classes
   below.
3. The record has **no DDA `590`** anywhere (record-level `NOT DDA`).

Condition 2 has two classes, reported side by side so the exact criteria can be
chosen after seeing the counts:

| `match_class` | Definition | Meaning |
| --- | --- | --- |
| `STRICT` | A single `590` contains **both** `ProQuest` **and** `purchase` | The literal refined rule: "ProQuest AND purchase in the same 590, NOT DDA." |
| `BROADENED_ONLY` | No single `590` has both words, **but** a `590` contains `purchase` together with `SUPO` or `MUPO` | A ProQuest purchase note that omits the literal word "ProQuest" (e.g. `Perpetual access ebook purchase; SUPO; autopurchase`). `SUPO`/`MUPO` are ProQuest's own license codes. |

- **The strict list** = `match_class = 'STRICT'` (~2,019 bibs in the last run).
- **The full list** = both classes. The `BROADENED_ONLY` rows are the ~380-record
  gap between the strict count and the expected ~2,400: purchase records whose
  `590` never spells out "ProQuest" and which the strict rule structurally
  misses, leaving them to duplicate against the fresh ingest.

Run **Query C** first to see both counts, then delete from `STRICT` only, or
from both, per that decision.

### Why `SUPO`/`MUPO` and not "subscription"
`SUPO` (Single-User Purchase Option) and `MUPO` (Multi-User Purchase Option) are
both **purchase** license models — seat counts on an owned title, not a
subscription. The original request assumed "MUPO = subscription record, remove
it"; the data disproves that (see the Appendix). MUPO appears on hundreds of
owned perpetual-access purchase notes. The true subscription marker is the
literal phrase `subscription` (e.g. `ProQuest LibCentral subscription`), which is
**not** part of this removal rule and is surfaced only as a warning column.

### Deletion hazard: `has_subscription`
A handful of bibs carry **both** a purchase `590` and a live
`ProQuest LibCentral subscription` `590` on the same record. Deleting such a bib
removes the subscription access too. These qualify only via `BROADENED_ONLY`, and
those without a DDA note are **not** filtered out by the `NOT DDA` condition.
Every query emits a `has_subscription` column (`Y` / blank) so these are visible;
review them before deleting.

### Case sensitivity
- `%purchase%` and `%ProQuest%` — **case-insensitive** (default collation).
  `purchase` must stay case-insensitive to catch `Purchased…`; `ProQuest` to
  catch any `PROQUEST`/`Proquest` variant.
- `%SUPO%`, `%MUPO%`, `%DDA%` — **case-sensitive** (`COLLATE
  Latin1_General_CS_AS`). MARC subfield codes are lowercase, so an uppercase
  acronym can never be forged at a code/content boundary. This is the same
  `dDa` false-positive guard proven necessary in
  `590-ebk-049-dda-not-purchased-report`; applied to `SUPO`/`MUPO` for the same
  reason.

---

## Query A — The Removal List (Read-Only)
**One row per bib.** Columns: `bib#`, `title`, `match_class`, `has_subscription`,
`purchase_590`. Filter on `match_class` to take the strict list or the full list.
Run in SSMS, then right-click the grid → **Save Results As… → CSV**.

```sql
WITH ebk AS (                        -- collapse the item side: one row per bib
        SELECT DISTINCT [bib#]
        FROM item_with_title
        WHERE collection = 'EBK'
),
qual AS (
        SELECT
            e.[bib#],
            CASE WHEN EXISTS (       -- one 590 holding BOTH words -> STRICT
                     SELECT 1 FROM bib s
                     WHERE s.[bib#] = e.[bib#] AND s.tag = '590'
                       AND s.text LIKE '%ProQuest%'
                       AND s.text LIKE '%purchase%')
                 THEN 'STRICT' ELSE 'BROADENED_ONLY'
            END AS match_class,
            CASE WHEN EXISTS (       -- record also carries a subscription note
                     SELECT 1 FROM bib sub
                     WHERE sub.[bib#] = e.[bib#] AND sub.tag = '590'
                       AND sub.text LIKE '%subscription%')
                 THEN 'Y' ELSE '' END AS has_subscription
        FROM ebk e
        WHERE EXISTS (               -- a ProQuest purchase 590 (strict OR broadened)
                SELECT 1 FROM bib p
                WHERE p.[bib#] = e.[bib#] AND p.tag = '590'
                  AND p.text LIKE '%purchase%'
                  AND (p.text LIKE '%ProQuest%'
                       OR p.text COLLATE Latin1_General_CS_AS LIKE '%SUPO%'
                       OR p.text COLLATE Latin1_General_CS_AS LIKE '%MUPO%'))
          AND NOT EXISTS (           -- record-level NOT DDA (case-sensitive)
                SELECT 1 FROM bib d
                WHERE d.[bib#] = e.[bib#] AND d.tag = '590'
                  AND d.text COLLATE Latin1_General_CS_AS LIKE '%DDA%')
)
SELECT
    q.[bib#]           AS [bib#],
    t.title            AS [title],
    q.match_class      AS [match_class],
    q.has_subscription AS [has_subscription],
    n.purchase_590     AS [purchase_590]
FROM qual q
OUTER APPLY (                        -- 245$a title (see "Title parsing" below)
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
    WHERE t245.[bib#] = q.[bib#] AND t245.tag = '245' AND m.pa > 0
    ORDER BY t245.tagord             -- lowest-tagord 245 segment
) t
OUTER APPLY (                        -- the qualifying purchase 590(s), one cell
    SELECT STRING_AGG(pp.text, ' | ')
               WITHIN GROUP (ORDER BY pp.tagord) AS purchase_590
    FROM bib pp
    WHERE pp.[bib#] = q.[bib#] AND pp.tag = '590'
      AND pp.text LIKE '%purchase%'
      AND (pp.text LIKE '%ProQuest%'
           OR pp.text COLLATE Latin1_General_CS_AS LIKE '%SUPO%'
           OR pp.text COLLATE Latin1_General_CS_AS LIKE '%MUPO%')
) n
ORDER BY q.match_class, q.has_subscription DESC, q.[bib#];
```

**Pre-2017 SQL Server:** `STRING_AGG` requires SQL Server 2017+. On an older
engine, replace the second `OUTER APPLY` with the `FOR XML PATH` form:

```sql
OUTER APPLY (
    SELECT STUFF((
        SELECT ' | ' + pp.text
        FROM bib pp
        WHERE pp.[bib#] = q.[bib#] AND pp.tag = '590'
          AND pp.text LIKE '%purchase%'
          AND (pp.text LIKE '%ProQuest%'
               OR pp.text COLLATE Latin1_General_CS_AS LIKE '%SUPO%'
               OR pp.text COLLATE Latin1_General_CS_AS LIKE '%MUPO%')
        ORDER BY pp.tagord
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, '') AS purchase_590
) n
```

`purchase_590` is a convenience column for eyeballing what matched; the delete
does not depend on it. If `FOR XML PATH` chokes on the `CHAR(30)`/`CHAR(31)`
control characters in `bib.text`, drop the column and verify with Query B.

---

## Query B — Detail / Verification (Read-Only)
**One row per matching `590` tag** on a qualifying bib. Shows every ProQuest-,
purchase-, subscription-, or DDA-bearing `590` so the classification can be
audited. Row count exceeds the record count — expected.

```sql
WITH ebk AS (
        SELECT DISTINCT [bib#] FROM item_with_title WHERE collection = 'EBK'
),
qual AS (
        SELECT e.[bib#],
            CASE WHEN EXISTS (
                     SELECT 1 FROM bib s
                     WHERE s.[bib#] = e.[bib#] AND s.tag = '590'
                       AND s.text LIKE '%ProQuest%' AND s.text LIKE '%purchase%')
                 THEN 'STRICT' ELSE 'BROADENED_ONLY' END AS match_class
        FROM ebk e
        WHERE EXISTS (
                SELECT 1 FROM bib p
                WHERE p.[bib#] = e.[bib#] AND p.tag = '590'
                  AND p.text LIKE '%purchase%'
                  AND (p.text LIKE '%ProQuest%'
                       OR p.text COLLATE Latin1_General_CS_AS LIKE '%SUPO%'
                       OR p.text COLLATE Latin1_General_CS_AS LIKE '%MUPO%'))
          AND NOT EXISTS (
                SELECT 1 FROM bib d
                WHERE d.[bib#] = e.[bib#] AND d.tag = '590'
                  AND d.text COLLATE Latin1_General_CS_AS LIKE '%DDA%')
)
SELECT q.[bib#] AS [bib#], q.match_class AS [match_class],
       b.tag AS [tag], b.text AS [text]
FROM qual q
INNER JOIN bib b ON b.[bib#] = q.[bib#] AND b.tag = '590'
ORDER BY q.[bib#], b.tagord;
```

---

## Query C — Both Counts (Read-Only, run this first)
Answers "how many strict vs. broadened, and how many carry a subscription."

```sql
WITH ebk AS (
        SELECT DISTINCT [bib#] FROM item_with_title WHERE collection = 'EBK'
),
qual AS (
        SELECT e.[bib#],
            CASE WHEN EXISTS (
                     SELECT 1 FROM bib s
                     WHERE s.[bib#] = e.[bib#] AND s.tag = '590'
                       AND s.text LIKE '%ProQuest%' AND s.text LIKE '%purchase%')
                 THEN 'STRICT' ELSE 'BROADENED_ONLY' END AS match_class,
            CASE WHEN EXISTS (
                     SELECT 1 FROM bib sub
                     WHERE sub.[bib#] = e.[bib#] AND sub.tag = '590'
                       AND sub.text LIKE '%subscription%')
                 THEN 1 ELSE 0 END AS has_sub
        FROM ebk e
        WHERE EXISTS (
                SELECT 1 FROM bib p
                WHERE p.[bib#] = e.[bib#] AND p.tag = '590'
                  AND p.text LIKE '%purchase%'
                  AND (p.text LIKE '%ProQuest%'
                       OR p.text COLLATE Latin1_General_CS_AS LIKE '%SUPO%'
                       OR p.text COLLATE Latin1_General_CS_AS LIKE '%MUPO%'))
          AND NOT EXISTS (
                SELECT 1 FROM bib d
                WHERE d.[bib#] = e.[bib#] AND d.tag = '590'
                  AND d.text COLLATE Latin1_General_CS_AS LIKE '%DDA%')
)
SELECT
    match_class                         AS [match_class],
    COUNT(*)                            AS [bibs],
    SUM(has_sub)                        AS [with_subscription_590]
FROM qual
GROUP BY match_class
WITH ROLLUP
ORDER BY GROUPING(match_class), match_class;
```

The `WITH ROLLUP` line (`match_class = NULL`) is the grand total = the full-list
record count. Compare `STRICT` against ~2,019 and the total against ~2,400.
`with_subscription_590` flags the deletion hazard in each class.

---

## Title parsing (`245$a`)
Reused verbatim from `590-ebk-049-dda-not-purchased-report`. `bib.text` stores a
MARC field's subfields delimited by `CHAR(31)`, with an optional trailing
`CHAR(30)`: `CHAR(31)+'a'+<title>+CHAR(31)+'c'+<author>…`. The `OUTER APPLY`
locates the `$a` delimiter, takes the text up to the next `CHAR(31)`/`CHAR(30)`
(or end of string), and strips one trailing ISBD punctuation mark
(`/ : ; , = .`) plus spaces. Horizon splits `245`s over 255 chars across multiple
`bib` rows (incrementing `tagord`); the lowest-`tagord` segment is used, so such
titles truncate to the first segment (rare for `245`). `OUTER APPLY` (not `CROSS
APPLY`) keeps a qualifying bib even when its `245$a` cannot be parsed (`title`
NULL) — the report never silently hides a record slated for deletion.

## Coverage note (item-side EBK definition)
"Is EBK" is read from `item_with_title`, so a bib that has lost its item rows
would not appear. A one-time sanity count (bibs matching the `590` rule with an
`EBK` `049` tag but no EBK item) returned **0** in the last run, confirming the
item-side definition is complete. Re-run it if the catalog changes materially:

```sql
SELECT COUNT(*) AS [ebk_049_bibs_with_no_ebk_item]
FROM (SELECT DISTINCT b049.[bib#] FROM bib b049
      WHERE b049.tag = '049' AND b049.text LIKE '%EBK%'
        AND EXISTS (SELECT 1 FROM bib p WHERE p.[bib#] = b049.[bib#]
                    AND p.tag = '590' AND p.text LIKE '%purchase%'
                    AND (p.text LIKE '%ProQuest%'
                         OR p.text COLLATE Latin1_General_CS_AS LIKE '%SUPO%'
                         OR p.text COLLATE Latin1_General_CS_AS LIKE '%MUPO%'))) z
WHERE NOT EXISTS (SELECT 1 FROM item_with_title i
                  WHERE i.[bib#] = z.[bib#] AND i.collection = 'EBK');
```

## Notes and edge cases
- A single `590` with both `ProQuest` and `purchase` makes a bib `STRICT`; it
  still appears once in Query A.
- Query A / Query C row counts are authoritative for the record count. Query B's
  row count is intentionally larger (one row per `590`).
- `ORDER BY q.match_class, q.has_subscription DESC` groups `BROADENED_ONLY` and
  floats the subscription-bearing hazards to the top of their group for review.
- `tagord` is order-only (and used in the title parser); not an output column.

---

## Appendix: MUPO / SUPO and the duplicate-record cleanup (deferred)
A related but separate problem: the catalog is believed to hold **duplicate
ProQuest records** for the same title. The original framing was "the subscription
record is MUPO, the owned record is SUPO — remove the MUPO one."

**The data contradicts that framing.** A discovery query located the codes, and
inspection of the removal-report output shows:

- `MUPO` and `SUPO` are **both purchase license models** (Multi-User / Single-User
  Purchase Option). `MUPO` appears on hundreds of **owned** perpetual-access
  purchase notes:
  `aProQuest Ebook Central perpetual access purchase; MUPO; autopurchase`.
  Deleting every `MUPO` record would delete owned books.
- The **true** subscription marker is the literal phrase `subscription`
  (`aProQuest LibCentral subscription; MUPO; …`) — and note it too can carry
  `MUPO`. So `MUPO` cannot discriminate subscription from purchase; only
  `subscription` vs `perpetual access purchase` can.
- Some "duplicates" are not two bibs at all but **one bib with two `590`s** (a
  purchase note and a subscription note on the same record). That changes the
  cleanup from "delete the MUPO bib" to "resolve two notes on one bib," a
  materially different operation.

The tag location, confirmed by discovery query:

```sql
SELECT tag, COUNT(*) AS hits
FROM bib
WHERE text LIKE '%MUPO%' OR text LIKE '%SUPO%'
GROUP BY tag ORDER BY hits DESC;
```

| tag | hits | | tag | hits |
| --- | --- | --- | --- | --- |
| **590** | **360,302** | | 776 | 1 |
| 245 | 9 | | 520 | 1 |
| 264 | 5 | | 500 | 1 |
| 536 | 3 | | 246 | 1 |

`MUPO`/`SUPO` live in the `590` tag. The 14 stray hits in `245`/`264`/`520`/`246`
(title, publication, summary fields — which cannot hold a license code) are
incidental substring matches, proving a bare `%MUPO%`/`%SUPO%` test is **not
self-validating** — the same class of bug as the `%DDA%`/`dDa` false positive.

**Open questions before any dedup query is written:**
1. Discriminator is `subscription` vs `perpetual access purchase`, **not**
   MUPO/SUPO.
2. Decide the "same title" key (ISBN `020`? OCLC `035`? `245$a` + author?).
3. Decide the two-`590s`-on-one-bib case: delete, or edit the record?

**No dedup query is specified or endorsed here.**
