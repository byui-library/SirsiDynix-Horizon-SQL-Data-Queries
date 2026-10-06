# Session handoff — 2026-10-06

State of play, and the exact next steps. Read §1 first; it is the only thing
with an open action on it.

Substitute real values for the placeholders throughout, per the table in
[`CLAUDE.md`](../CLAUDE.md#never-publish-real-site-identifiers):
**`CATALOGER`** = the affected operator's Horizon login, **`CATALOGER_T`** = the
replacement profile created for them. Both are in
`tools/.redaction-denylist.txt`, so they must never be typed into a tracked file.

---

## 1. The live issue — a Horizon client crash on import

**Status: half fixed, and now with the vendor. No action on our side.**

Four preference rows were corrected on 2026-10-06 and **the Horizon client
interface now imports cleanly**. The marcin command-line import still fails. A
further test — deleting the `WRKSPC`/`image` + `istyle` rows — **made it worse**,
turning a teardown error into an `ACCESS_VIOLATION`, and was rolled back.

The full preference output for both accounts was sent to Horizon support on
**2026-10-06** with a change log, at their request; they will produce the
correction. **Awaiting their response.**

The whole chain — what was changed, what it fixed, the regression, and three
hypotheses already eliminated — is in the
[solution's outcome log](../solutions/pref-setting-user-profile-test/README.md#outcome-log).
Read that rather than re-deriving any of it.

The operator can keep working from the replacement account meanwhile.

### Where this came from

The operator's Horizon client crashed on a delete-file import with:

```text
Db.TermSession: not all database 'connections' are properly 'logged out'-- logging them out
Fatal Horizon (Internal) Error: LbSync.Request: invalid semaphore handle
```

Reinstalling the client did not help. Vendor support attributed it to a
corrupted preference tied to that user profile. **A fresh profile was created
and the import ran cleanly under it**, which also cleared a separate KillBib
hang once `/r` pointed at the new login. So the fault is in something attached
to the original account, and the operator is currently working from the
replacement.

The vendor has asked for the differing `pref_setting` rows so they can correct
the real account and stop the operator working from the replacement.

### What has been established

Queries 4a–4d of
[`pref-setting-user-profile-test`](../solutions/pref-setting-user-profile-test/README.md)
have been run. Results are recorded in §4e of that README — **read it rather
than re-deriving**. In short:

- Both accounts sit in `pref_group#` **0**, so the comparison is valid.
- **56 rows** on the real account, **54** on the replacement, **20 differ**.
- **Nothing is byte-level corrupt.** No control characters, nothing near the
  255-byte limit, no stray whitespace. The fault is a *semantically invalid
  value*, not damaged data.

Ranked suspects:

| # | Row | Why |
| ---: | --- | --- |
| **1** | `WRKSPC` / `rect` + `max` | The only objectively invalid value: window geometry entirely off-screen |
| 2 | `CTRLBAR` / `basebar7`, `extbar7` | Present on the replacement, **absent** on the real account |
| 3 | `WRKSPC` / `image` + `istyle` | Points at a local image file that may no longer exist |
| 4 | `CTRLBAR` / `basebar1` | Three extra semicolon fields vs the replacement (18 vs 15) |

Suspect 1: the rectangle is `-1928,-8,-632,760` against `334,241,1630,1009` on
the replacement. **Both are exactly 1296 x 768** — same size, different place —
but the first is wholly off-screen, on a monitor left of the primary display,
and `max` is `1;1`. If that monitor is gone, the client restores a maximized
workspace onto a display that does not exist.

**This has not been tied to the `invalid semaphore handle` error mechanically.**
It is the strongest candidate on the evidence. Do not let it be reported as a
diagnosis.

### Do this next — one check, then wait

**Confirm the rollback landed.** A rollback restoring `WRKSPC`/`image` +
`istyle` was issued but never verified:

```sql
SELECT ps.user_id, COUNT(*) AS [pref_rows]
FROM pref_setting ps
WHERE ps.user_id IN ('CATALOGER', 'CATALOGER_T')
GROUP BY ps.user_id
ORDER BY ps.user_id;
```

**58** on the real account = the rollback went in. **56** = it did not, and those
two rows are still missing — which is the state that produced the
`ACCESS_VIOLATION`. If it reads 56, restore them; the values are in §4f and the
outcome log.

Then wait for support. **Do not change further preference rows in the meantime** —
they are working from a dump of the current state, and moving it underneath them
wastes the round trip.

### When support replies

Before applying anything they send:

- Check it does not revert the four rows that fixed the interface
  (`WRKSPC`/`rect`, `WRKSPC`/`max`, `CTRLBAR`/`basebar7`, `CTRLBAR`/`extbar7`).
  They were told, but a bulk correction built from the dump could still undo them.
- Apply it with the same contract as everything else here: audit first, row count
  checked inside a transaction, operator logged out of Horizon so
  `save_preferences` does not write over it.

### Still unanswered, and worth having

- **Does the operator still have a second monitor to the left of their primary
  display?** `save_preferences = 1`, so the client wrote `-1928,-8,-632,760`
  itself — that window really was there once. If the monitor is still attached,
  the geometry was never invalid and `basebar7` is what fixed the interface.
- **What machine and Windows account does marcin run under?** A path under one
  user's profile cannot resolve from another's context, which would make
  per-user paths structurally wrong for marcin rather than merely stale.
- **Which `import_source` does the failing import use?** Roughly forty exist at
  differing `ord` priorities.
- **Did earlier marcin runs also show an `ACCESS_VIOLATION`** that simply was not
  reported? If so, the teardown messages were never the fault and the first
  diagnosis was aimed at a symptom.
- **Did the records from the marcin runs actually land completely?** Those runs
  ended on unclean teardowns with connections open, which is how partial work
  survives looking like success.

### If you need to undo the 2026-10-06 change

Rollback is in §4f of the solution README. Four rows: two values restored
(`-1928,-8,-632,760` and `1;1`) and two inserted rows deleted.

**The operator must be logged out first**, or their client writes its in-memory
preferences back over whatever you do.

### What the vendor is still owed

- **The result, which is genuinely useful to them**: four rows fixed the client
  interface — `WRKSPC`/`rect` and `max`, plus `CTRLBAR`/`basebar7` and `extbar7`
  restored from the replacement account. No bulk repopulate was needed. That is
  a narrower answer than the prior case they described.
- **That marcin is a separate, surviving fault**, and that it now completes the
  import and fails on *teardown* rather than hanging. `Db.TermSession` means
  session termination, so the work finishes and the shutdown does not.
- **A question for them**: `CTRLBAR`/`basebar1` carries three more
  semicolon-delimited fields on the real account than on the replacement. The
  control-bar serialisation format is undocumented here, so it is reported, not
  interpreted.
- **A correction, if the earlier draft reply went out**: the replacement profile
  is a **fresh default**, not a copy of the operator's rows. An earlier draft
  overstated the candidate list as a result.
- Worth mentioning as ruled out, so they do not suggest it: no marcin match
  point references a missing table — all 68 resolve.

**Do not commit any query output.** `pref_data` holds local filesystem paths —
one of them contains a username. `.gitignore` blocks `*.csv`/`*.xlsx` for
exactly this reason.

---

## 2. Uncommitted work sitting in the tree

Everything below is written, tested and **not committed**. The suite passes; a
commit is one command.

| Path | State |
| --- | --- |
| `solutions/pref-setting-user-profile-test/` | the comparison (§4), the four-row fix (§4f) and the outcome log |
| `docs/SESSION-HANDOFF.md` | this file |

```powershell
powershell -ExecutionPolicy Bypass -File tools\Test-Tools.ps1
git add -A
git commit
git push origin master
```

Run the suite **before** committing — it is the redaction guard, and this
repository is public.

---

## 3. Recently finished — no action needed

### `borrLegal_KW` restore — pushed

[`solutions/borrlegal-kw-restore`](../solutions/borrlegal-kw-restore/README.md),
commit `29be4a6`. The scratch-table cleanup dropped a live local customisation —
a table plus three DML triggers deployed together in 2023 — and cataloguers lost
borrower edits three days later.

Two findings worth not re-deriving: the object is `borrLegal_KW`, not
`borrLegal_WK` (no `*_WK` object exists in the export, and `word.n_borrLegalKW`
does); and restoring the triggers does **not** repair the keyword counters that
drifted while they were absent. **Step 4 of that solution is still outstanding**
if the triggers have been restored — drift produces wrong search results, never
an error.

Its root cause is fixed too: `db-scratch-table-cleanup` now excludes any table
carrying triggers, because `sys.sql_expression_dependencies` cannot see a
trigger's own parent, so a table-plus-triggers customisation reads as an
unreferenced orphan.

### Toolkit published

<https://github.com/byui-library/horizon-dba-toolkit> — public, MIT, a
site-neutral version of this repository. Two open items: confirm the `LICENSE`
copyright holder, and run `Get-SiteProfile.ps1` once against a live database
(it has never been executed).

### Redaction guard

A denylist line may be written `word:<value>` to match only where the value
stands as its own token — a narrowing for short values that occur inside
unrelated identifiers, not an exclusion. See
[`CLAUDE.md`](../CLAUDE.md#denylist-entry-forms).

---

## 4. Things that will bite you if you forget them

- **Never guess a column name.** A report was written against
  `bib_control.creator`; the real column is `create_user`. Grep
  `horizon-schema/all_tables_all_views.csv`.
- **Never use a real identifier as an example**, including in a comment or in a
  sentence saying it appears nowhere. The guard has caught that three times now,
  twice in this assistant's own writing.
- **Indexes named `PK_*` are not primary keys.** Grain comes from unique indexes.
- **`pref_data` comparisons need care.** The collation is `CI` and the type is
  `varchar`, so `=` ignores case *and* trailing spaces; `pref_group#` is
  nullable, so a plain `=` join drops those rows. Use
  `COLLATE Latin1_General_BIN` plus `DATALENGTH`. §4c has the worked form.
- **A `CASE` with no `ELSE` returns `NULL`.** In an `UPDATE` against a nullable
  column that silently erases data. Always `ELSE <column>`.
- **Generated files are generated.** Edit the README and re-run
  `Build-SolutionDocs.ps1`. Unscoped, it regenerates *every* solution — which is
  how an unrelated solution's outputs end up modified in your tree.
- **Dates are `smallint` day counts** from a verified `1970-01-01` epoch. Verify
  with a weekday histogram, never `MAX()`.
- **Run the test suite before committing.** This repository is public.
