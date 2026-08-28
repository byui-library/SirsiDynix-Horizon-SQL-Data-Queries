# Library-SQL-Toolbox

A collection of SQL scripts and data-integrity solutions for Integrated Library
Systems (ILS) — primarily SirsiDynix Horizon on SQL Server, also Symphony.

Each solution audits or repairs a specific data problem: MARC tag validation,
item-to-bib synchronisation, batch cleanup. The SQL is **not run from this
repository** — it is delivered as documentation for a DBA to execute against a
live database.

## Start here

| If you want to… | Go to |
| --- | --- |
| Write a query against this database | **[docs/schema/AGENTS.md](./docs/schema/AGENTS.md)** |
| Run an existing solution | its `README.md` under [solutions/](./solutions/) |
| Delete records in batch | [docs/killbib.md](./docs/killbib.md) + [tools/README.md](./tools/README.md) |
| Add a new solution | [docs/authoring-solution-docs.md](./docs/authoring-solution-docs.md) |

## Repository layout

```text
solutions/        one directory per solution — the deliverables
docs/
  schema/         the Horizon schema: rules, conventions, per-table pages
  killbib.md      Horizon's batch-delete utility: flags, limits, failure modes
  authoring-solution-docs.md
horizon-schema/   raw CSV schema exports — the source of truth for names
tools/            PowerShell: doc generators, delete-run scripts
```

## Schema reference

**Before writing a query, read [docs/schema/](./docs/schema/).** The full schema
of this Horizon database is exported and committed — **969 tables, 433 views,
14,103 columns** — along with documentation of the conventions that make it
tricky: integer dates, user-defined types, unique-index grain, and the
Cartesian-product hazard between `bib` and `item`.

* **[docs/schema/AGENTS.md](./docs/schema/AGENTS.md)** — rules for writing correct
  SQL here, with lookup recipes and a pre-flight checklist. Tool-neutral: it
  applies to any AI assistant and to people.
* **[docs/schema/conventions.md](./docs/schema/conventions.md)** — the schema-wide
  patterns, explained.
* **[docs/schema/core/](./docs/schema/core/)** — per-table pages for the tables in
  active use.
* **[horizon-schema/](./horizon-schema/README.md)** — the raw CSV exports these
  are built from.

**Never infer a table or column name.** Every name used here must be looked up.

## Solutions

Each lives in its own directory with a `README.md` explaining the problem, the
schema reason it is hard, and the step-by-step implementation.

* **[049-duplicate-cleanup](./solutions/049-duplicate-cleanup)** — fixes redundant `049` tags where multiple collections exist in the item table but are not represented in the bib record.
* **[590-ebk-purchase-dda-report](./solutions/590-ebk-purchase-dda-report)** — read-only report of the purchase and DDA `590` note tags on EBK-collection bib records.
* **[590-ebk-049-dda-not-purchased-report](./solutions/590-ebk-049-dda-not-purchased-report)** — read-only report of EBK records with a DDA `590` and no purchase note, identified by the bib's own `049` tag.
* **[590-proquest-purchase-removal-report](./solutions/590-proquest-purchase-removal-report)** — read-only `bib#` list of EBK records carrying both a ProQuest and a purchase `590` note, for handoff to Horizon's batch delete ahead of a fresh ProQuest ingest.
* **[590-proquest-new-by-creator-report](./solutions/590-proquest-new-by-creator-report)** — read-only report of bib records created by a given operator on a given day whose `590` notes mention ProQuest, plus the end-to-end delete-list build.

### Generated alongside each README

Never edit these directly — edit the `README.md` and re-run
`tools/Build-SolutionDocs.ps1`:

* `sql/NN-<slug>.sql` — each query as a runnable file. Open in SSMS and press F5.
* `runbook.html` — a copy-ready page with a copy button per query. Open it in a
  browser; GitHub shows `.html` as source rather than rendering it. See
  [docs/authoring-solution-docs.md](./docs/authoring-solution-docs.md).

## Adding a solution

```powershell
powershell -ExecutionPolicy Bypass -File tools\New-Solution.ps1 `
    -Name 245-missing-subfield-a -Type Report `
    -Summary "Bibs whose 245 has no subfield a."
```

Scaffolds the directory with a README in the required structure and adds the
index line above. `-Type Fix` produces the Audit/Update variant instead.

## Best practices

1. **Always audit first.** Every repair ships a `SELECT` that lists exactly the
   rows the `UPDATE` will change, and the `UPDATE` reuses identical
   `FROM`/`JOIN` clauses so the affected set provably matches what was reviewed.
2. **Backups.** A `bib`/`item` table or full-database backup before any
   `UPDATE`.
3. **Transactions.** Wrap updates so the row count can be checked against the
   audit before commit.
4. **Look every name up.** A guessed column name either fails loudly or silently
   returns the wrong rows.

## Prerequisites

- **Language**: T-SQL (SQL Server). This database's compatibility level is low —
  no `STRING_AGG`, `CONCAT`, `IIF`, or `FORMAT`.
- **Permissions**: read access for reports; update access for repairs.
- **Tooling** (optional): Windows PowerShell 5.1 for the generators and
  delete-run scripts in [tools/](./tools/README.md).

## License

Distributed under the MIT License. See `LICENSE` for more information.
