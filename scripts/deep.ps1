# Djupscrape: hämtar ALLA annonser i en Blocket-kategori (eller sökning) och bygger en databas med historik.
#
# Blocket visar max 50 sidor (ca 2 500 annonser) per sökning. Stora kategorier delas därför upp per län
# och sedan per prisintervall tills varje del ryms. En extra omgång per skick taggar annonsernas skick.
#
# Per annons sparas: rubrik, pris, första pris, prishistorik, bild, antal bilder, ort, län, koordinater,
# märke, skick, frakt/köp nu/företag, publiceringstid, först sedd, senast sedd och när den försvann.
# Försvunna annonser = sålda eller borttagna. Det ger säljtid och säljtakt.
#
# Användning:  scripts\deep.ps1 -Watch alla|<id> -DbDir dbdata

param(
  [string]$Watch = 'alla',
  [string]$DbDir = 'dbdata',
  [int]$DelayMs = 650
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$Base = 'https://www.blocket.se/recommerce/forsale/search/api/search/SEARCH_ID_BAP_COMMON'
$SplitAt = 2400                      # över så här många träffar delas sökningen upp
$PriceBands = @(@(0, 99), @(100, 249), @(250, 499), @(500, 999), @(1000, 1999), @(2000, 4999), @(5000, 14999), @(15000, $null))
$Cols = @('id', 't', 'p', 'p0', 'img', 'n', 'loc', 'reg', 'lat', 'lon', 'brand', 'cond', 'fl', 'pub', 'first', 'last', 'gone', 'ph')
$C = @{}; for ($i = 0; $i -lt $Cols.Count; $i++) { $C[$Cols[$i]] = $i }
# fl (flaggor): 1 = kan skickas, 2 = köp nu, 4 = företag, 8 = gratis frakt
$Today = [int][math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) / 86400)

if (-not [IO.Path]::IsPathRooted($DbDir)) { $DbDir = Join-Path $RepoRoot $DbDir }
if (-not (Test-Path $DbDir)) { New-Item -ItemType Directory $DbDir | Out-Null }

$script:Req = 0
function Get-Search([hashtable]$params, [int]$page) {
  $qs = @("sort=PUBLISHED_DESC", "page=$page")
  foreach ($k in $params.Keys) { if ($null -ne $params[$k] -and "$($params[$k])" -ne '') { $qs += "$k=$([uri]::EscapeDataString([string]$params[$k]))" } }
  $url = "$Base`?" + ($qs -join '&')
  for ($try = 0; $try -lt 3; $try++) {
    try {
      $script:Req++
      $j = (Get-Text $url) | ConvertFrom-Json
      Start-Sleep -Milliseconds $DelayMs
      return $j
    } catch { Start-Sleep -Seconds (5 * ($try + 1)) }
  }
  throw "Blocket svarade inte: $url"
}

# Går igenom en sökning, delar upp den om den är för stor, och anropar $OnDoc för varje annons.
function Invoke-Collect([hashtable]$params, [string]$region, $state, [scriptblock]$OnDoc) {
  if ($state.capped) { return }
  $j = Get-Search $params 1
  $total = [int]$j.metadata.result_size.match_count
  $last = [int]$j.metadata.paging.last
  if ($total -gt $SplitAt) {
    if (-not $params.ContainsKey('location')) {
      $items = @(($j.filters | Where-Object { $_.name -eq 'location' }).filter_items | Where-Object { $_.hits -gt 0 })
      if ($items.Count -gt 1) {
        foreach ($it in $items) { $p2 = $params.Clone(); $p2['location'] = $it.value; Invoke-Collect $p2 $it.display_name $state $OnDoc }
        return
      }
    }
    if (-not $params.ContainsKey('price_from') -and -not $params.ContainsKey('price_to')) {
      foreach ($band in $PriceBands) {
        $p2 = $params.Clone(); $p2['price_from'] = $band[0]; if ($null -ne $band[1]) { $p2['price_to'] = $band[1] }
        Invoke-Collect $p2 $region $state $OnDoc
      }
      return
    }
    $state.truncated = $true
    Write-Host "   OBS: över $SplitAt annonser även efter uppdelning ($total), tar de 50 första sidorna." -ForegroundColor Yellow
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

$cats = Read-Json (Join-Path $DataDir 'blocket-kategorier.json')
$watches = @(Read-Json (Join-Path $DataDir 'bevakningar.json'))
if ($Watch -and $Watch -ne 'alla') { $watches = @($watches | Where-Object { $_.id -eq $Watch }) }
$watches = @($watches | Where-Object { $_ -and $_.enabled -ne $false })
if (-not $watches.Count) { Write-Host 'Inga bevakningar att köra.'; return }

$indexFile = Join-Path $DbDir 'index.json'
$index = @{}; $oldIdx = Read-Json $indexFile; if ($oldIdx -and $oldIdx.watches) { foreach ($w in $oldIdx.watches) { $index[$w.id] = $w } }

foreach ($w in $watches) {
  $start = Get-Date
  Write-Host "== Bevakning: $($w.name) ($($w.id))" -ForegroundColor Cyan
  $dbFile = Join-Path $DbDir "$($w.id).json"
  $old = Read-Json $dbFile
  $rows = @{}
  if ($old -and $old.rows) { foreach ($r in $old.rows) { $rows[[string]$r[0]] = [System.Collections.ArrayList]@($r) } }
  $runs = if ($old -and $old.runs) { [System.Collections.ArrayList]@($old.runs) } else { [System.Collections.ArrayList]@() }

  $params = @{}
  if ($w.q) { $params['q'] = $w.q }
  if ($w.category) { $params[$(if ($w.categoryParam) { $w.categoryParam } else { 'category' })] = $w.category }
  if ($w.location) { $params['location'] = $w.location }
  if ($w.priceFrom) { $params['price_from'] = $w.priceFrom }
  if ($w.priceTo) { $params['price_to'] = $w.priceTo }
  $maxListings = if ($w.maxListings) { [int]$w.maxListings } else { 15000 }

  $state = @{ truncated = $false; capped = $false; errors = 0 }
  $seen = @{}; $newCount = 0; $priceChanges = 0; $script:Req = 0
  $onDoc = {
    param($d, $region)
    $id = [string]$d.ad_id; if (-not $id -or $id -eq '0') { $id = [string]$d.id }
    if ($seen.ContainsKey($id)) { return }
    if ($d.trade_type -and $d.trade_type -notmatch 'ljes$') { return }
    $price = if ($d.price -and $d.price.amount) { [int]$d.price.amount } else { 0 }
    $img = if ($d.image -and $d.image.path) { $d.image.path } else { '' }
    $nImg = @($d.image_urls).Count
    $lat = if ($d.coordinates) { [math]::Round([double]$d.coordinates.lat, 3) } else { $null }
    $lon = if ($d.coordinates) { [math]::Round([double]$d.coordinates.lon, 3) } else { $null }
    $pub = [int64]([double]$d.timestamp / 1000)
    $reg = if ($region) { $region } elseif ($w.locationName) { $w.locationName } else { '' }
    $seen[$id] = 1
    if ($rows.ContainsKey($id)) {
      $r = $rows[$id]
      if ($price -ne [int]$r[$C.p]) {
        $ph = [System.Collections.ArrayList]@(); if ($r[$C.ph] -and $r[$C.ph] -isnot [int] -and $r[$C.ph] -isnot [long]) { foreach ($x in $r[$C.ph]) { [void]$ph.Add(@($x)) } }
        [void]$ph.Add(@($Today, $price)); $r[$C.ph] = $ph.ToArray()
        $r[$C.p] = $price; $script:priceChanges++
      }
      $r[$C.t] = $d.heading; $r[$C.img] = $img; $r[$C.n] = $nImg; $r[$C.fl] = (Get-Flags $d); $r[$C.last] = $Today; $r[$C.gone] = 0
      if ($reg) { $r[$C.reg] = $reg }
      if ($d.brand) { $r[$C.brand] = $d.brand }
    } else {
      $rows[$id] = [System.Collections.ArrayList]@([int64]$id, $d.heading, $price, $price, $img, $nImg, $d.location, $reg, $lat, $lon, $(if ($d.brand) { $d.brand } else { '' }), 0, (Get-Flags $d), $pub, $Today, $Today, 0, 0)
      $script:newCount++
    }
    if ($seen.Count -ge $maxListings) { $state.capped = $true }
  }
  $script:newCount = 0; $script:priceChanges = 0

  try {
    Invoke-Collect $params '' $state $onDoc
    Write-Host "   $($seen.Count) aktiva annonser, $script:Req anrop. Taggar skick…"
    # Skick finns inte i sökresultatet, så vi söker per skick och märker annonserna.
    if (-not $state.capped -and $w.conditions -ne $false) {
      foreach ($cond in 1..5) {
        $p2 = $params.Clone(); $p2['condition'] = $cond
        $tag = { param($d, $region) $id = [string]$d.ad_id; if ($rows.ContainsKey($id)) { $rows[$id][$C.cond] = $cond } }.GetNewClosure()
        $st2 = @{ truncated = $false; capped = $false }
        Invoke-Collect $p2 '' $st2 $tag
      }
    }
  } catch {
    $state.errors++
    Write-Host "   FEL: $($_.Exception.Message)" -ForegroundColor Red
  }

  $complete = -not $state.truncated -and -not $state.capped -and $state.errors -eq 0
  $goneCount = 0
  if ($complete) {
    foreach ($id in @($rows.Keys)) {
      $r = $rows[$id]
      if (-not $seen.ContainsKey($id) -and [int]$r[$C.gone] -eq 0) { $r[$C.gone] = $Today; $goneCount++ }
    }
  }
  # Rensa annonser som försvann för mer än 180 dagar sedan.
  foreach ($id in @($rows.Keys)) { $g = [int]$rows[$id][$C.gone]; if ($g -gt 0 -and ($Today - $g) -gt 180) { $rows.Remove($id) } }

  $activePrices = @($rows.Values | Where-Object { [int]$_[$C.gone] -eq 0 -and [int]$_[$C.p] -gt 0 } | ForEach-Object { [int]$_[$C.p] } | Sort-Object)
  $median = if ($activePrices.Count) { $activePrices[[math]::Floor(($activePrices.Count - 1) / 2)] } else { $null }
  $secs = [math]::Round(((Get-Date) - $start).TotalSeconds)
  $run = [ordered]@{ day = $Today; at = (Get-Date).ToUniversalTime().ToString('o'); active = $seen.Count; total = $rows.Count
    new = $(if ($old) { $script:newCount } else { 0 }); gone = $goneCount; priceChanges = $script:priceChanges; median = $median
    requests = $script:Req; secs = $secs; complete = $complete; truncated = $state.truncated; capped = $state.capped }
  # En körning per dag räcker i historiken: ersätt dagens om den redan finns.
  $runs = [System.Collections.ArrayList]@($runs | Where-Object { $_.day -ne $Today })
  [void]$runs.Add($run)
  if ($runs.Count -gt 400) { $runs = [System.Collections.ArrayList]@($runs | Select-Object -Last 400) }

  $out = [ordered]@{
    v = 1; watch = $w; updatedAt = (Get-Date).ToUniversalTime().ToString('o'); today = $Today
    imgBase = 'https://images.blocketcdn.se/dynamic/320w/'; urlBase = 'https://www.blocket.se/recommerce/forsale/item/'
    flags = [ordered]@{ ship = 1; buyNow = 2; company = 4; freeShip = 8 }
    cols = $Cols; rows = @($rows.Values | ForEach-Object { $a = $_.ToArray(); if (-not $a[$C.ph] -or @($a[$C.ph]).Count -eq 0) { $a[$C.ph] = 0 }; , $a }); runs = @($runs)
  }
  Write-Json $dbFile $out 8
  $index[$w.id] = [ordered]@{ id = $w.id; name = $w.name; updatedAt = $out.updatedAt; active = $seen.Count; total = $rows.Count
    gone = @($rows.Values | Where-Object { [int]$_[$C.gone] -gt 0 }).Count; median = $median; complete = $complete; secs = $secs
    bytes = (Get-Item $dbFile).Length }
  Write-Host ("   Klart: {0} aktiva, {1} nya, {2} försvunna, {3} prisändringar, {4} anrop, {5} s, {6:N1} MB" -f $seen.Count, $run.new, $goneCount, $script:priceChanges, $script:Req, $secs, ((Get-Item $dbFile).Length / 1MB)) -ForegroundColor Green
}

Write-Json $indexFile ([ordered]@{ updatedAt = (Get-Date).ToUniversalTime().ToString('o'); watches = @($index.Values) })
