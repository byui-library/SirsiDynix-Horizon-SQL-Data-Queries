# pref_setting user-profile isolation test

## The Problem

A cataloguer (`CATALOGER`) crashes the Horizon client when running a delete-file
import. The signature is two errors in sequence:

```text
Db.TermSession: not all database 'connections' are properly 'logged out'-- logging them out
Fatal Horizon (Internal) Error: LbSync.Request: invalid semaphore handle
```

Reinstalling the client did not help. Vendor support reports a prior case at this
institution with the identical string, traced to a corrupted preference tied to
the **Horizon user profile** rather than to the `pref_setting` table as a whole
or to anything in the Security Menu.

**This solution does not fix anything.** It is a diagnostic that answers one
question: *is the fault carried by the operator's preference rows, or not?* It
copies `CATALOGER`'s preferences onto a throwaway login and re-runs the import
there.

- Import **crashes** as the test user → the fault travels with the preference
  rows, and the next step is bisecting which row carries it.
- Import **succeeds** as the test user → the fault is *not* in the copied rows.
  It is in something else attached to the account (client-side profile, roaming
  data, `user_id` row itself), and copying preferences will never surface it.

That second outcome is the one worth stating up front, because the vendor's
proposed script cannot distinguish it from a mis-set-up test.

### The tables

Looked up in `horizon-schema/`, not inferred:

| Object | Grain | Role |
| --- | --- | --- |
| `pref_setting` | `pref_category, pref_group#, user_id, pref_id` | one row per preference, per user |
| `user_id` | `user_id` | the Horizon staff account itself |
| `pref_group` | `pref_group#` | named preference group, with a `load_priority` |

`pref_setting` has exactly five columns — `pref_category`, `pref_group#`,
`user_id`, `pref_id`, `pref_data` — with no identity and no computed column, so a
five-column `INSERT` copies a row completely. **Verified against the export**;
had there been a sixth column, the vendor's script would have silently produced
partial rows and the test would have proved nothing.

### Three things the vendor's script does not handle

**1. Nothing enforces that the test user exists.** There is **no foreign key** on
`pref_setting.user_id` — the export shows no FK touching this table at all. So
`INSERT ... SELECT` for a `user_id` that was never created as a Horizon account
succeeds, reports rows copied, and looks exactly like success. You then cannot
log in as that user, and the "test" was never run.

**The test login must be created in Horizon first**, through the staff client's
user administration. Do not hand-write a row into `user_id`: it carries
`user_password` (`varbinary`) and `user_password_64`, and a hand-built row will
not authenticate.

**2. `pref_group#` is part of the key, and the copy preserves it.** The vendor's
`SELECT` carries `CATALOGER`'s `pref_group#` across unchanged, while
`user_id.pref_group#` (default `2`) says which group the *test* account belongs
to. If those differ, the copied rows land under a group the test login does not
load — the import runs clean, and you conclude the profile is fine when in fact
nothing of `CATALOGER`'s was ever loaded. **A false "fixed".** Step 0 checks this
before anything is written.

**3. `save_preferences` can overwrite the copy.** `user_id.save_preferences` is a
`one_bit` defaulting to 1. With it on, logging in as the test user and closing
the client writes that session's preferences back — so a second run of the test
is no longer testing the rows you copied. Re-run Step 2 between attempts, or turn
the flag off on the test account.

### The `PK_` trap applies here

`PK_PREF_SETTING` reports `is_primary_key = no`. It is a **unique index**, not a
declared primary key — see [`docs/schema/conventions.md`](../../docs/schema/conventions.md#keys-grain-and-the-pk_-trap).
It still establishes grain, and because `user_id` sits inside that key, rows
copied under a different `user_id` cannot collide with the source rows.

### A backup is required before Step 2

Step 2 deletes rows. Take a **`pref_setting` table backup, or a full database
backup**, before running it:

```sql
SELECT * INTO pref_setting_bak_20260922 FROM pref_setting;
```

Under a `FULL` recovery model that is fully logged — check the size of
`pref_setting` first. The table is small at most sites, but confirm rather than
assume.

> **Substitute your own values.** `CATALOGER` is the placeholder for the real
> operator login and `CATALOGER_T` for the throwaway test login, per the
> placeholder table in [`CLAUDE.md`](../../CLAUDE.md#never-publish-real-site-identifiers).
> Both are `varchar(30)`; the collation is `CI`, so case does not matter.

---

## Step 0: Verify before you touch anything (read-only)

**Run all three and read the results before continuing.** Each one can invalidate
the test on its own.

```sql
-- Q0a: Do both accounts exist, and do they share a preference group?
-- Every column below was looked up in horizon-schema/, not inferred.
SELECT u.user_id,
       u.user_name,
       u.[pref_group#],
       u.save_preferences,
       u.user_disabled,
       u.security_level
FROM user_id u
WHERE u.user_id IN ('CATALOGER', 'CATALOGER_T')
ORDER BY u.user_id;
```

| Result | Meaning |
| --- | --- |
| **Two rows** | Proceed — but compare `pref_group#` (see below). |
| **One row** (`CATALOGER` only) | The test account does not exist. **Stop.** Create it in Horizon first; the copy would otherwise succeed against nothing. |
| `user_disabled = 1` on the test account | It cannot log in. Enable it first. |
| `pref_group#` **differs** between the two | Stop and read "If the preference groups differ" below before running Step 2. |
| `save_preferences = 1` on the test account | Expect the copy to be overwritten when the client closes. Re-run Step 2 before each attempt. |

```sql
-- Q0b: What is actually being copied, broken out by group and category?
SELECT ps.[pref_group#],
       ps.pref_category,
       COUNT(*) AS [rows]
FROM pref_setting ps
WHERE ps.user_id = 'CATALOGER'
GROUP BY ps.[pref_group#], ps.pref_category
ORDER BY ps.[pref_group#], ps.pref_category;
```

If this returns **no rows**, the operator has no stored preferences and the
vendor's hypothesis cannot be tested this way at all. Stop and say so.

```sql
-- Q0c: Current row counts on both sides. Record these.
SELECT ps.user_id, COUNT(*) AS [pref_rows]
FROM pref_setting ps
WHERE ps.user_id IN ('CATALOGER', 'CATALOGER_T')
GROUP BY ps.user_id
ORDER BY ps.user_id;
```

### If the preference groups differ

Prefer fixing it on the account: set the test user's preference group to match
the operator's, in Horizon's user administration, then re-run Q0a. That keeps
Step 2 a straight copy and keeps the test honest.

Only if that is not possible, rewrite the group during the copy — and record that
you did, because it means the test is no longer an exact reproduction:

```sql
-- Variant of Step 2's INSERT. Use ONLY when the two accounts are in different
-- preference groups and the test account's group cannot be changed.
-- Replace 2 with the test account's actual pref_group# from Q0a.
INSERT INTO pref_setting (pref_category, [pref_group#], user_id, pref_id, pref_data)
SELECT ps.pref_category, 2, 'CATALOGER_T', ps.pref_id, ps.pref_data
FROM pref_setting ps
WHERE ps.user_id = 'CATALOGER';
```

---

## Step 1: The Audit

**Run this first and record both row counts.** It lists exactly the rows Step 2
will remove and the rows it will create. The `WHERE` clauses are the same ones
Step 2 uses.

```sql
-- Every table and column below was looked up in horizon-schema/, not inferred.
SELECT 'will DELETE' AS [action],
       ps.pref_category,
       ps.[pref_group#],
       ps.user_id,
       ps.pref_id,
       ps.pref_data
FROM pref_setting ps
WHERE ps.user_id = 'CATALOGER_T'

UNION ALL

SELECT 'will INSERT as CATALOGER_T' AS [action],
       ps.pref_category,
       ps.[pref_group#],
       ps.user_id,
       ps.pref_id,
       ps.pref_data
FROM pref_setting ps
WHERE ps.user_id = 'CATALOGER'

ORDER BY [action], pref_category, [pref_group#], pref_id;
```

Record the count of each `action`. The `will DELETE` count must match Q0c's row
for `CATALOGER_T` (or be zero if that user had none); the `will INSERT` count
must match Q0c's row for `CATALOGER`.

---

## Step 2: The Update

The `FROM`/`WHERE` clauses below are **identical** to the audit query's, so the
affected row set provably matches what was reviewed. If you change one, change
both — diverging them breaks the core safety guarantee of this repo.

Simplified from the vendor's version: their `IF EXISTS ... DELETE ... INSERT ELSE
INSERT` runs the same `INSERT` down both branches, and a `DELETE` that matches
nothing is already a no-op. The branch adds a second copy of the statement to
keep in sync and buys nothing.

```sql
BEGIN TRANSACTION;

DELETE FROM pref_setting
WHERE user_id = 'CATALOGER_T';

SELECT @@ROWCOUNT AS [rows_deleted];    -- compare to the audit's "will DELETE"

INSERT INTO pref_setting (pref_category, [pref_group#], user_id, pref_id, pref_data)
SELECT ps.pref_category,
       ps.[pref_group#],
       'CATALOGER_T',
       ps.pref_id,
       ps.pref_data
FROM pref_setting ps
WHERE ps.user_id = 'CATALOGER';

SELECT @@ROWCOUNT AS [rows_inserted];   -- compare to the audit's "will INSERT"

-- Both counts match the audit:
-- COMMIT TRANSACTION;
-- Either count is different:
-- ROLLBACK TRANSACTION;
```

**Do not leave this transaction open.** An uncommitted transaction holds locks on
`pref_setting`, which every staff client reads at login — you will block the
library, not just yourself.

---

## Step 3: Run the test

1. Log in to the Horizon client as **`CATALOGER_T`**.
2. Run **the same delete-file import** that crashes for `CATALOGER` — same file,
   same options.
3. Before attempting it, start a `DbDebug` trace (`Ctrl+Shift+Alt+D` in the
   client) so the `.DMP` is captured whichever way it goes.

| Outcome | What it means | Next step |
| --- | --- | --- |
| **Crashes**, same two errors | The fault is in the copied preference rows. | Bisect: restore half the rows to the test user, re-test, repeat. `pref_category` is the natural first split. |
| **Succeeds** | The fault is **not** in `pref_setting`. | Look at the `user_id` row itself, client-side profile/roaming data, and anything account-scoped outside this table. Copying preferences will not find it. |
| **Crashes differently** | Not the same fault; the test user is probably mis-configured. | Re-check Q0a — especially `pref_group#`. |

Send the `.DMP` to vendor support either way. A clean run is evidence too, and it
is the result their script cannot currently distinguish from a test that never
loaded anything.

---

## Step 4: Identify which rows differ

### What actually happened — read this before trusting the diff

The test did not run as Step 2 designed it. Rather than copying the operator's
preferences onto the test login, **a brand-new profile was created and the
import ran cleanly under it.** Pointing KillBib's `/r` at the new login also
cleared a separate hang.

That is a *better* outcome for the user and a *worse* one for the diff, and the
reason is worth being explicit about:

| If the test login had… | A diff against it would show |
| --- | --- |
| a **copy** of the operator's rows (Step 2) | only what changed since — a short list, probably one row |
| a **fresh default** profile (what happened) | **every preference the operator ever customised** |

So the comparison below does **not** isolate the corrupted row. It returns the
operator's entire deviation from default — window positions, saved searches,
default locations, all of it — with the fault somewhere inside. Narrowing is
Step 4c's job, not the diff's.

Do not send the raw diff on as "the rows that differ". It is the candidate set.

### 4a. Are the two accounts comparable?

```sql
-- Read-only. Every column looked up in horizon-schema/, not inferred.
SELECT u.user_id,
       u.user_name,
       u.[pref_group#],
       u.save_preferences,
       u.user_disabled
FROM user_id u
WHERE u.user_id IN ('CATALOGER', 'CATALOGER_T')
ORDER BY u.user_id;
```

### 4b. Which preference groups do their rows actually sit in?

**Run this before the diff.** `pref_group#` is part of the grain, so if the two
accounts' rows sit in different groups, every row joins to nothing and the diff
reports *everything* as one-sided — which reads exactly like total corruption
and means nothing of the sort.

```sql
-- Read-only.
SELECT ps.user_id,
       ps.[pref_group#],
       COUNT(*) AS [rows]
FROM pref_setting ps
WHERE ps.user_id IN ('CATALOGER', 'CATALOGER_T')
GROUP BY ps.user_id, ps.[pref_group#]
ORDER BY ps.user_id, ps.[pref_group#];
```

If the group numbers match, the diff is meaningful. If they do not, stop and say
so rather than reporting the output as differences.

### 4c. The diff

Three details in the schema shape this query, and all three can hide the thing
you are hunting:

1. **`pref_group#` is nullable.** A plain `=` join silently drops rows where it
   is `NULL`, because `NULL = NULL` is not true. The join below handles that
   explicitly.
2. **`pref_data` is `varchar` under a `CI` collation**, so `=` ignores case
   *and* trailing spaces. For a *corrupted* value, either could be the entire
   difference — so the comparison uses `Latin1_General_BIN` and checks
   `DATALENGTH` as well.
3. **`pref_data` is nullable**, and a `<>` against `NULL` yields `NULL`, never
   true. The `NULL`-vs-value cases are therefore tested separately.

```sql
-- Read-only. Shows rows present on one side only, and rows whose value differs.
SELECT
    COALESCE(a.pref_category, b.pref_category) AS [pref_category],
    COALESCE(a.[pref_group#], b.[pref_group#]) AS [pref_group#],
    COALESCE(a.pref_id, b.pref_id)             AS [pref_id],
    CASE WHEN a.user_id IS NULL THEN 'only on the test login'
         WHEN b.user_id IS NULL THEN 'only on the real account'
         ELSE 'value differs' END              AS [difference],
    a.pref_data                                AS [real_value],
    b.pref_data                                AS [test_value],
    DATALENGTH(a.pref_data)                    AS [real_bytes],
    DATALENGTH(b.pref_data)                    AS [test_bytes]
FROM      (SELECT pref_category, [pref_group#], user_id, pref_id, pref_data
           FROM pref_setting WHERE user_id = 'CATALOGER')   a
FULL OUTER JOIN
          (SELECT pref_category, [pref_group#], user_id, pref_id, pref_data
           FROM pref_setting WHERE user_id = 'CATALOGER_T') b
       ON  b.pref_category = a.pref_category
       AND b.pref_id       = a.pref_id
       AND (b.[pref_group#] = a.[pref_group#]
            OR (b.[pref_group#] IS NULL AND a.[pref_group#] IS NULL))
WHERE a.user_id IS NULL
   OR b.user_id IS NULL
   OR (a.pref_data IS     NULL AND b.pref_data IS NOT NULL)
   OR (a.pref_data IS NOT NULL AND b.pref_data IS     NULL)
   OR a.pref_data COLLATE Latin1_General_BIN
   <> b.pref_data COLLATE Latin1_General_BIN
   OR DATALENGTH(a.pref_data) <> DATALENGTH(b.pref_data)
ORDER BY [pref_category], [pref_group#], [pref_id];
```

`FULL OUTER JOIN` rather than a one-sided join because all three cases matter: a
row the real account has and the test login does not, a row only the test login
has, and a row both have with different data.

### 4d. Hunt the corruption directly

More likely to find it than the diff, because it does not care what the test
login holds. A value described as *corrupted* often looks structurally wrong,
and these three shapes are what that looks like in a `varchar(255)`:

```sql
-- Read-only. Structurally suspicious preference values on the real account.
SELECT
    ps.pref_category,
    ps.[pref_group#],
    ps.pref_id,
    ps.pref_data,
    DATALENGTH(ps.pref_data) AS [bytes],
    CASE
        WHEN ps.pref_data COLLATE Latin1_General_BIN LIKE '%[^ -~]%'
             THEN 'contains control or high-byte characters'
        WHEN DATALENGTH(ps.pref_data) = 255
             THEN 'exactly 255 bytes - possibly truncated'
        WHEN DATALENGTH(ps.pref_data)
          <> DATALENGTH(LTRIM(RTRIM(ps.pref_data)))
             THEN 'leading or trailing whitespace'
        ELSE ''
    END AS [why_suspicious]
FROM pref_setting ps
WHERE ps.user_id = 'CATALOGER'
  AND ps.pref_data IS NOT NULL
  AND (ps.pref_data COLLATE Latin1_General_BIN LIKE '%[^ -~]%'
       OR DATALENGTH(ps.pref_data) = 255
       OR DATALENGTH(ps.pref_data) <> DATALENGTH(LTRIM(RTRIM(ps.pref_data))))
ORDER BY [why_suspicious], ps.pref_category, ps.pref_id;
```

`[^ -~]` matches any byte outside printable ASCII — space (32) through tilde
(126) — so control characters and high bytes both show up. The `BIN` collation
is what makes that range mean bytes rather than linguistic equivalence.

**`DATALENGTH` exactly 255** deserves attention on its own: the column is
`varchar(255)`, so a value that fills it precisely is the signature of something
written through a path that truncated it, and a truncated setting is a corrupted
setting.

Cross-reference the output against 4c. **A row appearing in both lists is the
strongest candidate you will get from SQL alone.**

### 4e. What the diff actually found

Run 2026-10-02. **20 rows differed** out of 56 on the real account and 54 on the
test login. Recorded here so the analysis is not redone from scratch.

Nothing was byte-level corrupt — 4d came back empty, the longest value was 93
bytes against a 255 limit, every byte printable. **So the fault is a
semantically invalid value, not damaged data**, which narrows it considerably.

**Ranked suspects:**

| # | Row | Why |
| ---: | --- | --- |
| 1 | `WRKSPC` / `rect` | **The only objectively invalid value in the set.** See below. |
| 2 | `CTRLBAR` / `basebar7`, `extbar7` | Present on the test login, **absent** on the real account |
| 3 | `WRKSPC` / `image` + `istyle` | Points at a local image file that may no longer exist |
| 4 | `CTRLBAR` / `basebar1` | Three extra semicolon fields vs the test login (18 vs 15) |

**Suspect 1 in detail.** The workspace rectangle on the real account was
`-1928,-8,-632,760`; on the test login, `334,241,1630,1009`. Both are **exactly
1296 x 768** — same window size, different position — but the first sits
entirely off-screen, on a monitor to the *left* of the primary display. Paired
with `max` = `1;1` (maximized) against `0;0`.

If that second monitor is gone — redocked, reimaged, moved — the client restores
a maximized workspace onto a display that does not exist. That is a known way
for a Windows application to hang or die when it next opens a modal dialog,
which is when an import runs.

**This has not been tied to the `invalid semaphore handle` error mechanically**,
and should not be presented as though it had. It is the strongest candidate on
the evidence, nothing more.

Suspects 2 and 4 are for the vendor: the control-bar serialisation format is
undocumented here, so the field-count difference is reported, not interpreted.

### 4f. Test suspect 1 — two rows, fully reversible

> **The operator must be fully logged out of Horizon before this runs.**
> If `save_preferences` is set on the account, an open client writes its
> **in-memory** preferences back when it closes, overwriting the update and
> making a correct fix look like a failure. Check `save_preferences` in 4a.

**The audit.** Expect exactly 2 rows.

```sql
SELECT
    ps.pref_category,
    ps.[pref_group#],
    ps.pref_id,
    ps.pref_data                        AS [current_value],
    CASE ps.pref_id
         WHEN 'rect' THEN '334,241,1630,1009'
         WHEN 'max'  THEN '0;0'
    END                                 AS [proposed_value]
FROM pref_setting ps
WHERE ps.user_id = 'CATALOGER'
  AND ps.pref_category = 'WRKSPC'
  AND ps.pref_id IN ('rect', 'max');
```

**The update.** Identical `WHERE` to the audit, so the rows changed are provably
the rows reviewed.

```sql
BEGIN TRANSACTION;

UPDATE pref_setting
SET    pref_data = CASE pref_id
                        WHEN 'rect' THEN '334,241,1630,1009'
                        WHEN 'max'  THEN '0;0'
                        ELSE pref_data
                   END
WHERE user_id = 'CATALOGER'
  AND pref_category = 'WRKSPC'
  AND pref_id IN ('rect', 'max');

SELECT @@ROWCOUNT AS [rows_updated];    -- must be 2

-- COMMIT TRANSACTION;
-- ROLLBACK TRANSACTION;
```

**`ELSE pref_data` is load-bearing.** A `CASE` with no `ELSE` returns `NULL` for
any unmatched row, and `pref_data` is nullable — so widening the `IN` list
without widening the `CASE` would silently null out settings rather than leave
them alone.

**Do not leave the transaction open.** Every staff client reads `pref_setting`
at login, so held locks block the library rather than just this session.

**The rollback** — this is the backup that matters for a two-row change. The
original values, captured before the update:

```sql
UPDATE pref_setting
SET    pref_data = CASE pref_id
                        WHEN 'rect' THEN '-1928,-8,-632,760'
                        WHEN 'max'  THEN '1;1'
                        ELSE pref_data
                   END
WHERE user_id = 'CATALOGER'
  AND pref_category = 'WRKSPC'
  AND pref_id IN ('rect', 'max');
```

**Then have the operator launch a fresh client and re-run the import.**

| Outcome | Meaning |
| --- | --- |
| Succeeds | Found and fixed. Two rows, no bulk correction needed. |
| Still crashes | Suspect 1 eliminated for the cost of two rows. Move to suspect 2. |
| Crashes differently | Record the new error verbatim — a changed signature is information. |

**Afterwards, re-run the audit.** If the two rows have reverted, the operator's
client session wrote its preferences back and the test did not actually run.

### What to send on

The vendor asked for the rows that differ, so they can build corrected values.
Send:

- 4b's group distribution — it is the context that makes the rest readable
- 4c's diff, **labelled as the candidate set, not the answer**
- 4d's anomalies, flagged as the narrower list
- a note on whether the test login is a copy or a fresh default, because it
  changes what the diff means

**Do not commit any of this output.** It is query output from a live ILS;
`.gitignore` blocks `*.csv`/`*.xlsx` for exactly this reason. `pref_data` can
hold paths, server names and file locations.

---

## Step 5: Clean up

The test rows are harmless but they are scratch, and scratch that stays becomes
the kind of thing
[`db-scratch-table-cleanup`](../db-scratch-table-cleanup/README.md) exists to
find later.

```sql
-- Remove the copied preferences once the test is concluded.
DELETE FROM pref_setting WHERE user_id = 'CATALOGER_T';
SELECT @@ROWCOUNT AS [rows_removed];
```

Drop the backup table once the outcome is recorded, and disable or delete the
test account in Horizon.

---

## Notes and edge cases

- **Case sensitivity**: `user_id` is `SQL_Latin1_General_CP850_CI_AS`, so `=`
  ignores case. `'CATALOGER'` and `'cataloger'` match the same account.
- **`pref_data` is `varchar(255)` and nullable.** A corrupted value is very
  likely to be *inside* one of these strings, which is why the audit selects the
  data rather than just counting.
- **No date columns are involved**, so the integer-date convention in
  [`docs/schema/conventions.md`](../../docs/schema/conventions.md#dates) does not
  apply here. `user_id.last_updated_date` is a real `datetime`, unusually for this
  schema — do not "fix" it into a day count.
- **`pref_setting` has no foreign keys at all**, in either direction. Nothing in
  the database will object to an orphaned or malformed row; only the client will,
  by crashing.
- **Deliberately not filtered**: the copy takes *all* of the operator's
  preference rows, across every category and group. Narrowing it would presuppose
  which preference is at fault, which is the thing the test is meant to discover.
- This is a **diagnostic, not a remedy**. Even a crash-free test run leaves the
  operator working from a test login; the actual repair is a separate change once
  the offending row is identified.
