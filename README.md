# Library-SQL-Toolbox
A collection of SQL scripts and data integrity solutions for Integrated Library Systems (ILS).

## Overview
This repository contains specialized SQL queries designed to audit and repair common data integrity issues in library databases (such as Horizon and Symphony). These scripts focus on MARC tag validation, item-to-bib synchronization, and batch cleanup operations.

## Repository Structure
Each solution is contained in its own directory with a dedicated README explaining the logic, the database challenges (such as Cartesian products), and the step-by-step implementation.

* **[049-duplicate-cleanup](./049-duplicate-cleanup)**: Fixes redundant 049 tags where multiple collections exist in the item table but are not represented in the bib record.
* **[590-ebk-purchase-dda-report](./590-ebk-purchase-dda-report)**: Read-only CSV report of the purchase and DDA `590` note tags on EBK-collection bib records.
* **[590-proquest-purchase-removal-report](./590-proquest-purchase-removal-report)**: Read-only `bib#` list of EBK records carrying both a ProQuest and a purchase `590` note, for handoff to Horizon's batch delete ahead of a fresh ProQuest ingest.

## Best Practices
1. **Always Audit First**: Every solution includes a `SELECT` statement to verify the targeted records before any changes are made.
2. **Backups**: Ensure a full database or table backup (e.g., `bib` or `item` table) is performed before executing `UPDATE` scripts.
3. **Transaction Blocks**: When possible, wrap updates in a transaction to allow for a rollback if the affected row count does not match the audit count.

## Prerequisites
- **Language**: T-SQL (SQL Server)
- **Permissions**: Administrative or Update access to the ILS database tables.

## License
Distributed under the MIT License. See `LICENSE` for more information.