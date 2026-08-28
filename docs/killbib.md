# KillBib — Horizon's batch bib delete

Reference for the vendor utility itself: what its flags mean, what it silently
refuses to do, and how it fails. For *our* wrapper scripts see
[`tools/README.md`](../tools/README.md).

**Version documented: 7.61 (2024-05-28)**, verified against
`KillBib.exe /?` on 2026-08-27. On this machine the executable is at
`C:\Program Files (x86)\SirsiDynix\Horizon_2\KillBib.exe` and is **not on
`PATH`**; `tools\Find-KillBib.ps1` resolves it.

Everything below was established by running the tool, not inferred. Where a fact
is still unproven it says so.

---

## Usage output

```text
Usage: KILLBIB    version 7.61   05/28/2024
     /sServer  /pPassword  /uUser  /dDatabase  /lLocation
     /rHorizon User ID
     /t tablename with bib# int field
     /b beginning bib# and /e ending bib#
     /k brutal delete -- will delete items/copies/circ info, etc.
     (use extreme caution with /k option -- there is no recovery!)
     /w don't wipe bib/bib_control rows (default is yes)
     /# show program change history
     NOTE: will not delete copies if issues/predictions are attached
```

| Flag | Meaning | Required? |
| --- | --- | --- |
| `/s` | SQL Server instance | yes |
| `/d` | Database name | yes |
| `/u` | **Database** login | yes |
| `/p` | Password for `/u` | yes |
| `/r` | **Horizon User ID** — a different identity from `/u` | **yes** (see below) |
| `/l` | Horizon location code | **yes** (see below) |
| `/t` | Table holding the `bib#` list, `int` column | yes |
| `/b` | Beginning `bib#` | optional |
| `/e` | Ending `bib#` — with `/b`, bounds a range | optional |
| `/k` | "Brutal delete" — also removes items, copies, circ info | optional |
| `/w` | Do **not** wipe `bib`/`bib_control` (default is to wipe) | optional |
| `/#` | Show program change history | optional |

Values abut their switch with no space: `/sILSSERVER`, not `/s ILSSERVER`.

---

## The five things that will cost you an afternoon

None of these appear in the usage output.

### 1. The `/t` table name is truncated at 31 characters

**Measured 2026-08-27.** A table named
`ProQuest_CAT_20260825_DeleteList_2` (35 chars) reached the server as
`ProQuest_CAT_20260825_DeleteLi` (31 chars) and failed with:

```text
Database Error| [Microsoft][ODBC Driver 18 for SQL Server][SQL Server]
Invalid object name 'ProQuest_CAT_20260825_DeleteLi'.
```

SQL Server permits 128-character identifiers, so **nothing on the database side
catches this** — the table is created correctly, granted correctly, and KillBib
simply cannot see it. Granting permissions again does not help, because the
object it is looking for does not exist.

**Keep delete-list table names to 30 characters or fewer.** The 2026-07 run
succeeded partly because `ProQuest_Purchase_DeleteList` is 28.
`tools\Invoke-DeleteListRun.ps1` and `tools\Invoke-KillBib.ps1` both refuse a
longer name up front with an explanation.

### 2. There is no dry-run

`/w`'s description — *"don't wipe bib/bib_control rows (default is yes)"* —
proves that the default behaviour **deletes bib and bib_control rows with or
without `/k`**. `/k` widens the blast radius to items, copies and circulation
data; it does not switch deletion on.

Running without `/k` "to see what happens" deletes records. Nothing in this
utility can be run exploratorily.

The only safe way to observe its behaviour is to point `/t` at a table
containing **zero rows**, or to bound a run to a single record with `/b` and
`/e` set to the same `bib#`.

### 3. It must run from its own directory

Invoked by full path from another working directory, KillBib **died silently**
— 18.9 seconds, no output at all, exit code `2147483647` (`Int32.MaxValue`, not
a real status). Run from `C:\Program Files (x86)\SirsiDynix\Horizon_2` it
authenticates and prints:

```text
Logged in to ILSSERVER\..\ILSDB
```

`tools\Invoke-KillBib.ps1` sets the working directory automatically.

### 4. `/u` and `/r` are different identities

`/u` is the **SQL Server login**. `/r` is the **Horizon staff User ID** — the
account you log into the Horizon client with. They are unrelated, and the usage
output lists no password flag for `/r`.

Supplying `/u` and `/p` alone gets you as far as `Logged in to ...` and no
further. Both wrapper scripts prompt for `/r` as a mandatory parameter so it
cannot be forgotten.

### 5. `/l` is a Horizon location code

Undescribed in the usage output. Site practice here is that it is required.
`tools\Invoke-DeleteListRun.ps1` **validates it against the `location` table**
before doing anything else, so a typo fails in step 1 with a list of valid codes
rather than surfacing as KillBib misbehaving.

---

## Serials: copies can survive a successful run

> `NOTE: will not delete copies if issues/predictions are attached`

A serial copy carrying issue or prediction records is **skipped, not deleted**.
The bib may go while some copies remain, and the run still reports success. On a
delete list containing serials, re-count afterwards rather than assuming
everything went:

```sql
SELECT COUNT(*) AS [items_left]
FROM item i
INNER JOIN dbo.<DeleteListTable> d ON d.[bib#] = i.[bib#];
```

---

## `FK_stat_data_*` failures

KillBib writes statistics rows as it deletes. If an item on the list carries a
`location`, `collection`, or `itype` code that is **missing from its parent
table**, that insert fails on a foreign key, the delete rolls back, and the run
stops partway through.

Diagnose across the whole list before resuming:

```sql
SELECT i.location AS [missing_code], COUNT(*) AS [items],
       COUNT(DISTINCT i.[bib#]) AS [bibs]
FROM item i
INNER JOIN dbo.<DeleteListTable> d ON d.[bib#] = i.[bib#]
LEFT JOIN location l ON l.location = i.location
WHERE l.location IS NULL
GROUP BY i.location;
```

Restore the missing code to its parent table, or correct the offending items,
then resume with `/b<bib#>` from where it stopped.

**Never drop or disable the foreign key to force it through** — that writes
statistics rows pointing at a code that does not exist and corrupts the stat
tables.

`tools\Test-DeleteListPreflight.ps1` checks all three code types across the
entire list *before* KillBib starts, turning a partial, resumed run into a clean
one.

---

## Resuming a stopped run

`/b` alone restarts at a given `bib#`:

```text
KillBib.exe /s<server> /d<db> /u<login> /p<password> /r<horizon-id> /l<loc> ^
            /t<table> /k /b<bib-it-failed-on>
```

Our wrapper never resumes automatically — a partial delete that stopped for an
unexplained reason is a decision for a human holding the diagnostic. It prints
the exact resume command instead.

---

## The password is visible in the process list

KillBib takes `/p<password>` **on the command line**, and Windows exposes full
command lines to anyone who can read the process list. No wrapper can hide this;
it is inherent to the utility's interface.

Our scripts prompt for the password as a `SecureString`, never write it to disk,
never log it, and mask it in every echoed command — but during the seconds or
minutes KillBib runs, the password is readable by other processes on that
machine. Factor that into where you run it.

---

## Verified invocation

```text
KillBib.exe /sILSSERVER /dILSDB /uils_svc /p<password> ^
            /tPQ_CAT_20260825_DeleteList /rHZUSER /lLOC /k
```

Run from `C:\Program Files (x86)\SirsiDynix\Horizon_2`, against a 6,790-row
delete list, 2026-08-27.

**Status: VERIFIED COMPLETE, 2026-08-28.** All 6,790 bibs were deleted and no
item rows remained. Both post-run checks returned 0:

```sql
SELECT COUNT(*) FROM bib_control bc
INNER JOIN dbo.<DeleteListTable> d ON d.[bib#] = bc.[bib#];   -- 0
SELECT COUNT(*) FROM item i
INNER JOIN dbo.<DeleteListTable> d ON d.[bib#] = i.[bib#];    -- 0
```

The zero item count also means this particular set contained no serials with
issues or predictions attached — otherwise some copies would have survived a
successful run (see above). Do not generalise that to the next list.

See `solutions/590-proquest-new-by-creator-report/README.md` for that job's
specifics.

## Related

- [`tools/README.md`](../tools/README.md) — the wrapper scripts and batch mode
- [`schema/core/location.md`](schema/core/location.md) — orphaned location codes
- [`schema/core/item.md`](schema/core/item.md) — what `/k` removes
