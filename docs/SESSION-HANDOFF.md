# Session handoff — 2026-09-22

State of play. Read this first; it says what is finished, what is genuinely
unresolved, and what to do next.

---

## 0. Start here — one blocking issue

**`tools\Test-Tools.ps1` currently fails: 63 passed, 1 FAILED.** The failure is
the redaction guard, and it needs a decision before the next commit, because
this repository is public.

```powershell
powershell -ExecutionPolicy Bypass -File tools\Test-Tools.ps1
```

**What it is flagging.** Denylist **entry #7** — a 4-character value — appears
inside two local table names, which the generated index pages and the raw schema
export therefore carry:

```text
fix####Proxy        (12 chars)
fix####Redirect     (15 chars)
```

It matches as a **substring only, never as a standalone token**. Affected files:
`horizon-schema/all_tables_all_views.csv`, `horizon-schema/indexes_and_keys.csv`,
`docs/schema/index/all-objects.md`, `docs/schema/index/no-unique-index.md`.

**This is pre-existing and was not introduced by the last session's work.** All
four files are unchanged from `HEAD` and their content is already public. The
denylist grew from 5 entries to 7 between sessions, and entry #7 is what newly
trips the guard.

**The decision — one of two, and it is yours:**

| If entry #7 is… | Do this |
| --- | --- |
| **Not actually sensitive** (an institution abbreviation is already public — the GitHub org name and `LICENSE` both carry it) | Remove it from `tools/.redaction-denylist.txt`. Over-broad short entries cause false positives exactly like this. |
| **Genuinely sensitive** | **Rename the two `fix*` tables** in the database and re-export. Do **not** add an exclusion to the guard and do **not** edit the export — a doctored export silently disagrees with the database, which is the error class this repo exists to prevent. |

Judgement: the first looks right. A 4-character value embedded in two local
utility table names, matching nothing as a whole token, reads as an over-broad
denylist entry rather than a leak. But weakening a redaction rule on a public
repo is not a call to make unilaterally.

**The affected operator's login is on the denylist and appears in no tracked
file** — verified. The new solution uses the `CATALOGER` placeholder throughout,
per the table in [`CLAUDE.md`](../CLAUDE.md#never-publish-real-site-identifiers).

---

## 1. New this session — `pref-setting-user-profile-test`

**Committed.** [`solutions/pref-setting-user-profile-test/`](../solutions/pref-setting-user-profile-test/README.md)
— README plus 8 generated `.sql` files and a runbook.

A **diagnostic, not a repair.** A cataloguer crashes the Horizon client on a
delete-file import with:

```text
Db.TermSession: not all database 'connections' are properly 'logged out'-- logging them out
Fatal Horizon (Internal) Error: LbSync.Request: invalid semaphore handle
```

Vendor support attributes it to a corrupted preference tied to the Horizon user
profile, and proposed copying the operator's `pref_setting` rows to a throwaway
login to confirm. The solution wraps that test in this repo's audit/backup/
transaction contract.

### What the schema lookup established

`pref_setting` is exactly five columns — `pref_category`, `pref_group#`,
`user_id`, `pref_id`, `pref_data` — with no identity and no computed column, so
the vendor's five-column `INSERT` copies a row **completely**. Worth having
checked: a sixth column would have produced partial rows and a test that proved
nothing.

`PK_PREF_SETTING` is a **unique index, not a declared primary key** — the usual
trap. Grain is `pref_category, pref_group#, user_id, pref_id`. Because `user_id`
sits inside that key, copied rows cannot collide with the source rows.

### Three faults found in the vendor's script

1. **Nothing enforces that the test user exists.** There is **no foreign key on
   `pref_setting.user_id`** — none on the table at all. The `INSERT` succeeds for
   an account that was never created, reports rows copied, and is
   indistinguishable from success. You then cannot log in, and the test never
   ran.
2. **`pref_group#` is part of the key and the copy preserves it.** Their `SELECT`
   carries the operator's `pref_group#` across unchanged, while
   `user_id.pref_group#` (default `2`) decides which group the *test* account
   loads. If those differ, the copied rows land in a group the test login never
   reads — the import runs clean and you conclude the profile is fine when
   nothing was ever loaded. **A false "fixed".**
3. **`save_preferences`** (`one_bit`, default 1) writes the session's preferences
   back on exit, so a second attempt is no longer testing the copied rows.

Also collapsed their `IF EXISTS … DELETE … INSERT ELSE INSERT`: both branches run
the same `INSERT`, and a `DELETE` matching nothing is already a no-op.

### Where it is blocked

**The throwaway Horizon account must be created in the staff client first.** That
is a GUI action, not SQL. Do not hand-write a `user_id` row — it carries
`user_password` (`varbinary`) and `user_password_64`, and a hand-built row will
not authenticate.

**Nothing has been run against the database.** Step 0 (three read-only queries)
gates everything and has not been executed.

### Next steps, in order

1. Create the test login in Horizon; confirm it is enabled.
2. Run **Step 0** (read-only). Compare `pref_group#` between the two accounts —
   if they differ, fix it on the account rather than rewriting the group in the
   copy.
3. Back up `pref_setting`, run **Step 1** (audit), record both counts.
4. Run **Step 2** inside the transaction; commit only if both `@@ROWCOUNT`
   values match the audit. **Do not leave the transaction open** — every staff
   client reads `pref_setting` at login, so an open transaction blocks the
   library.
5. Run the import as the test user with a `DbDebug` trace
   (`Ctrl+Shift+Alt+D`) already running.

**Worth sending back to support:** their script cannot distinguish "import
succeeded, so the profile was at fault" from "import succeeded because the copy
never loaded". A clean run is only evidence once Step 0 has passed.

---

## 2. The shareable toolkit — published

A generalised, site-neutral version of this repository was built and published:

**<https://github.com/byui-library/horizon-dba-toolkit>** — public, MIT, 53 files.

Local clone at `..\horizon-dba-toolkit\`. It is a **separate repository**; this
one is unchanged by its existence.

The organising idea: prose states only what is true of Horizon *everywhere*, and
everything that varies by site is **generated** from that site's own database.
It ships with no schema in it. `tools/Get-SiteProfile.ps1` is new there — it
measures compatibility level, collation, recovery model, declared PKs, and
probes which T-SQL functions actually work, then proves the **date epoch** by
scoring every candidate anchor from −3 to +3 days against a weekday histogram of
`bib_control`.

### Two open items on that repo

- **`LICENSE` reads `Copyright (c) 2026 Brigham Young University-Idaho`**,
  substituted for the `[Your Name]` placeholder. Now published attribution —
  confirm with whoever owns that call.
- **`Get-SiteProfile.ps1` has never run against a live database.** It parses
  clean, is pure ASCII with no BOM, and the suite statically verifies it writes
  no identifiers and contains no data-modifying SQL — but its queries are
  unexecuted. Run it once (read-only) before pointing another site at the setup
  instructions.

---

## 3. Uncommitted work sitting in the tree

**Not mine, and deliberately left alone.** Decide what to do with it.

| Path | State |
| --- | --- |
| `solutions/db-scratch-table-cleanup/README.md` | **+78 lines, uncommitted** — in-progress edit |
| `solutions/db-scratch-table-cleanup/sql/02, 04, 05` + `runbook.html` | regenerated by a `Test-Tools.ps1` run to match that README; they belong **with** it |
| `find-borrlegal-wk.sql` | untracked, at repo root |
| `restore-borrlegal-kw-permissions.sql` | untracked, at repo root |
| `restore-borrlegal-kw-triggers.sql` | untracked, at repo root |

The three loose `.sql` files sit at the **repository root**, which breaks the
structure convention — work belongs in `solutions/<name>/` with a README as the
deliverable, and `sql/*.sql` is generated from that README, never hand-placed. If
this is real work, scaffold it:

```powershell
powershell -ExecutionPolicy Bypass -File tools\New-Solution.ps1 `
    -Name borrlegal-kw-restore -Type Fix -Summary "One line for the index."
```

If it is scratch, delete it or move it out of the repo.

---

## 4. Earlier work — still current

### The ProQuest delete — DONE

Verified complete 2026-08-28. All 6,790 bibs deleted, no item rows remained, both
post-run checks returned 0. Recorded in [`killbib.md`](killbib.md).

The zero item count means that set contained no serials with issues or
predictions attached. **Do not generalise it** — KillBib skips such copies, so a
future list can leave items behind after a *successful* run.

### Scratch-table cleanup — DONE

42 tables dropped 2026-08-28, 0 failures. Three tables were pulled off the
candidate list as vendor, not scratch: all three had a post-install
`create_date` because something rebuilt them. The dependency check did not catch
them — a standalone lookup table has nothing referencing it. That near-miss is
why step 1b reports structural signals beside each candidate.

Schema export refreshed afterwards: 928 tables, 433 views, 13,949 columns.

### Accepted residual risk

The real server name is in public git history at `d765f8e` (2026-07-17). A
deliberate decision was made not to rewrite: it is a hostname rather than a
credential, it is already public, and force-pushing a public repo breaks clones
while GitHub still serves the old commit by SHA. **No password was ever
committed.**

---

## 5. Things that will bite you if you forget them

- **Never guess a column name.** A report was written against
  `bib_control.creator`; the real column is `create_user`. Grep
  `horizon-schema/all_tables_all_views.csv`.
- **Indexes named `PK_*` are not primary keys.** Only 6 declared PKs exist.
  Grain comes from *unique indexes*.
- **`STRING_AGG` does not exist** at this compatibility level, and `FOR XML PATH`
  fails on `bib.text` because of its control characters.
- **You cannot aggregate an `EXISTS`** — Msg 130. Compute the flag in a derived
  table first.
- **Generated files are generated.** Never hand-edit `sql/*.sql` or
  `runbook.html`; edit the README and re-run `Build-SolutionDocs.ps1`. Note that
  running it **unscoped regenerates every solution**, which is how an unrelated
  solution's outputs end up modified in your tree.
- **Dates are `smallint` day counts** from a verified `1970-01-01` epoch. Verify
  with a weekday histogram, never `MAX()` — a one-day error is invisible to it.
- **Run the test suite before committing.** It is the redaction guard, and this
  repository is public.
