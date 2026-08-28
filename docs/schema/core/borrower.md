# `borrower` — patrons

**Grain: `borrower#` — one row per patron.** Also uniquely indexed on
`second_id`. 44 columns.

> ## Personal data
>
> This table holds names, birth dates, home rooms, guardians, driver's licence
> numbers, password hashes, and LDAP distinguished names. **This repository is
> public.**
>
> - **Never commit query output from this table** — the `.gitignore` blocks
>   `*.csv`/`*.xlsx` for exactly this reason. Do not add an exception for it.
> - Do not paste result rows into a README, an issue, or a commit message.
> - Prefer aggregates and counts over row-level extracts wherever the question
>   allows it.
> - Report examples in documentation must use invented values, never real ones.

## Key columns

| Ord | Column | Type | Notes |
| --- | --- | --- | --- |
| 1 | `borrower#` | `int` | The grain |
| 2 | `location` | `code_type` | Home library → [`location.md`](location.md) |
| 3 | `btype` | `code_type` | Borrower type |
| 4 | `second_id` | `varchar` | Also unique — barcode/alternate ID |
| 5 | `name` | `null_string` | |
| 7 | `birth_date` | `smallint` | Horizon day count |
| 11 | `registration_date` | `smallint` | Horizon day count |
| 12 | `expiration_date` | `smallint` | Horizon day count |
| 13 | `creation_date` | `smallint` | Horizon day count |
| 14 | `last_update_date` | `smallint` | Horizon day count |
| 34 | `last_update_user_id` | `name_string` | Operator login |

Nine `smallint` date columns on this table alone — all day counts, all needing
`DATEDIFF(day, '1970-01-01', ...)`. See [conventions.md](../conventions.md#dates).

## Traps

**`borrower_bak` is not this table.** It is a local backup and may be arbitrarily
stale. Same for `borrower_bak`-style copies generally — check
[`index/all-objects.md`](../index/all-objects.md) before querying anything
`borrower`-adjacent.

**`name` vs `name_reconstructed` vs `legal_name`.** Three name columns (5, 24,
41) plus `legal_name_reconst` (42). They are not interchangeable. Look up which
one your report means rather than taking the shortest name.

**Barcodes live in two places.** `second_id` here, and the `borrower_barcode`
table (grain `borrower#, ord`) which holds multiple barcodes per patron. A join
to `borrower_barcode` **fans out**.

## Declared foreign keys

Unusually for this database, `borrower` has real FKs — to `grade`, `homeroom`,
and `teacher`. See [`index/joins.md`](../index/joins.md).

## Related

- [`circ.md`](circ.md) — current checkouts
