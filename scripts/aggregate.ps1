# Slår ihop databasen efter en körning:
#   index.json              - alla bevakningar med antal, storlek och tid (läses av appen)
#   <id>/overview.json      - för alla-bevakningar: dagens sammanfattning per underkategori
#   <id>/trend.json         - för alla-bevakningar: en rad per dag och underkategori (växer över tid)
#
# Användning:  scripts\aggregate.ps1 -DbDir dbdata

param([string]$DbDir = 'dbdata')
. (Join-Path $PSScriptRoot 'lib.ps1')
if (-not [IO.Path]::IsPathRooted($DbDir)) { $DbDir = Join-Path $RepoRoot $DbDir }
function Get-Med($sorted) { if (-not $sorted -or $sorted.Count -eq 0) { return $null }; return $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)] }

$watches = @(Read-Json (Join-Path $DataDir 'bevakningar.json') | Where-Object { $_ })
$valid = @{}; foreach ($w in $watches) { $valid[$w.id] = $w }
$cats = Read-Json (Join-Path $DataDir 'blocket-kategorier.json')
$catOrder = @{}; $i = 0; foreach ($c in $cats.categories) { $catOrder[$c.value] = $i++ }

# Befintligt index + nya poster från idx/
$index = [ordered]@{}
$old = Read-Db (Join-Path $DbDir 'index.json')
if ($old -and $old['watches']) { foreach ($x in $old['watches']) { $index[$x['id']] = $x } }
$idxDir = Join-Path $DbDir 'idx'
if (Test-Path $idxDir) { foreach ($f in Get-ChildItem $idxDir -Filter *.json) { $x = Read-Db $f.FullName; $index[$x['id']] = $x } }

foreach ($w in $watches | Where-Object { $_.mode -eq 'alla' }) {
  $dir = Join-Path $DbDir $w.id
  $sumDir = Join-Path $dir 'sum'
  if (-not (Test-Path $sumDir)) { continue }
  $sums = @(Get-ChildItem $sumDir -Filter *.json | ForEach-Object { Read-Db $_.FullName } | Where-Object { $_ })
  if (-not $sums.Count) { continue }
  $sums = @($sums | Sort-Object { $catOrder[$_['cat']] }, { -[int]$_['active'] })
  $day = ($sums | ForEach-Object { [int]$_['day'] } | Measure-Object -Maximum).Maximum

  # Totaler
  $tot = [ordered]@{ active = 0; total = 0; new = 0; gone = 0; gone30 = 0; value = [int64]0; priced = 0; ship = 0; company = 0; drops = 0; bytes = [int64]0; requests = 0; secs = 0; subs = $sums.Count; complete = 0 }
  $wdhr = New-Object int[] 168; $pubDays = New-Object int[] 60; $cond = New-Object int[] 6; $geo = @{}
  $hist = New-Object int[] (@($sums[0]['hist']).Count)
  foreach ($s in $sums) {
    foreach ($k in 'active', 'total', 'new', 'gone', 'gone30', 'priced', 'ship', 'company', 'drops', 'requests', 'secs') { $tot[$k] += [int]$s[$k] }
    $tot.value += [int64]$s['value']; $tot.bytes += [int64]$s['bytes']; if ($s['complete']) { $tot.complete++ }
    $stale = $day - [int]$s['day']   # en underkategori som inte kördes i dag: flytta dess dagserie
    for ($j = 0; $j -lt 168; $j++) { $wdhr[$j] += [int]$s['wdhr'][$j] }
    for ($j = 0; $j -lt 60; $j++) { $t = $j - $stale; if ($t -ge 0) { $pubDays[$t] += [int]$s['pubDays'][$j] } }
    for ($j = 0; $j -lt 6; $j++) { $cond[$j] += [int]$s['cond'][$j] }
    for ($j = 0; $j -lt $hist.Count; $j++) { $hist[$j] += [int]$s['hist'][$j] }
    foreach ($g in $s['geo']) { $k = [int]$g[0] * 1000 + [int]$g[1]; $geo[$k] = [int]$geo[$k] + [int]$g[2] }
  }
  $deals = @($sums | ForEach-Object { $s = $_; foreach ($d in $s['deals']) { , (@($d) + @($s['sub'])) } } | Sort-Object { $_[2] / $_[3] } | Select-Object -First 60)

  $overview = [ordered]@{
    v = 1; id = $w.id; name = $w.name; location = $w.location; locationName = $w.locationName; day = $day
    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    imgBase = 'https://images.blocketcdn.se/dynamic/320w/'; urlBase = 'https://www.blocket.se/recommerce/forsale/item/'
    geoGrid = [ordered]@{ lat0 = 58.6; lon0 = 16.9; dlat = 0.025; dlon = 0.045; rows = 72; cols = 66 }
    condNames = @('Okänt', 'Nytt', 'Som nytt', 'Bra skick', 'Okej skick', 'Trasigt')
    totals = $tot; wdhr = $wdhr; pubDays = $pubDays; cond = $cond; histBands = $sums[0]['histBands']; hist = $hist
    geo = @($geo.GetEnumerator() | ForEach-Object { , @([int][math]::Floor($_.Key / 1000), ($_.Key % 1000), $_.Value) })
    cats = @($cats.categories | ForEach-Object { [ordered]@{ value = $_.value; name = $_.name } })
    deals = $deals
    subs = @($sums | ForEach-Object { $s = $_; $o = [ordered]@{}; foreach ($k in $s.Keys) { if ($k -ne 'geo') { $o[$k] = $s[$k] } }; $o })
    subGeo = [ordered]@{}
  }
  foreach ($s in $sums) { $overview.subGeo[$s['sub']] = $s['geo'] }
  Write-Db (Join-Path $dir 'overview.json') $overview

  # Trend: en rad per dag. Dagens rad ersätts om körningen görs om samma dag.
  $trendFile = Join-Path $dir 'trend.json'
  $trend = Read-Db $trendFile
  $tcols = @('day', 'active', 'new', 'gone', 'p50', 'sell50', 'drops', 'value', 'within7', 'sellN')
  $series = @{}
  if ($trend -and $trend['subs']) { foreach ($k in $trend['subs'].Keys) { $series[$k] = [System.Collections.ArrayList]@($trend['subs'][$k] | Where-Object { [int]$_[0] -ne $day }) } }
  $totSeries = [System.Collections.ArrayList]@(); if ($trend -and $trend['total']) { foreach ($r in $trend['total']) { if ([int]$r[0] -ne $day) { [void]$totSeries.Add($r) } } }
  $sellAll = [System.Collections.Generic.List[int]]::new()
  foreach ($s in $sums) {
    if ([int]$s['day'] -ne $day) { continue }
    if (-not $series.ContainsKey($s['sub'])) { $series[$s['sub']] = [System.Collections.ArrayList]@() }
    [void]$series[$s['sub']].Add(@($day, $s['active'], $s['new'], $s['gone'], $s['p'][2], $s['sell']['d50'], $s['drops'], $s['value'], $s['sell']['within7'], $s['sell']['n']))
    if ($null -ne $s['sell']['d50']) { $sellAll.Add([int]$s['sell']['d50']) }
  }
  $sellAll.Sort()
  [void]$totSeries.Add(@($day, $tot.active, $tot.new, $tot.gone, $null, (Get-Med $sellAll), $tot.drops, $tot.value, $null, $null))
  $subsOut = [ordered]@{}; foreach ($k in $series.Keys) { $subsOut[$k] = @($series[$k] | Sort-Object { [int]$_[0] } | Select-Object -Last 400) }
  Write-Db $trendFile ([ordered]@{ v = 1; cols = $tcols; total = @($totSeries | Sort-Object { [int]$_[0] } | Select-Object -Last 400); subs = $subsOut })

  $index[$w.id] = [ordered]@{ id = $w.id; name = $w.name; mode = 'alla'; updatedAt = $overview.updatedAt; active = $tot.active; total = $tot.total
    gone = $tot.gone30; median = $null; complete = ($tot.complete -eq $tot.subs); secs = $tot.secs; bytes = $tot.bytes; subs = $tot.subs }
  Write-Host ("{0}: {1} underkategorier, {2} aktiva annonser, {3:N1} MB" -f $w.name, $tot.subs, $tot.active, ($tot.bytes / 1MB)) -ForegroundColor Green
}

# Ta bort borttagna bevakningar ur index och databas.
foreach ($id in @($index.Keys)) {
  if (-not $valid.ContainsKey($id)) {
    $index.Remove($id)
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $DbDir "$id.json"), (Join-Path $DbDir $id), (Join-Path $idxDir "$id.json")
  }
}
Write-Db (Join-Path $DbDir 'index.json') ([ordered]@{ updatedAt = (Get-Date).ToUniversalTime().ToString('o'); watches = @($index.Values) })
Write-Host "Index: $($index.Count) bevakningar."
