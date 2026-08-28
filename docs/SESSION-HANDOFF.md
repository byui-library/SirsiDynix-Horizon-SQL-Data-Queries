# Session handoff — 2026-08-27 / 28

State of play. Read this first; it says what is finished, what is genuinely
unresolved, and what to do next.

**Everything described here is committed.** The 2026-08-27 session's work — the
schema reference, the tooling, the reorganisation and the security pass — plus
the 2026-08-28 verification of the delete run.

Nothing has been **pushed**. `git log origin/master..HEAD` shows what is waiting.

---

## 1. The ProQuest delete — DONE

**Verified complete 2026-08-28.** All **6,790** bibs were deleted and no item
rows remained; both post-run checks returned 0. Recorded in
[`killbib.md`](killbib.md#verified-invocation).

The zero item count means that particular set contained no serials with issues
or predictions attached. Do not generalise that — KillBib skips such copies, so
a future list can leave items behind after a *successful* run.

### Server-side cleanup — DONE

**42 scratch tables dropped 2026-08-28, 0 failures**, using
[`db-scratch-table-cleanup`](../solutions/db-scratch-table-cleanup/README.md).
That swept up this job's delete lists along with years of accumulated scratch:
killbib lists from past runs, ISBN working sets, `del_*`/`tmp_*` copies, and
three stale patron-data backups holding roughly 530,000 records.

**Three tables were pulled off the candidate list as vendor**, not scratch:
`item_circ_renewal`, `bstat_group` and `sort_order`. All three had a
post-install `create_date` because something rebuilt them, which makes a vendor
table look local. The dependency check did not catch them — a standalone lookup
table has nothing referencing it. Step 1e of that solution exists because of
this, and is what separates the two.

The schema export was refreshed afterwards and matches the live database:
928 tables, 433 views, 13,949 columns.

**Dropping a delete list loses no audit trail** — that is the timestamped CSV in
`killbib-audit\`, written before anything was deleted.

---

## 2. What was completed

### Schema reference (new)

The full schema is exported and committed: **928 tables, 433 views, 13,949
columns** in `horizon-schema/`, with documentation in `docs/schema/`.
[`docs/schema/AGENTS.md`](schema/AGENTS.md) is the entry point — tool-neutral
rules for writing correct SQL here.

Findings worth not rediscovering:

- **Only 6 declared primary keys exist** in the whole database. Hundreds of
  indexes are *named* `PK_*` and are not. Grain comes from unique indexes.
- **941 `smallint` date columns across 294 tables** are day counts, not dates,
  with time in a separate `_time` column. The **`1970-01-01` epoch is verified**
  — proven with a weekday histogram, because a `MAX(create_date)` check cannot
  detect a one-day error.
- `bib` is one row per *tag*, `item` one row per *copy* — the Cartesian product
  this repo exists to guard against, now proven from the index export rather
  than asserted.

### KillBib documented from the tool itself

[`docs/killbib.md`](killbib.md) records version 7.61's actual `/?` output plus
five undocumented behaviours, each of which cost real time:

1. **`/t` truncates at 31 characters** — a 35-char name silently became 31 and
   failed with "Invalid object name". SQL Server allows 128, so nothing on the
   database side catches it.
2. **There is no dry-run.** `/w` proves bib rows are wiped with or without `/k`.
3. **It must run from its own install directory** or it dies silently with exit
   code `2147483647`.
4. **`/u` and `/r` are different identities** — SQL login vs Horizon login.
5. **`/l` is required** at this site.

### Tooling

Eight scripts in `tools/`, all documented in [`tools/README.md`](../tools/README.md):

| Script | Purpose |
| --- | --- |
| `Invoke-DeleteListRun.ps1` | the whole delete sequence, one command, ten steps |
| `Invoke-KillBib.ps1` | wraps the vendor binary |
| `Test-DeleteListPreflight.ps1` | four read-only checks |
| `Find-KillBib.ps1` | locates the executable; refuses to choose between installs |
| `HorizonSql.ps1` | shared SQL/validation helpers (dot-sourced) |
| `Build-SolutionDocs.ps1` | README → `sql/*.sql` + `runbook.html` |
| `Generate-SchemaDocs.ps1` | CSV exports → `docs/schema/index/` |
| `New-Solution.ps1` | scaffolds a new solution |
| `Test-Tools.ps1` | 64 tests, no database needed |

### Published runbook (Artifact)

The ProQuest solution's `runbook.html` was also published as a private Artifact:

<https://claude.ai/code/artifact/3ec00503-813c-4435-9e03-0bf951e19fde>

It is a copy of the generated page, so it goes stale whenever the README changes.
To refresh it, re-run `Build-SolutionDocs.ps1` and republish that same file to
that same URL. The URL is recorded here because it cannot be recovered from the
repository.

### Reorganisation

Solutions moved under `solutions/`; `horizon schema/` renamed to
`horizon-schema/` (the space needed quoting everywhere). All 110 internal links
verified resolving.

### Security pass

Real site identifiers were replaced with placeholders throughout — see the
"Never publish real site identifiers" section of `CLAUDE.md` for the table.
`tools/.redaction-denylist.txt` (gitignored) plus a check in `Test-Tools.ps1`
prevents them coming back.

**Accepted residual risk 1 — server name in history.** The real server name is
in the public git history at commit `d765f8e` (2026-07-17). A deliberate
decision was made not to rewrite history: it is a hostname rather than a
credential, it is already public, and force-pushing a public repo breaks clones
while GitHub still serves the old commit by SHA. No password was ever committed.

**Residual risk 2 — RESOLVED 2026-08-28.** The database held scratch tables
named after the staff member who created them, so a username appeared in the
schema export as *data*. Redacting the export was rejected — it exists so a grep
for a real object name finds it, and a doctored export would silently disagree
with the database, which is the exact class of error this repository guards
against.

The scratch-table cleanup dropped those tables at the source. The export was
refreshed, the username is gone, and the redaction guard's blind spots
(`horizon-schema/`, `docs/schema/index/`) have been removed — it scans
everything except frozen historical records again.

If a future export reintroduces such a name, fix it by renaming the table, not
by re-adding an exclusion.

---

## 3. Before committing

```powershell
powershell -ExecutionPolicy Bypass -File tools\Test-Tools.ps1
```

Expect **64 passed, 0 failed**. The suite includes the redaction guard, so a
real identifier that has crept back into a tracked file fails the run. Treat a
failure there as blocking — this repository is public.

---

## 4. Known-good next tasks

- **Nothing outstanding.** The delete run is verified, the scratch tables are
  dropped, and the schema export matches the live database.
- **Write the next solution** with the scaffold rather than by hand:

  ```powershell
  powershell -ExecutionPolicy Bypass -File tools\New-Solution.ps1 `
      -Name <dir-name> -Type Report -Summary "One line for the index."
  ```

- **Consider GitHub Pages** if the `runbook.html` pages should render for
  colleagues — GitHub shows `.html` as source otherwise. Trade-offs are in
  [`authoring-solution-docs.md`](authoring-solution-docs.md#enabling-github-pages-optional-one-time).

---

## 5. Things that will bite you if you forget them

- **Never guess a column name.** A report was written against `bib_control.creator`;
  the real column is `create_user`. Grep `horizon-schema/all_tables_all_views.csv`.
- **`STRING_AGG` does not exist** on this database's compatibility level, and
  `FOR XML PATH` fails on `bib.text` because of its control characters.
- **You cannot aggregate an `EXISTS`** — compute the flag in a derived table first.
- **Generated files are generated.** Never hand-edit `sql/*.sql` or
  `runbook.html`; edit the README and re-run `Build-SolutionDocs.ps1`.
- **The `590` filter is load-bearing.** The cataloguer runs batch loads but also
  creates the occasional record by hand without always recalling it. That filter
  is what keeps the hand-created records out of a delete — and it was *proven* to
  exclude real records, not assumed.
