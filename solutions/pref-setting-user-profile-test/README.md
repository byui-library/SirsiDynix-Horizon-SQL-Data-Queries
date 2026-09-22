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

## Step 4: Clean up

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
