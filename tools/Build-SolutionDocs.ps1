<#
.SYNOPSIS
    Generates runnable .sql files and a copy-ready runbook.html from a solution
    directory's README.md.

.DESCRIPTION
    The README.md remains the source of truth. This script derives two things
    from it, so they can never drift out of step with the prose:

      <solution>/sql/NN-<slug>.sql   one file per ```sql block, in README order
      <solution>/runbook.html        self-contained page, copy button per block

    Both outputs are GENERATED. Never hand-edit them — edit the README and
    re-run. Each generated file says so in its own header.

    A block is tagged READ-ONLY or WRITES automatically, by looking for
    INSERT / UPDATE / DELETE / CREATE / DROP / ALTER / GRANT / TRUNCATE.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Build-SolutionDocs.ps1
    powershell -ExecutionPolicy Bypass -File tools\Build-SolutionDocs.ps1 -Solution 590-proquest-new-by-creator-report
#>

[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $Solution      # omit to build every solution directory
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot  = Split-Path -Parent $scriptDir
}

function ConvertTo-HtmlText {
    param([string] $Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

function ConvertTo-Slug {
    param([string] $Text)
    $s = $Text.ToLower()
    $s = $s -replace '`', ''
    $s = $s -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 48) { $s = $s.Substring(0,48).Trim('-') }
    if (-not $s) { $s = 'query' }
    return $s
}

# ---------------------------------------------------------------------------
# Parse a README into ordered blocks: heading + language + code
# ---------------------------------------------------------------------------
function Get-ReadmeBlocks {
    param([string] $Path)

    $lines   = Get-Content -Path $Path -Encoding UTF8
    $blocks  = New-Object System.Collections.ArrayList
    $heading = 'Query'
    $inFence = $false
    $lang    = ''
    $buffer  = $null

    foreach ($line in $lines) {
        if (-not $inFence -and $line -match '^\s*#{2,4}\s+(.*)$') {
            # Strip markdown emphasis/backticks from the heading text
            $h = $Matches[1]
            $h = $h -replace '`', ''
            $h = $h -replace '\*\*', ''
            $h = $h -replace '\s*—.*$', ''      # drop em-dash subtitle
            $h = $h -replace '\s*&mdash;.*$', ''
            $heading = $h.Trim()
            continue
        }
        if ($line -match '^\s*```(\w*)\s*$') {
            if ($inFence) {
                $code = ($buffer -join "`n").TrimEnd()
                if ($code) {
                    [void] $blocks.Add([pscustomobject]@{
                        Heading = $heading
                        Lang    = $lang
                        Code    = $code
                    })
                }
                $inFence = $false
                $buffer  = $null
            } else {
                $inFence = $true
                $lang    = $Matches[1].ToLower()
                $buffer  = New-Object System.Collections.ArrayList
            }
            continue
        }
        if ($inFence) { [void] $buffer.Add($line) }
    }
    return $blocks
}

function Test-IsWrite {
    <#
        Fails CLOSED. A green "READ-ONLY" chip on a generated runbook is a
        safety assertion, so anything this cannot positively prove is read-only
        is reported as a write. A keyword allow-list would stamp MERGE,
        SELECT ... INTO, EXEC, and ;WITH cte AS (...) UPDATE as safe.
    #>
    param([string] $Code)

    # Strip comments and string literals so keywords inside them do not count.
    $bare = $Code -replace '(?m)--[^\n]*', ' ' -replace "'(?:''|[^'])*'", " '' "

    if ($bare -match '(?im)\b(INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|GRANT|REVOKE|TRUNCATE|MERGE|EXEC|EXECUTE|BACKUP|RESTORE|DENY|SET\s+LOCK_TIMEOUT)\b') { return $true }
    if ($bare -match '(?is)\bSELECT\b.*\bINTO\b\s+[\[\w#]') { return $true }   # SELECT ... INTO
    if ($bare -match '(?im)^\s*;?\s*WITH\b')                    { return $true }   # CTE may front an UPDATE
    return $false
}

# ---------------------------------------------------------------------------
# HTML shell. {{TITLE}} {{SUBTITLE}} {{SOURCE}} {{BODY}} are substituted.
# Single-quoted here-string: nothing inside is interpolated by PowerShell.
# ---------------------------------------------------------------------------
$htmlTemplate = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITLE}}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600;700&display=swap">
<style>
:root{
  --bg:#F3F5F7; --surface:#FFFFFF; --surface-2:#E9EDF1;
  --ink:#161C23; --ink-2:#48545F; --ink-3:#6F7D89;
  --rule:#D9E0E6; --rule-2:#C3CDD6;
  --accent:#175C6E; --accent-soft:#DFEDF1;
  --safe:#2B6F53; --safe-soft:#E0EFE7;
  --warn:#8F5602; --warn-soft:#F7EBD8;
  --code-bg:#EFF3F6; --code-ink:#1B242D;
  --kw:#175C6E; --str:#8F5602; --com:#77858F; --num:#7A3E8C;
  --shadow:0 1px 2px rgba(22,28,35,.05), 0 4px 14px rgba(22,28,35,.05);
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    --bg:#0F1419; --surface:#171D24; --surface-2:#1F272F;
    --ink:#E4EAF0; --ink-2:#A9B6C2; --ink-3:#7C8C99;
    --rule:#2A343D; --rule-2:#3A464F;
    --accent:#4FB6CE; --accent-soft:#16323A;
    --safe:#6BC195; --safe-soft:#152C22;
    --warn:#D9A046; --warn-soft:#31260F;
    --code-bg:#121820; --code-ink:#D3DBE3;
    --kw:#6FCCE1; --str:#D9A046; --com:#6E7C88; --num:#C79BD8;
    --shadow:0 1px 2px rgba(0,0,0,.4), 0 4px 14px rgba(0,0,0,.3);
  }
}
:root[data-theme="dark"]{
  --bg:#0F1419; --surface:#171D24; --surface-2:#1F272F;
  --ink:#E4EAF0; --ink-2:#A9B6C2; --ink-3:#7C8C99;
  --rule:#2A343D; --rule-2:#3A464F;
  --accent:#4FB6CE; --accent-soft:#16323A;
  --safe:#6BC195; --safe-soft:#152C22;
  --warn:#D9A046; --warn-soft:#31260F;
  --code-bg:#121820; --code-ink:#D3DBE3;
  --kw:#6FCCE1; --str:#D9A046; --com:#6E7C88; --num:#C79BD8;
  --shadow:0 1px 2px rgba(0,0,0,.4), 0 4px 14px rgba(0,0,0,.3);
}
*{box-sizing:border-box;}
body{
  margin:0;background:var(--bg);color:var(--ink);
  font-family:"IBM Plex Sans","Segoe UI",system-ui,-apple-system,sans-serif;
  font-size:16px;line-height:1.6;-webkit-font-smoothing:antialiased;
}
.wrap{max-width:62rem;margin:0 auto;padding:2.5rem 1.25rem 5rem;}
.masthead{display:flex;flex-direction:column;gap:.7rem;padding-bottom:1.4rem;
  margin-bottom:2rem;border-bottom:2px solid var(--ink);}
.eyebrow{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.7rem;
  font-weight:500;letter-spacing:.13em;text-transform:uppercase;color:var(--accent);}
h1{margin:0;font-size:clamp(1.6rem,3.6vw,2.3rem);line-height:1.15;font-weight:700;
  letter-spacing:-.02em;text-wrap:balance;}
.standfirst{margin:0;max-width:60ch;color:var(--ink-2);font-size:1.0625rem;}
.gen{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.72rem;
  color:var(--ink-3);}
.gen code{background:var(--surface-2);padding:.1em .35em;border-radius:3px;}
.step{background:var(--surface);border:1px solid var(--rule);border-radius:8px;
  margin-bottom:1.1rem;box-shadow:var(--shadow);overflow:hidden;}
.step-head{display:flex;align-items:flex-start;gap:.9rem;padding:1rem 1.2rem;}
.step-num{flex:0 0 auto;width:1.9rem;height:1.9rem;border-radius:5px;display:grid;
  place-items:center;font-family:"IBM Plex Mono",ui-monospace,monospace;
  font-size:.8rem;font-weight:600;background:var(--surface-2);color:var(--ink-2);
  border:1px solid var(--rule-2);font-variant-numeric:tabular-nums;}
.step-title{flex:1 1 auto;min-width:0;}
.step-title h2{margin:0;font-size:1.0625rem;font-weight:600;letter-spacing:-.01em;
  line-height:1.3;text-wrap:balance;}
.chip{align-self:flex-start;flex:0 0 auto;font-family:"IBM Plex Mono",ui-monospace,monospace;
  font-size:.625rem;font-weight:600;letter-spacing:.09em;text-transform:uppercase;
  padding:.28rem .5rem;border-radius:4px;white-space:nowrap;}
.chip.read{background:var(--safe-soft);color:var(--safe);}
.chip.write{background:var(--warn-soft);color:var(--warn);}
.codewrap{position:relative;border-top:1px solid var(--rule);background:var(--code-bg);}
.codebar{display:flex;align-items:center;justify-content:space-between;gap:1rem;
  padding:.45rem .7rem .45rem 1.2rem;border-bottom:1px solid var(--rule);}
.codelabel{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.65rem;
  letter-spacing:.1em;text-transform:uppercase;color:var(--ink-3);}
button.copy{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.7rem;
  font-weight:600;letter-spacing:.04em;padding:.4rem .7rem;border-radius:5px;
  cursor:pointer;background:var(--surface);color:var(--accent);
  border:1px solid var(--rule-2);
  transition:background .15s ease,border-color .15s ease,color .15s ease;}
button.copy:hover{background:var(--accent-soft);border-color:var(--accent);}
button.copy:focus-visible{outline:2px solid var(--accent);outline-offset:2px;}
button.copy.done{background:var(--safe-soft);color:var(--safe);border-color:var(--safe);}
pre{margin:0;padding:1.05rem 1.2rem;overflow-x:auto;
  font-family:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
  font-size:.8125rem;line-height:1.65;color:var(--code-ink);tab-size:4;}
pre code{font:inherit;color:inherit;}
.tok-kw{color:var(--kw);font-weight:600;}
.tok-str{color:var(--str);}
.tok-com{color:var(--com);font-style:italic;}
.tok-num{color:var(--num);}
footer{margin-top:3rem;padding-top:1.2rem;border-top:1px solid var(--rule);
  font-size:.8125rem;color:var(--ink-3);}
footer code{background:var(--surface-2);padding:.1em .35em;border-radius:3px;}
@media (prefers-reduced-motion: reduce){*{transition:none !important;animation:none !important;}}
</style>
</head>
<body>
<div class="wrap">
<header class="masthead">
  <div class="eyebrow">SirsiDynix Horizon &middot; Runbook</div>
  <h1>{{TITLE}}</h1>
  <p class="standfirst">{{SUBTITLE}}</p>
  <p class="gen">Generated from <code>{{SOURCE}}</code> &mdash; do not edit this file.</p>
</header>
{{BODY}}
<footer>
  The solution <code>README.md</code> is the source of truth; this page and the
  <code>sql/</code> files are generated from it by
  <code>tools/Build-SolutionDocs.ps1</code>. Read the README for the reasoning,
  the review gates, and the caveats &mdash; they are not reproduced here.
  Never enter real logins or passwords into a shared document.
</footer>
</div>
<script>
(function(){
  var KW = ["SELECT","FROM","WHERE","AND","OR","NOT","EXISTS","INNER","OUTER","LEFT","RIGHT","JOIN",
    "ON","GROUP","BY","ORDER","HAVING","INSERT","INTO","VALUES","UPDATE","DELETE","CREATE","TABLE",
    "DROP","ALTER","COLUMN","CONSTRAINT","PRIMARY","KEY","CLUSTERED","NONCLUSTERED","UNIQUE","INDEX",
    "GRANT","REVOKE","BEGIN","COMMIT","ROLLBACK","TRANSACTION","AS","IS","NULL","IN","BETWEEN","LIKE",
    "CASE","WHEN","THEN","ELSE","END","TOP","DISTINCT","CROSS","APPLY","IF","GO","COUNT","SUM","MIN",
    "MAX","DATEDIFF","DATEADD","DATENAME","CAST","CONVERT","RTRIM","LTRIM","LEN","SUBSTRING",
    "CHARINDEX","NULLIF","COALESCE","CHAR","OBJECT_ID","SCHEMA_NAME","TYPE_NAME","INT","SMALLINT",
    "VARCHAR","DESC","ASC","SET","WITH","UNION","ALL","COLLATE","ESCAPE","ROLLUP","OVER"];
  var re = new RegExp(
    "(--[^\\n]*)" + "|('(?:''|[^'])*')" + "|(\\b\\d+\\b)" + "|(@@?\\w+)" +
    "|\\b(" + KW.join("|") + ")\\b", "gi");
  function esc(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");}
  function highlight(src){
    var out="",last=0,m; re.lastIndex=0;
    while((m=re.exec(src))!==null){
      out+=esc(src.slice(last,m.index));
      if(m[1])      out+='<span class="tok-com">'+esc(m[1])+"</span>";
      else if(m[2]) out+='<span class="tok-str">'+esc(m[2])+"</span>";
      else if(m[3]) out+='<span class="tok-num">'+esc(m[3])+"</span>";
      else if(m[4]) out+='<span class="tok-num">'+esc(m[4])+"</span>";
      else          out+='<span class="tok-kw">'+esc(m[5])+"</span>";
      last=m.index+m[0].length;
    }
    return out+esc(src.slice(last));
  }
  function copyText(text,btn){
    var done=function(){
      var old=btn.getAttribute("data-label");
      btn.textContent="Copied"; btn.classList.add("done");
      setTimeout(function(){btn.textContent=old;btn.classList.remove("done");},1600);
    };
    var fallback=function(){
      var ta=document.createElement("textarea");
      ta.value=text; ta.setAttribute("readonly","");
      ta.style.position="fixed"; ta.style.top="-1000px";
      document.body.appendChild(ta); ta.select();
      try{document.execCommand("copy");done();}
      catch(e){btn.textContent="Press Ctrl+C";}
      document.body.removeChild(ta);
    };
    if(navigator.clipboard&&navigator.clipboard.writeText){
      navigator.clipboard.writeText(text).then(done,fallback);
    } else { fallback(); }
  }
  Array.prototype.forEach.call(document.querySelectorAll(".codewrap"),function(wrap){
    var code=wrap.querySelector("code"), btn=wrap.querySelector("button.copy");
    if(!code||!btn) return;
    var raw=code.textContent;
    code.innerHTML=highlight(raw);
    btn.setAttribute("data-label",btn.textContent);
    btn.addEventListener("click",function(){copyText(raw,btn);});
  });
})();
</script>
</body>
</html>
'@

# ---------------------------------------------------------------------------
# Build one solution
# ---------------------------------------------------------------------------
function Build-Solution {
    param([string] $Dir)

    $name   = Split-Path -Leaf $Dir
    $readme = Join-Path $Dir 'README.md'
    if (-not (Test-Path $readme)) {
        Write-Warning "No README.md in $name - skipped."
        return
    }

    $blocks = @(Get-ReadmeBlocks -Path $readme)
    $sqlBlocks = @($blocks | Where-Object { $_.Lang -eq 'sql' })
    if ($sqlBlocks.Count -eq 0) {
        Write-Host "  $name - no SQL blocks, skipped."
        return
    }

    # --- title / subtitle from the README's H1 and first paragraph ---
    $lines = Get-Content -Path $readme -Encoding UTF8
    $title = $name
    foreach ($l in $lines) { if ($l -match '^#\s+(.*)$') { $title = ($Matches[1] -replace '`',''); break } }
    $subtitle = "Copy-ready queries extracted from this solution's README."

    # --- .sql files ---
    $sqlDir = Join-Path $Dir 'sql'
    if (-not (Test-Path $sqlDir)) { New-Item -ItemType Directory -Path $sqlDir -Force | Out-Null }
    Get-ChildItem -Path $sqlDir -Filter '*.sql' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $i = 0
    foreach ($b in $sqlBlocks) {
        $i++
        $num  = '{0:D2}' -f $i
        $slug = ConvertTo-Slug -Text $b.Heading
        $file = Join-Path $sqlDir "$num-$slug.sql"
        if (Test-IsWrite -Code $b.Code) { $kind = 'WRITES - review before running' }
        else { $kind = 'READ-ONLY' }

        $header = @()
        $header += "-- $($b.Heading)"
        $header += "-- $kind"
        $header += "--"
        $header += "-- GENERATED from $name/README.md by tools/Build-SolutionDocs.ps1."
        $header += "-- Do not edit this file - edit the README and re-run the script."
        $header += "-- The README carries the reasoning, review gates and caveats."
        $header += ""
        $header += ""
        ($header -join "`r`n") + $b.Code | Out-File -FilePath $file -Encoding utf8
    }

    # --- runbook.html ---
    $sb = New-Object System.Text.StringBuilder
    $n = 0
    foreach ($b in $blocks) {
        $n++
        if (Test-IsWrite -Code $b.Code) { $chipCls = 'write'; $chipTxt = 'Writes' }
        else { $chipCls = 'read'; $chipTxt = 'Read-only' }
        if ($b.Lang -ne 'sql') { $chipCls = 'read'; $chipTxt = $b.Lang.ToUpper() }

        [void] $sb.AppendLine('<section class="step">')
        [void] $sb.AppendLine('  <div class="step-head">')
        [void] $sb.AppendLine("    <div class=`"step-num`">$n</div>")
        [void] $sb.AppendLine('    <div class="step-title">')
        [void] $sb.AppendLine("      <h2>$(ConvertTo-HtmlText $b.Heading)</h2>")
        [void] $sb.AppendLine('    </div>')
        [void] $sb.AppendLine("    <span class=`"chip $chipCls`">$chipTxt</span>")
        [void] $sb.AppendLine('  </div>')
        [void] $sb.AppendLine('  <div class="codewrap">')
        [void] $sb.AppendLine("    <div class=`"codebar`"><span class=`"codelabel`">$(ConvertTo-HtmlText $b.Heading)</span><button class=`"copy`">Copy</button></div>")
        [void] $sb.AppendLine("    <pre><code>$(ConvertTo-HtmlText $b.Code)</code></pre>")
        [void] $sb.AppendLine('  </div>')
        [void] $sb.AppendLine('</section>')
    }

    $html = $htmlTemplate
    $html = $html.Replace('{{TITLE}}',    (ConvertTo-HtmlText $title))
    $html = $html.Replace('{{SUBTITLE}}', (ConvertTo-HtmlText $subtitle))
    $html = $html.Replace('{{SOURCE}}',   (ConvertTo-HtmlText "$name/README.md"))
    $html = $html.Replace('{{BODY}}',     $sb.ToString())

    $out = Join-Path $Dir 'runbook.html'
    $html | Out-File -FilePath $out -Encoding utf8

    Write-Host ("  {0} - {1} sql file(s), {2} block(s) in runbook.html" -f $name, $sqlBlocks.Count, $blocks.Count)
}

# ---------------------------------------------------------------------------
if ($Solution) {
    # Accept either a bare name ("590-proquest-new-by-creator-report") or a
    # path already including the solutions/ prefix.
    $cand = Join-Path (Join-Path $RepoRoot 'solutions') $Solution
    if (-not (Test-Path $cand)) { $cand = Join-Path $RepoRoot $Solution }
    if (-not (Test-Path $cand)) { throw "Solution not found: $Solution" }
    $dirs = @($cand)
} else {
    # Solutions live under solutions/. Anything else at the repo root is
    # infrastructure (docs, tools, schema exports) and is never a solution.
    $solRoot = Join-Path $RepoRoot 'solutions'
    if (-not (Test-Path $solRoot)) { throw "No solutions directory at $solRoot" }
    $dirs = Get-ChildItem -Path $solRoot -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName 'README.md') } |
            ForEach-Object { $_.FullName }
}

Write-Host "Building solution docs:"
foreach ($d in $dirs) { Build-Solution -Dir $d }
Write-Host ""
Write-Host "Done. README.md files were not modified."
