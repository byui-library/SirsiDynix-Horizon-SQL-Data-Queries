# ProQuest Purchase 590 Removal Report — Design

Date: 2026-07-14
Status: Approved

## Goal

Identify the SirsiDynix Horizon ebook records carrying **both** a `ProQuest` and
a `purchase` `590` (local note) tag, and emit their `bib#` list so those records
can be removed from the collection ahead of a fresh ingest.

Context: a complete export of all owned ProQuest (Ebook Central) titles will be
loaded into Horizon. That load both refreshes the records already in the catalog
and adds owned titles that were never there. The existing ProQuest purchase
records must be pulled first. Expected magnitude: **~2,400 records**.

## Scope

This report **does not delete anything**. Horizon spreads one record across
`bib`, `item`, and several dependent index/control tables; a raw SQL `DELETE`
would orphan rows in tables this repo does not model. The deliverable is a
read-only `bib#` list handed to Horizon's own batch-delete utility, which
performs the referential cleanup correctly.

The MUPO/SUPO duplicate-record cleanup is a **separate, deferred problem**. Only
its field location is recorded here (see Appendix); no dedup query is designed.

## Requirements

1. A bib qualifies when it has an **EBK item** and some `590` containing
   `ProQuest` **and** some `590` containing `purchase` (the broad "any 590"
   rule).
2. Each qualifying bib is labelled `match_type`:
   - `SAME_ROW` — at least one single `590` contains **both** words.
   - `CROSS_ROW_ONLY` — the words appear only in **separate** `590` rows.
3. Ship **two** queries:
   - **Query A (handoff):** one row per bib. Row count == record count.
     Columns: `bib#`, `title`, `match_type`, `notes_590`.
   - **Query B (detail):** one row per matching `590` tag, for verification.
     Columns: `bib#`, `title`, `match_type`, `tag`, `text`.
4. `title` = subfield `a` of the bib's `245`, cleaned/trimmed. A qualifying bib
   with no parseable `245$a` still appears, with `title` NULL (`OUTER APPLY`).
5. Read-only `SELECT`s. No backup, no transaction.
6. Deliver as CSV (SSMS → *Save Results As…*).

## Decisions (from brainstorming)

- **Match rule:** report **both** counts rather than pick one. Qualify on the
  broad rule, then label `SAME_ROW` / `CROSS_ROW_ONLY` so the strict rule's
  count is a subset the user can read directly off the same result set and
  compare against the ~2,400 expectation.
- **Removal method:** read-only `bib#` list only. No `DELETE`, no suppression
  `UPDATE`. Horizon's batch delete owns the referential cleanup.
- **Scope:** limited to EBK ebooks. Guards against an unrelated non-ebook record
  that happens to mention both words being swept into a ~2,400-record deletion.
- **EBK source:** the **item** side — `DISTINCT [bib#] FROM item_with_title
  WHERE collection = 'EBK'` — carried over from `590-ebk-purchase-dda-report`.
  Chosen over the `049` tag. **This has a known blind spot** (see Risks).
- **Report shape:** both queries (handoff + detail), per requirement 3.
- **Match strictness:** case-insensitive substring, default collation, for both
  `%ProQuest%` and `%purchase%` (see Case sensitivity).
- **`STRING_AGG` vs `FOR XML PATH`:** ship `STRING_AGG` as primary with a
  `FOR XML PATH` fallback block, so the query runs without first pinning down
  the server's SQL Server version.
- **MUPO/SUPO dedup:** deferred. Appendix records the field location only.

## The Cartesian product

`bib` and `item_with_title` are both keyed by `bib#` with a one-to-many
relationship — a bib has many `590` rows and may have many item rows. A raw join
multiplies every `590` row by the EBK-item count, inflating the row count and
corrupting the record count that drives the deletion.

Both queries collapse the item side to a `DISTINCT [bib#]` derived table (`ebk`
CTE) and test the `590` conditions with per-bib `EXISTS` subqueries, so the item
table can never multiply the output. Query A additionally collapses the matching
`590`s into a single `notes_590` cell via an aggregate in an `OUTER APPLY`,
guaranteeing one row per bib.

## Case sensitivity

Both `%ProQuest%` and `%purchase%` are **case-insensitive** (default collation).

- `purchase` **must** stay case-insensitive so a note written `Purchased…` /
  `Purchase…` with a leading capital is still caught. A missed purchase note
  means a record wrongly survives the purge.
- Neither string is exposed to the false-positive trap that forced
  `COLLATE Latin1_General_CS_AS` on `%DDA%` in
  `590-ebk-049-dda-not-purchased-report`. That bug required a lowercase MARC
  subfield **code** abutting content to forge the acronym (`$d` + `Da…` →
  `dDa`). Subfield codes are a single character, so no code/content boundary can
  manufacture `proquest` or `purchase`.

## Risks

**1. The item-side EBK definition has a blind spot.** Because "is EBK" is read
from `item_with_title`, a bib that has lost its item rows **will not appear** in
Query A. Such a record would survive the purge and then collide with the
freshly-ingested records.

Mitigation: **Query C**, a count-only sanity check, reports how many bibs match
the `590` rule and carry an `EBK` `049` tag but have **no EBK item**.

- `0` → the item-side definition is provably complete; proceed.
- `> 0` → that many records are invisible to Query A. Widen the rule to
  `EBK 049 OR EBK item` before deleting, or accept the miss knowingly.

Query C must be run **before** Query A's output is trusted.

**2. `CROSS_ROW_ONLY` records are ambiguous.** A bib holding a ProQuest DDA note
*and* an unrelated purchase note from a different vendor satisfies the broad
rule but is not necessarily a ProQuest purchase record. Query A orders by
`match_type` so this group is a contiguous, reviewable (or sliceable) block in
the CSV. It should be reviewed, not deleted blind.

**3. `FOR XML PATH` and control characters.** `bib.text` embeds `CHAR(30)` /
`CHAR(31)`, which are not legal XML 1.0 characters. If the fallback
`notes_590` aggregation chokes on them, drop the `notes_590` column and use
Query B for verification instead. `notes_590` is a convenience column only; the
delete does not depend on it.

## Title parsing (`245$a`)

Reused verbatim from `590-ebk-049-dda-not-purchased-report`. `bib.text` stores a
MARC field's subfields delimited by `CHAR(31)`, with an optional trailing
`CHAR(30)`: `CHAR(31)+'a'+<title>+CHAR(31)+'c'+<author>…`. The `OUTER APPLY`
locates the `$a` delimiter, takes the text up to the next `CHAR(31)`/`CHAR(30)`
(or end of string), and strips one trailing ISBD punctuation mark (`/ : ; , = .`)
plus spaces.

Horizon splits MARC fields longer than 255 chars across multiple `bib` rows
(same tag, incrementing `tagord`); the lowest-`tagord` `245` segment is used, so
over-255-char titles truncate to the first segment (rare for `245`).

`OUTER APPLY` (not `CROSS APPLY`) keeps a qualifying bib in the report even when
its `245$a` cannot be parsed — the report **never silently hides a matching
record**, which is critical when the output drives a deletion.

## Assumptions / edge cases

1. A single `590` containing both words qualifies the bib as `SAME_ROW`; the bib
   still appears exactly once in Query A.
2. Query A's row count is the authoritative record count. Query B's row count
   exceeds it whenever a bib has more than one matching `590` — expected.
3. `tagord` is used only for ordering and inside the title parser; it is not an
   output column.
4. Read-only `SELECT`s; no backup or transaction wrapper needed.

## Deliverable / repo placement

New directory `590-proquest-purchase-removal-report/` containing a `README.md`
(Problem → match rule → Query A → Query B → Query C → title parsing → notes →
appendix), linked from the top-level `README.md` "Repository Structure" index.

Read-only report — uses the **The Report (Read-Only)** section pattern from
`CLAUDE.md`'s read-only report exception. No `UPDATE`, so the audit / backup /
transaction conventions do not apply to this report. They *do* apply to whatever
tool consumes the `bib#` list.

## Appendix: where MUPO / SUPO live (deferred work)

Related deferred problem: the catalog holds **duplicate ProQuest records** for
the same title — typically a **subscription** record (`MUPO`) alongside an
**owned** record (`SUPO`). The `MUPO` record is the one to remove.

A discovery query established which tag carries these values:

```sql
SELECT tag, COUNT(*) AS hits
FROM bib
WHERE text LIKE '%MUPO%' OR text LIKE '%SUPO%'
GROUP BY tag
ORDER BY hits DESC;
```

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

**Conclusion: `MUPO`/`SUPO` are carried in the `590` tag** — the same local-note
tag used throughout this repo, so the dedup can reuse the per-bib `EXISTS`
pattern.

Two constraints for that future design:

1. **The long tail is a false-positive warning.** `245` (title), `264`
   (publication), `520` (summary) and `246` cannot hold a license code — those
   14 hits are incidental substring matches. Same class of bug as the `%DDA%` /
   `dDa` false positive. A bare `%MUPO%` / `%SUPO%` substring test is therefore
   **not self-validating**; the dedup must anchor on ProQuest `590` context.
2. **360,302 counts `590` *rows*, not bibs**, and combines `MUPO` with `SUPO`.
   The dedup needs the `MUPO`/`SUPO` split **per bib**, plus a decided key for
   "same title" (ISBN `020`? OCLC `035`? `245$a` + author?) — neither of which
   this count provides.

Both are open questions. **No dedup query is specified or endorsed.**
