# Acquisitions — `po`, `po_line`, `vendor`, `invoice`

Purchase orders, their lines, vendors, and invoices. Relevant to any question
about what was ordered, from whom, and at what price.

> The ProQuest work in this repo concerns purchase *notes in MARC `590` tags*,
> which is cataloguing metadata — it never touches these tables. "Purchased" in a
> `590` note and a row in `po_line` are independent facts and can disagree.

## Grain

| Object | Grain | One row per |
| --- | --- | --- |
| `po` | `po#` (also unique on `po_number`) | purchase order |
| `po_line` | `po#, line` | line on an order |
| `vendor` | `vendor#` | vendor |
| `invoice` | **VIEW, no unique index** | see below |

`po` → `po_line` **fans out**: one order has many lines. Collapse with `EXISTS`
or aggregate when you want one row per order.

## `po` — purchase orders (24 columns)

| Ord | Column | Notes |
| --- | --- | --- |
| 1 | `po#` | The grain |
| 2 | `po_number` | `name_string`, also unique — the human-facing number |
| 4 | `vendor#` | → `vendor` |
| 8 | `location` / 14 `collection` / 15 `itype` | `code_type` defaults applied to created items |
| 19 | `creation_date` | Horizon day count |
| 21 | `completion_date` | Horizon day count |

Note **two** unique keys: `po#` (internal) and `po_number` (as printed). Join on
`po#`; report `po_number`.

## `po_line` — order lines (35 columns)

| Ord | Column | Notes |
| --- | --- | --- |
| 1,2 | `po#`, `line` | The grain |
| 4 | `bib#` | Link to the catalogue record — **no FK** |
| 6,7,8 | `isbn`, `issn`, `ismn` | Plain `varchar`, not normalised |
| 9 | `title` | Order-time title, **not** the catalogue's |
| 20 | `unit_price` | `money` |
| 28 | `polstat` | `code_type` — line status |

Two traps worth stating:

**`po_line.title` is what was typed on the order**, not the title in the
catalogue. It can differ from `title.processed` or `245$a` in spelling,
punctuation, and completeness. For the catalogue's title, join through `bib#` —
see [`title.md`](title.md).

**`po_line.bib#` is nullable and unenforced.** An order line may have no
catalogue record at all. Use `LEFT JOIN` to `bib`/`title`, or the lines you most
want to find — ordered but never catalogued — disappear from the report.

## `vendor` (29 columns)

Grain `vendor#`. `vendor` (ord 2) is the short code; `name` (ord 3) is the full
name. Claim configuration lives here too (`first_claim_delay`, `claim_interval`,
`max_claims` — ords 19–21).

## `invoice` — note this is a VIEW

`invoice` is a **view**, not a table, and has no unique index of its own. Its
grain follows the underlying tables; confirm before assuming one row per
`invoice#`. Columns include `statement#`, `vendor#`, `amount`,
`amount_remaining`, and four Horizon day-count dates (`statement_date`,
`creation_date`, `completion_date`, `approve_date`).

## Dates

Every date column across these tables is a `smallint` Horizon day count with no
time component — `creation_date`, `completion_date`, `last_order_date`,
`next_renewal_date`, `statement_date`, `approve_date`. Filter with
`DATEDIFF(day, '1970-01-01', ...)`; see
[conventions.md](../conventions.md#dates).

## Related

- [`bib.md`](bib.md) — what `po_line.bib#` points at
- Full column lists: grep `horizon-schema/all_tables_all_views.csv`
