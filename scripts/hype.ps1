# Hype: saker som kan säljas över nypris i Sverige.
#
# 1. Bevakade (data/hype.json): för varje vara hämtas sålda priser på Tradera och utropspriser på Blocket,
#    så att appen kan jämföra med nypriset. En rad per dag sparas, så att man ser om priset faller.
# 2. Hett just nu (automatiskt): bland alla oanvända saker som sålts på Tradera senaste 30 dagarna (databasen
#    från tradera.ps1) letas varutyper upp där många säljs med budkrig. Det fångar nya hypevaror som ingen har listat.
#
# Skriver <DbDir>/hype/hype.json. Körs i nattens databaskörning efter kombo.ps1.
# Användning:  scripts\hype.ps1 -DbDir dbdata

param([string]$DbDir = 'dbdata', [int]$DelayMs = 900, [switch]$NoScrape)
. (Join-Path $PSScriptRoot 'lib.ps1')
if (-not [IO.Path]::IsPathRooted($DbDir)) { $DbDir = Join-Path $RepoRoot $DbDir }
$t0 = Get-Date
$Today = [int][math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) / 86400)
$outFile = Join-Path $DbDir 'hype\hype.json'
$old = Read-Db $outFile
$hist = @{}; if ($old -and $old['items']) { foreach ($x in $old['items']) { $hist[[string]$x['id']] = $x['hist'] } }

function Get-S($st) {
  if (-not $st -or -not $st.n) { return $null }
  return [ordered]@{ n = [int]$st.n; med = $st.med; p25 = $st.p25; p75 = $st.p75 }
}

# ---------- 1. bevakade varor ----------
$cfg = Read-Json (Join-Path $DataDir 'hype.json')
$items = [System.Collections.Generic.List[object]]::new()
foreach ($it in $cfg.items) {
  $id = [string]$it.id
  $entry = [ordered]@{ id = $id; t = $null; b = $null; list = @(); hist = @(); err = '' }
  if (-not $NoScrape) {
    try {
      # Bara oanvända på Tradera: hype handlar om att sälja nytt. "used": true i hype.json stänger av det.
      $r = Invoke-Term -Q $it.q -Cat 'Övrigt' -Must $it.must -DelayMs $DelayMs -NewOnly:($it.used -ne $true)
      $entry.t = Get-S $r.tradera.stats; $entry.b = Get-S $r.blocket.stats
      $entry.list = @($r.listings | Where-Object { $_.s -eq 't' } | Select-Object -First 4) + @($r.listings | Where-Object { $_.s -eq 'b' } | Select-Object -First 4) |
        ForEach-Object { , @([string]$_.s, [string]$_.t, [int]$_.p, [string]$_.img, [string]$_.u) }
      if ($r.errors) { $entry.err = ($r.errors -join '; ') }
    } catch { $entry.err = $_.Exception.Message }
  }
  # Historik: en rad per dag [dag, Tradera median, antal, Blocket median, antal]
  $h = [System.Collections.ArrayList]::new()
  if ($hist.ContainsKey($id) -and $hist[$id]) { foreach ($row in $hist[$id]) { if ([int]$row[0] -ne $Today) { [void]$h.Add($row) } } }
  if ($entry.t -or $entry.b) { [void]$h.Add(@($Today, $(if ($entry.t) { $entry.t.med } else { $null }), $(if ($entry.t) { $entry.t.n } else { 0 }), $(if ($entry.b) { $entry.b.med } else { $null }), $(if ($entry.b) { $entry.b.n } else { 0 }))) }
  elseif (($entry.err -or $NoScrape) -and $old -and $old['items']) { $prev = @($old['items'] | Where-Object { $_['id'] -eq $id })[0]; if ($prev) { $entry.t = $prev['t']; $entry.b = $prev['b']; $entry.list = $prev['list'] } }
  if ($h.Count -gt 180) { $h.RemoveRange(0, $h.Count - 180) }
  $entry.hist = $h.ToArray()
  $items.Add($entry)
  Write-Host ("{0,-45} Tradera {1,4} st {2,8} kr   Blocket {3,4} st {4,8} kr {5}" -f $it.name, $(if ($entry.t) { $entry.t.n } else { 0 }), $(if ($entry.t) { $entry.t.med } else { '–' }), $(if ($entry.b) { $entry.b.n } else { 0 }), $(if ($entry.b) { $entry.b.med } else { '–' }), $entry.err)
}

# ---------- 2. hett just nu: oanvända saker med budkrig på Tradera ----------
$stop = @{}; foreach ($w in ('och med till för som från utan inte helt nytt nya ny oanvänd oanvänt oanvända oöppnad oöppnat oöppnade inplastad inplastat förseglad sealed ' +
    'förpackning kartong original orginal storlek stl strl färg svart vit vita blå röd grön grå rosa set paket st styck the and for with new size black white ' +
    'auktion utrop frakt fraktfritt gratis köp nu fint fin bra skick mycket gott okej defekt äkta helt sällsynt rare limited edition ' +
    'pack box pro ultra totalt collection retro påsar påse card game cards kort del delar övrigt mix blandat lot parti olika').Split(' ')) { if ($w) { $stop[$w] = 1 } }
$hot = @{}
$tdir = Join-Path $DbDir 'tradera'
$nRows = 0
if (Test-Path $tdir) {
  foreach ($f in Get-ChildItem $tdir -Filter *.json) {
    $d = Read-Db $f.FullName
    if (-not $d -or -not $d['rows'] -or -not $d['cols']) { continue }
    $ci = @{}; $i = 0; foreach ($c in $d['cols']) { $ci[[string]$c] = $i++ }
    foreach ($r in $d['rows']) {
      if ([string]$r[$ci['cond']] -ne 'Oanvänt') { continue }
      if ($Today - [int][math]::Floor([double]$r[$ci['end']] / 86400) -gt 30) { continue }
      $p = [int]$r[$ci['p']]; if ($p -lt 100) { continue }
      $nRows++
      $words = @(([regex]::Matches(([string]$r[$ci['t']]).ToLowerInvariant(), '[\p{L}\p{N}]+') | ForEach-Object { $_.Value }) | Where-Object { $_.Length -ge 3 -and -not $stop.ContainsKey($_) -and $_ -notmatch '^\d+\p{L}{0,3}$' })
      $keys = @{}; foreach ($w in $words) { $keys[$w] = 1 }; for ($k = 0; $k + 1 -lt $words.Count; $k++) { if ($words[$k] -ne $words[$k + 1]) { $keys["$($words[$k]) $($words[$k + 1])"] = 1 } }
      $type = [int]$r[$ci['type']]; $bids = [int]$r[$ci['bids']]; $p0 = [int]$r[$ci['p0']]
      foreach ($k in $keys.Keys) {
        if (-not $hot.ContainsKey($k)) { $hot[$k] = @{ p = [System.Collections.Generic.List[int]]::new(); bids = 0; auc = 0; over = 0; ex = [System.Collections.Generic.List[object]]::new(); cats = @{}; ids = [System.Collections.Generic.HashSet[long]]::new() } }
        $o = $hot[$k]; $o.p.Add($p); [void]$o.ids.Add([int64]$r[$ci['id']])
        if ($type -le 2) { $o.auc++; $o.bids += $bids; if ($p0 -gt 0 -and $p -ge $p0 * 1.5) { $o.over++ } }
        $o.cats[$f.BaseName] = 1 + [int]$o.cats[$f.BaseName]
        if ($o.ex.Count -lt 12) { $o.ex.Add(@([int64]$r[$ci['id']], [string]$r[$ci['t']], $p, [string]$r[$ci['img']], $bids)) }
      }
    }
  }
}
$cand = foreach ($kv in $hot.GetEnumerator()) {
  $o = $kv.Value; $n = $o.p.Count
  if ($n -lt 8 -or $o.auc -lt 5) { continue }
  $o.p.Sort(); $med = $o.p[[int][math]::Floor(($n - 1) / 2)]
  $bidsAvg = $o.bids / $o.auc
  if ($med -lt 150 -or $bidsAvg -lt 4) { continue }
  [pscustomobject]@{ k = $kv.Key; n = $n; med = $med; p25 = $o.p[[int][math]::Floor(($n - 1) * 0.25)]; p75 = $o.p[[int][math]::Floor(($n - 1) * 0.75)]
    bids = [math]::Round($bidsAvg, 1); over = [math]::Round($o.over / $o.auc, 2); score = $n * $bidsAvg * [math]::Log10($med); o = $o }
}
# Ordpar före enstaka ord: ett ord som nästan bara förekommer i ett visst ordpar visas som ordparet.
$byK = @{}; foreach ($c in $cand) { $byK[$c.k] = $c }
$skip = @{}
foreach ($c in $cand) { if ($c.k.Contains(' ')) { foreach ($u in $c.k.Split(' ')) { if ($byK.ContainsKey($u) -and $c.n -ge 0.6 * $byK[$u].n) { $skip[$u] = 1 } } } }
# Samma annonser under två namn ("zelda ocarina" och "ocarina time"): behåll det starkaste.
$kept = [System.Collections.Generic.List[object]]::new()
foreach ($c in @($cand | Where-Object { -not $skip.ContainsKey($_.k) } | Sort-Object score -Descending)) {
  $ids = $c.o.ids
  $dup = $false; foreach ($k in $kept) { $same = 0; foreach ($x in $ids) { if ($k.ids.Contains($x)) { $same++ } }; if ($same -ge 0.7 * [math]::Min($ids.Count, $k.ids.Count)) { $dup = $true; break } }
  if (-not $dup) { $kept.Add([pscustomobject]@{ c = $c; ids = $ids }) }
  if ($kept.Count -ge 30) { break }
}
$hotOut = @($kept | ForEach-Object { $_.c } | ForEach-Object {
    $ex = @($_.o.ex | Sort-Object { -[int]$_[4] } | Select-Object -First 4)
    [ordered]@{ k = $_.k; n = $_.n; med = $_.med; p25 = $_.p25; p75 = $_.p75; bids = $_.bids; over = $_.over; ex = $ex }
  })

Write-Db $outFile ([ordered]@{ v = 1; day = $Today; updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    traderaImg = 'https://img.tradera.net/250-square/'; traderaUrl = 'https://www.tradera.com/item/'
    items = $items.ToArray(); hot = $hotOut; hotRows = $nRows })
Write-Host ("Hype: {0} bevakade, {1} heta varutyper ur {2} oanvända sålda, {3:N0} s" -f $items.Count, $hotOut.Count, $nRows, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor Green
