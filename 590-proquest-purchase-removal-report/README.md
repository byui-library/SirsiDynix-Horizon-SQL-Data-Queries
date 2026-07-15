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
2. It has some `590` containing `ProQuest`.
3. It has some `590` containing `purchase`.

The two words may be in **one `590` or spread across two (or more)** — it does
not matter which. Multiple `590`s record a title's status history: a record with
a `DDA` note in one `590` and a `purchase` note in another was added as a DDA
title and later purchased. Such records **are** in scope and are kept — there is
**no `DDA` exclusion**.

Last run: **2,117 bibs** qualify.

### Informational columns (do not filter the delete)
Each qualifying bib carries three descriptive columns so the delete list can be
reviewed without a second query:

| Column | Meaning |
| --- | --- |
| `match_type` | `SAME_ROW` = one `590` holds both words; `CROSS_ROW` = the words are split across separate `590`s. Purely descriptive — both are in scope. |
| `has_dda` | `Y` = the record also has a `DDA` `590` (the DDA-then-purchased progression). 95 in the last run. Still removed. |
| `has_subscription` | `Y` = the record also has a live `ProQuest LibCentral subscription` `590`. **Deletion hazard** — see below. 6 in the last run. |

### Deletion hazard: `has_subscription`
A few bibs carry **both** a purchase `590` and a live
`ProQuest LibCentral subscription` `590` on the same record. Deleting such a bib
removes the subscription access too, not just the stale purchase record. Query A
floats these to the top of the list (`ORDER BY has_subscription DESC`).
**Recommendation: pull the `has_subscription = Y` rows out of the delete batch**
and handle them with the duplicate-record cleanup (see Appendix), rather than
purging them blind.

### Coverage note — records with no literal "ProQuest"
This rule requires the literal word `ProQuest` in some `590`. A record whose
`590`s only ever say `Perpetual access ebook purchase; SUPO` — with no `ProQuest`
anywhere — is **not** matched. Many such records are still caught here because
they carry a ProQuest DDA note in a second `590`, but a record with no ProQuest
`590` at all will be missed. If, after the reload, duplicates remain from records
like that, widen condition 2 to also accept a `590` containing `purchase` with
`SUPO`/`MUPO` (ProQuest's own purchase codes). That broaden was measured at
~7,934 bibs total and is **not** applied here; it is noted only as the lever to
pull if literal matching proves too narrow.

### Case sensitivity
- `%ProQuest%` and `%purchase%` — **case-insensitive** (default collation).
  `purchase` must stay case-insensitive to catch `Purchased…`; `ProQuest` to
  catch any `PROQUEST`/`Proquest` variant.
- `%DDA%` (the `has_dda` flag) — **case-sensitive** (`COLLATE
  Latin1_General_CS_AS`). MARC subfield codes are lowercase, so an uppercase
  acronym can never be forged at a code/content boundary; a case-insensitive
  `%DDA%` also matched the `dDa` sequence where a `$d` subfield code abuts
  content beginning `Da…`. This guard was proven necessary in
  `590-ebk-049-dda-not-purchased-report`. (The flag is descriptive only, but is
  kept accurate.)

---

## Query A — The Removal List (Read-Only)
**One row per bib.** Columns: `bib#`, `title`, `match_type`, `has_dda`,
`has_subscription`. Run in SSMS, then right-click the grid →
**Save Results As… → CSV**.

This primary form uses **no `STRING_AGG`**, so it runs on any SQL Server version
and any database compatibility level — confirmed against the live Horizon
database, whose compat level is below where `STRING_AGG` is available. For the
`590` note text on any record, use **Query B**. An optional `notes_590` column
for engines that support `STRING_AGG` (SQL Server 2017+, compat 110+) is shown
after the query.

```sql
WITH ebk AS (                        -- collapse the item side: one row per bib
        SELECT DISTINCT [bib#]
        FROM item_with_title
        WHERE collection = 'EBK'
),
qual AS (
        SELECT
            e.[bib#],
            CASE WHEN EXISTS (       -- one 590 holding BOTH words
                     SELECT 1 FROM bib s
                     WHERE s.[bib#] = e.[bib#] AND s.tag = '590'
                       AND s.text LIKE '%ProQuest%' AND s.text LIKE '%purchase%')
                 THEN 'SAME_ROW' ELSE 'CROSS_ROW' END AS match_type,
            CASE WHEN EXISTS (       -- record also has a DDA note
                     SELECT 1 FROM bib d
                     WHERE d.[bib#] = e.[bib#] AND d.tag = '590'
                       AND d.text COLLATE Latin1_General_CS_AS LIKE '%DDA%')
                 THEN 'Y' ELSE '' END AS has_dda,
            CASE WHEN EXISTS (       -- record also has a subscription note
                     SELECT 1 FROM bib sub
                     WHERE sub.[bib#] = e.[bib#] AND sub.tag = '590'
                       AND sub.text LIKE '%subscription%')
                 THEN 'Y' ELSE '' END AS has_subscription
        FROM ebk e
        WHERE EXISTS (               -- some 590 contains ProQuest
                SELECT 1 FROM bib p
                WHERE p.[bib#] = e.[bib#] AND p.tag = '590'
                  AND p.text LIKE '%ProQuest%')
          AND EXISTS (               -- some 590 contains purchase
                SELECT 1 FROM bib u
                WHERE u.[bib#] = e.[bib#] AND u.tag = '590'
                  AND u.text LIKE '%purchase%')
)
SELECT
    q.[bib#]           AS [bib#],
    t.title            AS [title],
    q.match_type       AS [match_type],
    q.has_dda          AS [has_dda],
    q.has_subscription AS [has_subscription]
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
ORDER BY q.has_subscription DESC, q.match_type, q.[bib#];
```

### Optional `notes_590` column (SQL Server 2017+, compat 110+ only)
The primary query omits the matching-`590` text so it runs everywhere; verify
note text with **Query B**. If your engine has `STRING_AGG` **and** the database
compatibility level is 110+, you can add the notes inline. Put `n.notes_590 AS
[notes_590],` back in the `SELECT` list and add this `OUTER APPLY` after the
title block:

```sql
OUTER APPLY (                        -- the matching 590(s), collapsed to one cell
    SELECT STRING_AGG(pp.text, ' | ') WITHIN GROUP (ORDER BY pp.tagord) AS notes_590
    FROM bib pp
    WHERE pp.[bib#] = q.[bib#] AND pp.tag = '590'
      AND (pp.text LIKE '%ProQuest%' OR pp.text LIKE '%purchase%')
) n
```

Failure modes seen on the live database (both avoided by the primary query):
`STRING_AGG` at compat level below 110 rejects the ordering clause
(`The function 'STRING_AGG' may not have a WITHIN GROUP clause.`); at a still
lower level the function is unavailable entirely
(`'STRING_AGG' is not a recognized built-in function name.`). `FOR XML PATH` is
the usual pre-2017 substitute but tends to fail here because `590` text embeds
`CHAR(31)`/`CHAR(30)` control characters that are illegal in XML. When in doubt,
use the primary query and Query B.

---

## Query B — Detail / Verification (Read-Only)
**One row per `590` tag** on a qualifying bib — every `590`, so a title's full
status progression (DDA → purchase, subscription, etc.) is visible. Row count
exceeds the record count — expected.

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
                 THEN 'SAME_ROW' ELSE 'CROSS_ROW' END AS match_type
        FROM ebk e
        WHERE EXISTS (SELECT 1 FROM bib p WHERE p.[bib#] = e.[bib#]
                        AND p.tag = '590' AND p.text LIKE '%ProQuest%')
          AND EXISTS (SELECT 1 FROM bib u WHERE u.[bib#] = e.[bib#]
                        AND u.tag = '590' AND u.text LIKE '%purchase%')
)
SELECT q.[bib#] AS [bib#], q.match_type AS [match_type],
       b.tag AS [tag], b.text AS [text]
FROM qual q
INNER JOIN bib b ON b.[bib#] = q.[bib#] AND b.tag = '590'
ORDER BY q.[bib#], b.tagord;
```

---

## Query C — Counts (Read-Only)
The delete-list size plus the informational flag totals.

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
                 THEN 'SAME_ROW' ELSE 'CROSS_ROW' END AS match_type,
            CASE WHEN EXISTS (SELECT 1 FROM bib d WHERE d.[bib#] = e.[bib#]
                     AND d.tag = '590'
                     AND d.text COLLATE Latin1_General_CS_AS LIKE '%DDA%')
                 THEN 1 ELSE 0 END AS has_dda,
            CASE WHEN EXISTS (SELECT 1 FROM bib sub WHERE sub.[bib#] = e.[bib#]
                     AND sub.tag = '590' AND sub.text LIKE '%subscription%')
                 THEN 1 ELSE 0 END AS has_sub
        FROM ebk e
        WHERE EXISTS (SELECT 1 FROM bib p WHERE p.[bib#] = e.[bib#]
                        AND p.tag = '590' AND p.text LIKE '%ProQuest%')
          AND EXISTS (SELECT 1 FROM bib u WHERE u.[bib#] = e.[bib#]
                        AND u.tag = '590' AND u.text LIKE '%purchase%')
)
SELECT
    match_type       AS [match_type],
    COUNT(*)         AS [bibs],
    SUM(has_dda)     AS [with_dda_590],
    SUM(has_sub)     AS [with_subscription_590]
FROM qual
GROUP BY match_type
WITH ROLLUP
ORDER BY GROUPING(match_type), match_type;
```

The `WITH ROLLUP` line (`match_type = NULL`) is the grand total = the delete-list
record count. Last run: **2,117** total (`SAME_ROW` 2,028, `CROSS_ROW` 89);
`with_dda_590` 95; `with_subscription_590` 6.

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
`EBK` `049` tag but no EBK item) returned **0** in an earlier run, confirming the
item-side definition is complete. Re-run it if the catalog changes materially:

```sql
SELECT COUNT(*) AS [ebk_049_bibs_with_no_ebk_item]
FROM (SELECT DISTINCT b049.[bib#] FROM bib b049
      WHERE b049.tag = '049' AND b049.text LIKE '%EBK%'
        AND EXISTS (SELECT 1 FROM bib p WHERE p.[bib#] = b049.[bib#]
                    AND p.tag = '590' AND p.text LIKE '%ProQuest%')
        AND EXISTS (SELECT 1 FROM bib u WHERE u.[bib#] = b049.[bib#]
                    AND u.tag = '590' AND u.text LIKE '%purchase%')) z
WHERE NOT EXISTS (SELECT 1 FROM item_with_title i
                  WHERE i.[bib#] = z.[bib#] AND i.collection = 'EBK');
```

## Notes and edge cases
- Both `match_type` values (`SAME_ROW`, `CROSS_ROW`) are in scope; the column is
  descriptive, not a filter.
- Query A / Query C row counts are authoritative for the record count. Query B's
  row count is intentionally larger (one row per `590`).
- `ORDER BY has_subscription DESC` floats the subscription-bearing hazards to the
  top of Query A for review before deletion.
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
