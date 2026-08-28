# Authoring solution documentation

Every solution directory under `solutions/` carries three things. **One is written; two are
generated from it.**

| File | Status | Purpose |
| --- | --- | --- |
| `README.md` | **written — source of truth** | The problem, the reasoning, the review gates, the caveats |
| `sql/NN-<slug>.sql` | generated | Runnable files — open in SSMS and press F5 |
| `runbook.html` | generated | Copy-ready page, one copy button per query |

Generated files carry a header saying so. **Never hand-edit them** — the edit
would be silently destroyed on the next build, and the README would no longer
match the SQL anyone actually ran. Edit the README, then rebuild.

## Rebuilding

```powershell
# every solution
powershell -ExecutionPolicy Bypass -File tools\Build-SolutionDocs.ps1

# just one
powershell -ExecutionPolicy Bypass -File tools\Build-SolutionDocs.ps1 -Solution 590-proquest-new-by-creator-report
```

The script reads each README, extracts fenced code blocks in document order, and
attributes each to the nearest preceding heading. `sql/` is cleared and rewritten
each run; README files are never modified.

**Commit the generated files.** They are cheap, and committing them means a
colleague gets working `.sql` files and a runbook without needing PowerShell or
knowing this script exists.

### What the generator does automatically

- **Numbering follows README order**, so `01-` is the first query in the
  document and the sequence matches the order of operations described in prose.
- **Each block is tagged `READ-ONLY` or `WRITES`** by scanning for `INSERT`,
  `UPDATE`, `DELETE`, `CREATE`, `DROP`, `ALTER`, `GRANT`, `TRUNCATE`, `REVOKE`.
  This appears in the `.sql` header comment and as a coloured chip in the
  runbook, so a destructive step is visible before it is run.
- **Non-`sql` fenced blocks** (a `killbib` command line, a shell snippet) appear
  in `runbook.html` but are not emitted as `.sql` files.

### What it cannot do

The generator has no idea *why* a query exists. It does not carry across the
review gates, the row counts to reconcile against, the drift warnings, or any of
the reasoning. **The README is still required reading before running anything**,
and both generated artifacts say so in their footer.

## Viewing `runbook.html`

Be aware of what actually renders where — this is the part that most often
surprises people.

| Context | Renders? | How |
| --- | --- | --- |
| Any web browser | **Yes** | Open the file directly. It is fully self-contained. |
| VS Code | **Not natively** | VS Code has no built-in HTML preview. Either right-click → *Open in Default Browser*, or install Microsoft's **Live Preview** extension (`ms-vscode.live-server`) for an in-editor pane. |
| GitHub, browsing the repo | **No** | github.com displays `.html` as **source code**, never rendered. This is a deliberate GitHub security policy and cannot be worked around from inside the repo. |
| GitHub Pages | **Yes** | Requires enabling Pages once — see below. |

> Markdown, by contrast, renders everywhere. That is why `README.md` stays the
> source of truth and the HTML is an *additional* convenience, never a
> replacement. A reader who only ever sees the GitHub view must still get the
> whole story.

### GitHub already gives you copy buttons

Before reaching for the HTML: **GitHub renders a copy button on every fenced code
block natively.** If your colleagues read these on github.com, they can already
copy each query in one click, with no extra tooling. The runbook exists for
working locally, where that affordance is missing.

### Enabling GitHub Pages (optional, one-time)

This makes every `runbook.html` a live URL that renders properly for anyone.

1. Repository → **Settings** → **Pages**
2. **Source**: Deploy from a branch
3. **Branch**: `master`, folder `/ (root)` → **Save**

Runbooks then resolve to:

```text
https://<owner>.github.io/<repo>/solutions/590-proquest-new-by-creator-report/runbook.html
```

Two things to weigh first:

- Pages publishes the repository as a **website**. This repo is already public,
  so nothing new is exposed — but confirm that remains true before enabling it,
  and never let query output (patron or catalog data) into the repo regardless.
  The `.gitignore` rules exist for this.
- The published site includes `horizon-schema/*.csv`. That is schema metadata
  with no records in it, which is why those files are committed — but it does
  mean your table and column names become publicly browsable. Acceptable for a
  vendor ILS schema; worth a conscious decision rather than a surprise.

## Adding a new solution

1. **Scaffold it** — don't copy an existing solution by hand:

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\New-Solution.ps1 `
       -Name 245-missing-subfield-a -Type Report `
       -Summary "Bibs whose 245 has no subfield a."
   ```

   That creates `solutions/<name>/README.md` pre-filled with the structure
   `CLAUDE.md` requires — **The Problem**, then either the Audit/Update pair
   (`-Type Fix`) or a single **The Report (Read-Only)** section
   (`-Type Report`) — and appends the index line to the top-level `README.md`.

2. **Look every table and column up** in [`schema/`](schema/README.md) as you
   write. Never infer a name.

3. **Generate** the runnable files and the runbook:

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\Build-SolutionDocs.ps1 -Solution <name>
   ```

4. **Confirm the index line** landed in the top-level `README.md` (the scaffold
   adds it after the last existing entry).

5. **Commit** the README together with its generated `sql/` and `runbook.html`.

## Writing READMEs so they generate well

The generator's output is only as good as the README's structure. Three habits
that cost nothing and make it much better:

- **Give every code block a heading.** The nearest preceding `##`/`###` becomes
  the `.sql` filename and the runbook's block label. A block under a vague
  heading produces a vague filename.
- **Tag fences with a language.** ` ```sql ` blocks become `.sql` files;
  untagged fences are skipped entirely. Use ` ```text ` for command lines so
  they land in the runbook but not in `sql/`.
- **Keep headings distinct.** Two headings that slugify identically produce two
  files distinguished only by their number prefix, which is legible but not
  helpful.
