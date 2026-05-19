# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A documentation-first collection of T-SQL (SQL Server) scripts that audit and repair
data-integrity issues in Integrated Library System (ILS) databases — primarily
SirsiDynix Horizon, also Symphony. There is **no build, test, lint, or run tooling**.
The SQL is not executed here; it is delivered as documentation to be run by a DBA
against a live ILS database. "Running tests" means a human reviewing the SQL logic
and running the audit query against a real database.

## Structure convention

Each fix is a self-contained directory whose `README.md` is the deliverable. The
top-level `README.md` is an index — when adding a new solution, add a directory with
its own `README.md` and link it from the top-level `README.md`'s Repository Structure
list.

Every solution README must follow the same two-step structure, in this order:

1. **The Problem** — including the schema reason it is hard (see Cartesian product below).
2. **Step 1: The Audit** — a `SELECT` that lists exactly the rows the update will
   change, showing current value beside proposed new value.
3. **Step 2: The Update** — an `UPDATE` whose `FROM`/`JOIN` clauses are identical to
   the audit query's, so the affected row set provably matches what was audited.

The audit `SELECT` and the update `UPDATE` must target the same rows via the same
joins/subqueries. Diverging them breaks the core safety guarantee of this repo.

**Read-only report exception:** a solution that only *reports* data (a `SELECT`
with no `UPDATE`) has no audit/update split. Such a README uses a single
**The Report (Read-Only)** section instead of the Audit/Update steps, and states
that no backup or transaction is required. See `590-ebk-purchase-dda-report/`.

## Horizon schema knowledge required to write correct scripts

- `bib` and `item` are both children of `bib#` but have **no direct key linking a
  specific item row to a specific tag row**. Joining them is many-to-many and
  produces a Cartesian product (2 items × 2 tags = 4 rows). Scripts must collapse
  this with aggregation/`DISTINCT`/`EXISTS`, never a naive join.
- MARC subfield text stored in `bib.text` uses control characters, not literal
  pipes: `CHAR(31)` is the subfield delimiter, `CHAR(30)` is the field terminator.
  Write these as `CHAR(31)+'a'+value+CHAR(30)`; use a human-readable `'|a'+value`
  column only for display in audit output.
- To change one of several same-`tag` rows for a `bib#`, isolate it by `tagord`
  (e.g. `MAX(tagord)` to target the later duplicate while preserving the first).
  `HAVING COUNT(*) = N AND MIN(text) = MAX(text)` is the idiom for "N identical tags".

## Non-negotiable conventions for any UPDATE script

- Ship the audit `SELECT` first and state that it must be run and its row count
  recorded before the `UPDATE`.
- State explicitly that a `bib`/`item` table (or full DB) backup is required first.
- Where the engine allows, wrap the `UPDATE` in a transaction so the row count can
  be checked against the audit before commit.
