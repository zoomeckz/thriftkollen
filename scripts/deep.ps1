# Djupscrape: hämtar ALLA annonser i en Blocket-kategori (eller sökning) och bygger en databas med historik.
#
# Blocket visar max 50 sidor (ca 2 500 annonser) per sökning. Stora sökningar delas därför upp
# per län, sedan per kommun och sist per prisintervall (som halveras tills varje del ryms).
# En extra omgång per skick taggar annonsernas skick.
#
# Två sorters bevakningar (data/bevakningar.json):
#   vanlig   - en kategori/sökning, sparas som <id>.json
#   mode=alla - HELA Blocket i ett område, en fil per underkategori: <id>/<underkategori>.json
#               plus en sammanfattning per underkategori: <id>/sum/<underkategori>.json
#               (scripts/aggregate.ps1 slår ihop sammanfattningarna till overview.json och trend.json)
#
# Per annons sparas: rubrik, pris, första pris, prishistorik, bild, antal bilder, ort, län, koordinater,
# märke, skick, frakt/köp nu/företag, publiceringstid, först sedd, senast sedd och när den försvann.
# Försvunna annonser = sålda eller borttagna. Det ger säljtid och säljtakt.
#
# Användning:
#   scripts\deep.ps1 -Watch alla|nya|<id>[,<id>] [-Subs 1.78.5196,1.78.5222] -DbDir dbdata [-OutDir ut]

param(
  [string]$Watch = 'alla',
  [string]$Subs = '',
  [string]$DbDir = 'dbdata',
  [string]$OutDir = '',
  [int]$DelayMs = 300
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$Base = 'https://www.blocket.se/recommerce/forsale/search/api/search/SEARCH_ID_BAP_COMMON'
$SplitAt = 2400                      # över så här många träffar delas sökningen upp
# Kompakt radformat (v2): img = bara bildens uuid (sökvägen är item/<id>/<uuid>), reg = tomt när det är bevakningens
# område, och "senast sedd" sparas inte (aktiva annonser sågs i dag, försvunna dagen innan de försvann). Ca 20 % mindre filer.
$Cols = @('id', 't', 'p', 'p0', 'img', 'n', 'loc', 'reg', 'lat', 'lon', 'brand', 'cond', 'fl', 'pub', 'first', 'gone', 'ph')
$C = @{}; for ($i = 0; $i -lt $Cols.Count; $i++) { $C[$Cols[$i]] = $i }
# fl (flaggor): 1 = kan skickas, 2 = köp nu, 4 = företag, 8 = gratis frakt
$Today = [int][math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) / 86400)
$Tz = [TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time')
$HistBands = @(0, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000)
# Rutnät för kartan: ca 2,8 x 2,6 km per ruta.
$Geo = @{ lat0 = 58.6; lon0 = 16.9; dlat = 0.025; dlon = 0.045; rows = 72; cols = 66 }

if (-not [IO.Path]::IsPathRooted($DbDir)) { $DbDir = Join-Path $RepoRoot $DbDir }
if (-not $OutDir) { $OutDir = $DbDir } elseif (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $RepoRoot $OutDir }
foreach ($d in @($DbDir, $OutDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null } }

# "item/12345/abc-uuid" -> "abc-uuid" (läses tillbaka med Expand-Img / i appen)
function Compress-Img([string]$p) { if ($p -match '^item/\d+/([^/]+)$') { return $Matches[1] }; return $p }
function Expand-Img($id, [string]$p) { if (-not $p -or $p.Contains('/')) { return $p }; return "item/$id/$p" }
function ConvertTo-Hash($o) {
  if ($null -eq $o) { return $null }
  $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }; return $h
}
function Get-Med($sorted) { if (-not $sorted -or $sorted.Count -eq 0) { return $null }; return $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)] }
function Get-Q($sorted, [double]$q) { if (-not $sorted -or $sorted.Count -eq 0) { return $null }; return $sorted[[int][math]::Floor(($sorted.Count - 1) * $q)] }

$script:Req = 0
function Get-Search([hashtable]$params, [int]$page) {
  $qs = @("sort=PUBLISHED_DESC", "page=$page")
  foreach ($k in $params.Keys) { if ($null -ne $params[$k] -and "$($params[$k])" -ne '') { $qs += "$k=$([uri]::EscapeDataString([string]$params[$k]))" } }
  $url = "$Base`?" + ($qs -join '&')
  for ($try = 0; $try -lt 4; $try++) {
    try {
      $script:Req++
      $j = (Get-Text $url) | ConvertFrom-Json
      Start-Sleep -Milliseconds $DelayMs
      return $j
    } catch { Start-Sleep -Seconds (5 * ($try + 1)) }
  }
  throw "Blocket svarade inte: $url"
}

# Nästa prisuppdelning: [lägsta, högsta] -> två halvor. $null = ingen övre gräns.
function Split-Price($lo, $hi) {
  if ($null -eq $hi) { $mid = [math]::Max(1000, $lo * 3); return @(@($lo, ($mid - 1)), @($mid, $null)) }
  if ($hi -le $lo) { return $null }
  $mid = [int][math]::Floor(($lo + $hi) / 2)
  return @(@($lo, $mid), @(($mid + 1), $hi))
}

# Går igenom en sökning, delar upp den om den är för stor, och anropar $OnDoc för varje annons.
function Invoke-Collect([hashtable]$params, [string]$region, $state, [scriptblock]$OnDoc) {
  if ($state.capped) { return }
  $j = Get-Search $params 1
  $total = [int]$j.metadata.result_size.match_count
  $last = [int]$j.metadata.paging.last
  if ($total -gt $SplitAt) {
    $locF = $j.filters | Where-Object { $_.name -eq 'location' }
    if (-not $params.ContainsKey('location')) {
      $items = @($locF.filter_items | Where-Object { $_.hits -gt 0 })
      if ($items.Count -gt 1) {
        foreach ($it in $items) { $p2 = $params.Clone(); $p2['location'] = $it.value; Invoke-Collect $p2 $it.display_name $state $OnDoc }
        return
      }
    } elseif ("$($params['location'])" -like '0.*' -and -not $params.ContainsKey('price_from')) {
      # Län -> kommuner
      $reg = @($locF.filter_items | Where-Object { $_.value -eq $params['location'] })[0]
      $items = @($reg.filter_items | Where-Object { $_.hits -gt 0 })
      if ($items.Count -gt 1) {
        foreach ($it in $items) { $p2 = $params.Clone(); $p2['location'] = $it.value; Invoke-Collect $p2 $region $state $OnDoc }
        return
      }
    }
    $lo = if ($params.ContainsKey('price_from')) { [int]$params['price_from'] } else { 0 }
    $hi = if ($params.ContainsKey('price_to')) { [int]$params['price_to'] } else { $null }
    $halves = Split-Price $lo $hi
    if ($halves) {
      foreach ($h in $halves) {
        $p2 = $params.Clone(); $p2['price_from'] = $h[0]
        if ($null -ne $h[1]) { $p2['price_to'] = $h[1] } else { $p2.Remove('price_to') }
        Invoke-Collect $p2 $region $state $OnDoc
      }
      return
    }
    $state.truncated = $true
    Write-Host "   OBS: över $SplitAt annonser även efter uppdelning ($total st för $($params | ConvertTo-Json -Compress)), tar de 50 första sidorna." -ForegroundColor Yellow
  }
  foreach ($d in $j.docs) { & $OnDoc $d $region }
  for ($p = 2; $p -le [math]::Min($last, 50); $p++) {
    if ($state.capped) { return }
    $jp = Get-Search $params $p
    if (-not $jp.docs -or $jp.docs.Count -eq 0) { break }
    foreach ($d in $jp.docs) { & $OnDoc $d $region }
  }
}

function Get-Flags($d) {
  $f = 0
  if ($d.flags -contains 'shipping_exists') { $f = $f -bor 1 }
  if ($d.flags -contains 'buy_now') { $f = $f -bor 2 }
  if ($d.flags -contains 'retailer') { $f = $f -bor 4 }
  if (@($d.labels | Where-Object { $_.text -match 'Gratis frakt' }).Count) { $f = $f -bor 8 }
  return $f
}

# Kör en bevakning (eller en underkategori i en alla-bevakning). Returnerar rader och körningsinfo.
function Invoke-Watch($w, [string]$inFile, [string]$outFile, [int]$keepGoneDays) {
  $start = Get-Date
  $old = Read-Db $inFile
  $rows = @{}
  $oldIds = @{}
  if ($old -and $old['rows']) {
    $oc = @($old['cols']); $same = ($oc -join ',') -eq ($Cols -join ',')
    $map = @{}; for ($i = 0; $i -lt $oc.Count; $i++) { $map[[string]$oc[$i]] = $i }
    foreach ($r0 in $old['rows']) {
      $r = $r0
      if (-not $same) {   # äldre format: flytta om kolumnerna och komprimera bild och län
        $r = [object[]]::new($Cols.Count)   # inte New-Object: det ger ett PSObject som serialiseraren inte klarar
        for ($i = 0; $i -lt $Cols.Count; $i++) { if ($map.ContainsKey($Cols[$i])) { $r[$i] = $r0[$map[$Cols[$i]]] } else { $r[$i] = 0 } }
      }
      $r[$C.img] = [string](Compress-Img ([string]$r[$C.img])); if ([string]$r[$C.reg] -eq $w.locationName) { $r[$C.reg] = '' }
      $k = [string]$r[0]; $rows[$k] = $r; if ([int]$r[$C.gone] -eq 0) { $oldIds[$k] = 1 }
    }
  }
  $runs = [System.Collections.ArrayList]@(); if ($old -and $old['runs']) { foreach ($x in $old['runs']) { [void]$runs.Add($x) } }
  $script:condFull = 0

  $params = @{}
  if ($w.q) { $params['q'] = $w.q }
  if ($w.category) { $params[$(if ($w.categoryParam) { $w.categoryParam } else { 'category' })] = $w.category }
  if ($w.location) { $params['location'] = $w.location }
  if ($w.priceFrom) { $params['price_from'] = $w.priceFrom }
  if ($w.priceTo) { $params['price_to'] = $w.priceTo }
  $maxListings = if ($w.maxListings) { [int]$w.maxListings } else { 15000 }

  $state = @{ truncated = $false; capped = $false; errors = 0 }
  $seen = @{}; $script:Req = 0; $script:newCount = 0; $script:priceChanges = 0
  $onDoc = {
    param($d, $region)
    $id = [string]$d.ad_id; if (-not $id -or $id -eq '0') { $id = [string]$d.id }
    if ($seen.ContainsKey($id)) { return }
    if ($d.trade_type -and $d.trade_type -notmatch 'ljes$') { return }
    $price = if ($d.price -and $d.price.amount) { [int]$d.price.amount } else { 0 }
    $img = if ($d.image -and $d.image.path) { [string](Compress-Img $d.image.path) } else { '' }
    $nImg = @($d.image_urls).Count
    $lat = if ($d.coordinates) { [math]::Round([double]$d.coordinates.lat, 3) } else { $null }
    $lon = if ($d.coordinates) { [math]::Round([double]$d.coordinates.lon, 3) } else { $null }
    $pub = [int64]([double]$d.timestamp / 1000)
    $reg = if ($region -and $region -ne $w.locationName) { $region } else { '' }
    $seen[$id] = 1
    if ($rows.ContainsKey($id)) {
      $r = $rows[$id]
      if ($price -ne [int]$r[$C.p]) {
        $ph = [System.Collections.ArrayList]@(); if ($r[$C.ph] -is [array]) { foreach ($x in $r[$C.ph]) { [void]$ph.Add($x) } }
        [void]$ph.Add(@($Today, $price)); $r[$C.ph] = $ph.ToArray()
        $r[$C.p] = $price; $script:priceChanges++
      }
      $r[$C.t] = $d.heading; $r[$C.img] = $img; $r[$C.n] = $nImg; $r[$C.fl] = (Get-Flags $d); $r[$C.gone] = 0
      $r[$C.reg] = $reg
      if ($d.brand) { $r[$C.brand] = $d.brand }
    } else {
      $rows[$id] = [object[]]@([int64]$id, $d.heading, $price, $price, $img, $nImg, $d.location, $reg, $lat, $lon, $(if ($d.brand) { $d.brand } else { '' }), 0, (Get-Flags $d), $pub, $Today, 0, 0)
      $script:newCount++
    }
    if ($seen.Count -ge $maxListings) { $state.capped = $true }
  }

  try {
    Invoke-Collect $params '' $state $onDoc
    # Skick finns inte i sökresultatet, så vi söker per skick och märker annonserna.
    # Full omgång första gången och en gång i veckan. Andra nätter räcker de nya annonserna: sökningen är sorterad
    # på nyast först, så vi bläddrar bara tills en hel sida består av annonser vi redan kände till i går.
    if (-not $state.capped -and $w.conditions -ne $false) {
      $lastFull = 0; foreach ($x in $runs) { if ($x['condFull'] -and [int]$x['condFull'] -gt $lastFull) { $lastFull = [int]$x['condFull'] } }
      $fullCond = $oldIds.Count -eq 0 -or $lastFull -eq 0 -or ($Today - $lastFull) -ge 7
      foreach ($cond in 1..5) {
        $p2 = $params.Clone(); $p2['condition'] = $cond
        if ($fullCond) {
          # GetNewClosure fångar bara variabler i den här funktionen, inte skriptets (som $C). Kopiera in dem.
          $condIx = [int]$C.cond; $rowsRef = $rows
          $tag = { param($d, $region) $id = [string]$d.ad_id; if ($rowsRef.ContainsKey($id)) { $rowsRef[$id][$condIx] = $cond } }.GetNewClosure()
          $st2 = @{ truncated = $false; capped = $false }
          Invoke-Collect $p2 '' $st2 $tag
        } else {
          for ($pg = 1; $pg -le 50; $pg++) {
            $jp = Get-Search $p2 $pg
            if (-not $jp.docs -or $jp.docs.Count -eq 0) { break }
            $known = 0
            foreach ($d in $jp.docs) { $id = [string]$d.ad_id; if ($rows.ContainsKey($id)) { $rows[$id][$C.cond] = $cond }; if ($oldIds.ContainsKey($id)) { $known++ } }
            if ($known -eq $jp.docs.Count -or $pg -ge [int]$jp.metadata.paging.last) { break }
          }
        }
      }
      if ($fullCond) { $script:condFull = $Today }
    }
  } catch {
    $state.errors++
    Write-Host "   FEL: $($_.Exception.Message)" -ForegroundColor Red
  }

  # Försvunna annonser räknas bara när hela sökningen gick igenom, annars blir det falska "sålda".
  $complete = -not $state.truncated -and -not $state.capped -and $state.errors -eq 0 -and $seen.Count -gt 0
  $goneCount = 0
  if ($complete) {
    foreach ($id in @($rows.Keys)) {
      $r = $rows[$id]
      if (-not $seen.ContainsKey($id) -and [int]$r[$C.gone] -eq 0) { $r[$C.gone] = $Today; $goneCount++ }
    }
  }
  foreach ($id in @($rows.Keys)) { $g = [int]$rows[$id][$C.gone]; if ($g -gt 0 -and ($Today - $g) -gt $keepGoneDays) { $rows.Remove($id) } }

  $activePrices = [System.Collections.Generic.List[int]]::new()
  foreach ($r in $rows.Values) { if ([int]$r[$C.gone] -eq 0 -and [int]$r[$C.p] -gt 0) { $activePrices.Add([int]$r[$C.p]) } }
  $activePrices.Sort()
  $median = Get-Med $activePrices
  $secs = [math]::Round(((Get-Date) - $start).TotalSeconds)
  $run = [ordered]@{ day = $Today; at = (Get-Date).ToUniversalTime().ToString('o'); active = $seen.Count; total = $rows.Count
    new = $(if ($old) { $script:newCount } else { 0 }); gone = $goneCount; priceChanges = $script:priceChanges; median = $median
    requests = $script:Req; secs = $secs; complete = $complete; truncated = $state.truncated; capped = $state.capped; condFull = $script:condFull }
  # En körning per dag räcker i historiken: ersätt dagens om den redan finns.
  # Ingen pipeline här: den lindar in raderna i PSObject, som snabb-serialiseraren inte klarar.
  $keep = [System.Collections.ArrayList]::new(); foreach ($x in $runs) { if ([int]$x['day'] -ne $Today) { [void]$keep.Add($x) } }; $runs = $keep
  [void]$runs.Add($run)
  if ($runs.Count -gt 400) { $runs.RemoveRange(0, $runs.Count - 400) }

  $out = [ordered]@{
    v = 2; watch = (ConvertTo-Hash $w); updatedAt = (Get-Date).ToUniversalTime().ToString('o'); today = $Today
    imgBase = 'https://images.blocketcdn.se/dynamic/320w/'; urlBase = 'https://www.blocket.se/recommerce/forsale/item/'
    flags = [ordered]@{ ship = 1; buyNow = 2; company = 4; freeShip = 8 }
    cols = $Cols; rows = @($rows.Values); runs = $runs.ToArray()
  }
  Write-Db $outFile $out -Fast
  $bytes = (Get-Item $outFile).Length
  Write-Host ("   {0}: {1} aktiva, {2} nya, {3} försvunna, {4} prisändringar, {5} anrop, {6} s, {7:N1} MB{8}" -f $w.name, $seen.Count, $run.new, $goneCount, $script:priceChanges, $script:Req, $secs, ($bytes / 1MB), $(if ($complete) { '' } else { ' (ofullständig)' })) -ForegroundColor Green
  return @{ rows = $rows; run = $run; median = $median; bytes = $bytes; updatedAt = $out.updatedAt }
}

# Sammanfattning av en underkategori, för stora statistiken. Små tal, inga annonsrader.
function Get-Summary($rows, $run, $meta) {
  $act = [System.Collections.Generic.List[object]]::new(); $gone30 = [System.Collections.Generic.List[object]]::new()
  foreach ($r in $rows.Values) {
    $g = [int]$r[$C.gone]
    if ($g -eq 0) { $act.Add($r) } elseif ($Today - $g -le 30) { $gone30.Add($r) }
  }
  $prices = [System.Collections.Generic.List[int]]::new(); $value = [int64]0
  $hist = New-Object int[] $HistBands.Count; $cond = New-Object int[] 6
  $ship = 0; $company = 0; $buyNow = 0; $freeShip = 0; $drops = 0; $dropSum = 0.0
  $ages = [System.Collections.Generic.List[int]]::new(); $imgs = [System.Collections.Generic.List[int]]::new()
  $geoCells = @{}; $brands = @{}; $places = @{}
  foreach ($r in $act) {
    $p = [int]$r[$C.p]; $fl = [int]$r[$C.fl]
    if ($p -gt 0) {
      $prices.Add($p); $value += $p
      for ($b = $HistBands.Count - 1; $b -ge 0; $b--) { if ($p -ge $HistBands[$b]) { $hist[$b]++; break } }
    }
    $cond[[int]$r[$C.cond]]++
    if ($fl -band 1) { $ship++ }; if ($fl -band 4) { $company++ }; if ($fl -band 2) { $buyNow++ }; if ($fl -band 8) { $freeShip++ }
    $p0 = [int]$r[$C.p0]; if ($p -gt 0 -and $p -lt $p0) { $drops++; $dropSum += ($p0 - $p) / $p0 }
    $ages.Add($Today - [int][math]::Floor([double]$r[$C.pub] / 86400)); $imgs.Add([int]$r[$C.n])
    if ($null -ne $r[$C.lat] -and $null -ne $r[$C.lon]) {
      $gi = [int][math]::Floor(([double]$r[$C.lat] - $Geo.lat0) / $Geo.dlat); $gj = [int][math]::Floor(([double]$r[$C.lon] - $Geo.lon0) / $Geo.dlon)
      if ($gi -ge 0 -and $gi -lt $Geo.rows -and $gj -ge 0 -and $gj -lt $Geo.cols) { $k = $gi * 1000 + $gj; $geoCells[$k] = 1 + [int]$geoCells[$k] }
    }
    $loc = [string]$r[$C.loc]; if ($loc) { if (-not $places.ContainsKey($loc)) { $places[$loc] = [System.Collections.Generic.List[int]]::new() }; $places[$loc].Add($p) }
    $br = [string]$r[$C.brand]; if ($br) { if (-not $brands.ContainsKey($br)) { $brands[$br] = @{ p = [System.Collections.Generic.List[int]]::new(); d = [System.Collections.Generic.List[int]]::new(); n = 0; g = 0 } }; $brands[$br].n++; if ($p -gt 0) { $brands[$br].p.Add($p) } }
  }
  $prices.Sort(); $ages.Sort(); $imgs.Sort()
  $sell = [System.Collections.Generic.List[int]]::new(); $goneP = [System.Collections.Generic.List[int]]::new()
  foreach ($r in $gone30) {
    $dd = [int]$r[$C.gone] - [int][math]::Floor([double]$r[$C.pub] / 86400); if ($dd -ge 0) { $sell.Add($dd) }
    if ([int]$r[$C.p] -gt 0) { $goneP.Add([int]$r[$C.p]) }
    $br = [string]$r[$C.brand]; if ($br -and $brands.ContainsKey($br)) { $brands[$br].g++; if ($dd -ge 0) { $brands[$br].d.Add($dd) } }
  }
  $sell.Sort(); $goneP.Sort()
  $within7 = @($sell | Where-Object { $_ -le 7 }).Count

  # Publiceringar per dag (senaste 60 dagarna) och per veckodag x timme (svensk tid).
  $pubDays = New-Object int[] 60; $wdhr = New-Object int[] 168
  foreach ($r in $rows.Values) {
    $pd = [int][math]::Floor([double]$r[$C.pub] / 86400); $ix = 59 - ($Today - $pd)
    if ($ix -ge 0 -and $ix -lt 60) {
      $pubDays[$ix]++
      $lt = [TimeZoneInfo]::ConvertTimeFromUtc([DateTimeOffset]::FromUnixTimeSeconds([int64]$r[$C.pub]).UtcDateTime, $Tz)
      $wdhr[[int]$lt.DayOfWeek * 24 + $lt.Hour]++
    }
  }

  $brandOut = @($brands.GetEnumerator() | Sort-Object { $_.Value.n } -Descending | Select-Object -First 15 | ForEach-Object {
      $v = $_.Value; $v.p.Sort(); $v.d.Sort(); , @($_.Key, $v.n, (Get-Med $v.p), $v.g, (Get-Med $v.d)) })
  $placeOut = @($places.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | Select-Object -First 15 | ForEach-Object {
      $l = @($_.Value | Where-Object { $_ -gt 0 } | Sort-Object); , @($_.Key, $_.Value.Count, (Get-Med $l)) })

  # Fynd: aktiva annonser minst hälften under medianen för samma märke.
  $deals = [System.Collections.Generic.List[object]]::new()
  $brandMed = @{}; foreach ($kv in $brands.GetEnumerator()) { if ($kv.Value.p.Count -ge 5) { $kv.Value.p.Sort(); $brandMed[$kv.Key] = Get-Med $kv.Value.p } }
  foreach ($r in $act) {
    $p = [int]$r[$C.p]; $br = [string]$r[$C.brand]
    if ($p -ge 50 -and $br -and $brandMed.ContainsKey($br)) {
      $ref = $brandMed[$br]
      if ($p -le $ref * 0.5 -and $p -ge $ref * 0.15) { $deals.Add(@([int64]$r[$C.id], $r[$C.t], $p, $ref, [string](Expand-Img $r[$C.id] ([string]$r[$C.img])), $r[$C.loc], [int][math]::Floor([double]$r[$C.pub] / 86400), $br, [int]$r[$C.cond])) }
    }
  }
  $dealOut = @($deals | Sort-Object { $_[2] / $_[3] } | Select-Object -First 10)

  return [ordered]@{
    sub = $meta.sub; name = $meta.name; cat = $meta.cat; catName = $meta.catName; day = $Today; complete = $run.complete
    active = $act.Count; total = $rows.Count; new = $run.new; gone = $run.gone; priceChanges = $run.priceChanges
    value = $value; priced = $prices.Count
    p = @((Get-Q $prices 0.1), (Get-Q $prices 0.25), (Get-Med $prices), (Get-Q $prices 0.75), (Get-Q $prices 0.9))
    gone30 = $gone30.Count; goneMed = (Get-Med $goneP)
    sell = [ordered]@{ n = $sell.Count; d25 = (Get-Q $sell 0.25); d50 = (Get-Med $sell); d75 = (Get-Q $sell 0.75); within7 = $within7 }
    ship = $ship; company = $company; buyNow = $buyNow; freeShip = $freeShip
    drops = $drops; dropAvg = $(if ($drops) { [math]::Round($dropSum / $drops, 3) } else { 0 })
    age = (Get-Med $ages); imgs = (Get-Med $imgs)
    cond = $cond; histBands = $HistBands; hist = $hist; pubDays = $pubDays; wdhr = $wdhr
    geo = @($geoCells.GetEnumerator() | ForEach-Object { , @([int][math]::Floor($_.Key / 1000), ($_.Key % 1000), $_.Value) })
    brands = $brandOut; places = $placeOut; deals = $dealOut
  }
}

$cats = Read-Json (Join-Path $DataDir 'blocket-kategorier.json')
$watches = @(Read-Json (Join-Path $DataDir 'bevakningar.json') | Where-Object { $_ -and $_.enabled -ne $false })
$oldIndex = Read-Db (Join-Path $DbDir 'index.json')
$known = @{}; if ($oldIndex -and $oldIndex['watches']) { foreach ($x in $oldIndex['watches']) { $known[$x['id']] = 1 } }
if ($Watch -eq 'nya') { $watches = @($watches | Where-Object { -not $known.ContainsKey($_.id) }) }
elseif ($Watch -and $Watch -ne 'alla') { $ids = $Watch -split ','; $watches = @($watches | Where-Object { $ids -contains $_.id }) }
if (-not $watches.Count) { Write-Host 'Inga bevakningar att köra.'; return }
$subFilter = @($Subs -split ',' | Where-Object { $_ })

foreach ($w in $watches) {
  if ($w.mode -eq 'tradera') {
    # Tradera har en egen skrapa. -Subs betyder här huvudkategorier.
    & (Join-Path $PSScriptRoot 'tradera.ps1') -Watch $w.id -Tops $Subs -DbDir $DbDir -OutDir $OutDir
    continue
  }
  if ($w.mode -eq 'alla') {
    Write-Host "== Hela Blocket: $($w.name) ($($w.id))" -ForegroundColor Cyan
    foreach ($cat in $cats.categories) {
      foreach ($s in $cat.subs) {
        if ($subFilter.Count -and $subFilter -notcontains $s.value) { continue }
        $sw = [pscustomobject]@{ id = "$($w.id)/$($s.value)"; name = "$($cat.name) › $($s.name)"; category = $s.value; categoryParam = $s.param
          categoryName = "$($cat.name) › $($s.name)"; location = $w.location; locationName = $w.locationName; q = ''
          maxListings = 100000; conditions = ($w.conditions -ne $false); parent = $w.id }
        $res = Invoke-Watch $sw (Join-Path $DbDir "$($w.id)\$($s.value).json") (Join-Path $OutDir "$($w.id)\$($s.value).json") $(if ($w.keepGoneDays) { [int]$w.keepGoneDays } else { 45 })
        $sum = Get-Summary $res.rows $res.run @{ sub = $s.value; name = $s.name; cat = $cat.value; catName = $cat.name }
        $sum['bytes'] = $res.bytes; $sum['secs'] = $res.run.secs; $sum['requests'] = $res.run.requests
        Write-Db (Join-Path $OutDir "$($w.id)\sum\$($s.value).json") $sum
        $res = $null; [GC]::Collect()
      }
    }
  } else {
    Write-Host "== Bevakning: $($w.name) ($($w.id))" -ForegroundColor Cyan
    $res = Invoke-Watch $w (Join-Path $DbDir "$($w.id).json") (Join-Path $OutDir "$($w.id).json") 180
    $goneN = 0; foreach ($r in $res.rows.Values) { if ([int]$r[$C.gone] -gt 0) { $goneN++ } }
    Write-Db (Join-Path $OutDir "idx\$($w.id).json") ([ordered]@{ id = $w.id; name = $w.name; updatedAt = $res.updatedAt; active = $res.run.active; total = $res.rows.Count
      gone = $goneN; median = $res.median; complete = $res.run.complete; secs = $res.run.secs; bytes = $res.bytes })
  }
}
Write-Host "Klart. Kör scripts\aggregate.ps1 för att bygga index, översikt och trender."
