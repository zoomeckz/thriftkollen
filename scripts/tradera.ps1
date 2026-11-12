# Tradera-databas: SÅLDA annonser med riktiga slutpriser, för hela Sverige.
#
# Tradera visar avslutade (sålda) annonser per kategori, sorterade på när de lades upp.
# Varje natt hämtas, per underkategori, allt som lagts upp de senaste $Days dagarna och redan är sålt.
# Körs varje natt fångas därmed allt som säljs inom $Days dagar från att det lades upp
# (alla vanliga auktioner, och köp nu-annonser som säljer snabbt).
# Dessutom sparas antalet aktiva annonser per underkategori (utbudet).
#
# Filer:  <id>/<underkategori>.json  rader med sålda annonser (sparas $KeepDays dagar)
#         <id>/sum/<underkategori>.json  sammanfattning (aggregate.ps1 bygger overview.json och trend.json)
#
# Användning:  scripts\tradera.ps1 -Watch tradera [-Tops 1612,20] -DbDir dbdata [-OutDir ut]

param(
  [string]$Watch = 'tradera',
  [string]$Tops = '',          # huvudkategorier (id, komma). Tomt = alla
  [string]$DbDir = 'dbdata',
  [string]$OutDir = '',
  [int]$Days = 8,
  [int]$KeepDays = 30,
  [int]$DelayMs = 400,
  [int]$MaxPages = 8,        # högst så många sidor (80 annonser/sida) per underkategori och natt; stora kategorier blir ett urval
  [int]$MaxSubs = 0          # för test: bara de första N underkategorierna per huvudkategori
)
. (Join-Path $PSScriptRoot 'lib.ps1')
if (-not [IO.Path]::IsPathRooted($DbDir)) { $DbDir = Join-Path $RepoRoot $DbDir }
if (-not $OutDir) { $OutDir = $DbDir } elseif (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $RepoRoot $OutDir }

Add-Type -TypeDefinition @'
public static class JsonCut {
  // Hittar värdet (objekt eller lista) efter "key": med start från position from. Håller koll på strängar.
  public static string After(string s, string key, int from) {
    int i = s.IndexOf(key, from); if (i < 0) return null;
    i += key.Length; while (i < s.Length && char.IsWhiteSpace(s[i])) i++;
    char open = s[i], close = open == '[' ? ']' : '}'; if (open != '[' && open != '{') return null;
    int depth = 0; bool str = false;
    for (int j = i; j < s.Length; j++) {
      char c = s[j];
      if (str) { if (c == '\\') j++; else if (c == '"') str = false; continue; }
      if (c == '"') str = true; else if (c == open || (c == '[' || c == '{')) depth++; else if (c == ']' || c == '}') { depth--; if (depth == 0) return s.Substring(i, j - i + 1); }
    }
    return null;
  }
}
'@

$Cols = @('id', 't', 'p', 'p0', 'bin', 'type', 'bids', 'start', 'end', 'cat', 'img', 'fl', 'ship', 'brand', 'cond')
$C = @{}; for ($i = 0; $i -lt $Cols.Count; $i++) { $C[$Cols[$i]] = $i }
# type: 1 = auktion, 2 = auktion med köp nu, 3 = köp nu, 4 = butik.  fl: 1 = företag, 2 = gratis frakt, 4 = tar emot bud/prisförslag
$TypeCode = @{ Auction = 1; AuctionBin = 2; PureBin = 3; ShopItem = 4 }
$Now = [DateTimeOffset]::UtcNow
$Today = [int][math]::Floor($Now.ToUnixTimeSeconds() / 86400)
$Cutoff = $Now.AddDays(-$Days)
$Tz = [TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time')
$HistBands = @(0, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000)

$script:Req = 0
function Get-Payload([string]$url) {
  for ($try = 0; $try -lt 4; $try++) {
    try {
      $script:Req++
      $h = Get-Text $url
      Start-Sleep -Milliseconds $DelayMs
      $sb = [Text.StringBuilder]::new()
      foreach ($m in [regex]::Matches($h, 'self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)')) { [void]$sb.Append($script:Ser.DeserializeObject('"' + $m.Groups[1].Value + '"')) }
      return $sb.ToString()
    } catch { Start-Sleep -Seconds (5 * ($try + 1)) }
  }
  throw "Tradera svarade inte: $url"
}
function Get-Listing([string]$url) {
  $t = Get-Payload $url
  $i = $t.IndexOf('"totalItemCount":')
  $res = @{ total = 0; items = @(); pages = 0; text = $t }
  if ($i -lt 0) { return $res }
  $res.total = [int][regex]::Match($t.Substring($i, 40), '\d+').Value
  $arr = [JsonCut]::After($t, '"items":', $i)
  if ($arr) { $res.items = @($script:Ser.DeserializeObject($arr)) }
  $pg = [regex]::Match($t.Substring($i), '"pageCount":(\d+)'); if ($pg.Success) { $res.pages = [int]$pg.Groups[1].Value }
  return $res
}
# Underkategorier med antal, från kategorisidans filter ("activeCategory").
function Get-SubCounts([string]$text) {
  $o = @{}
  $ac = [JsonCut]::After($text, '"activeCategory":', 0); if (-not $ac) { return $o }
  $cat = $script:Ser.DeserializeObject($ac)
  foreach ($ch in $cat['children']) { $o[[string]$ch['id']] = @{ name = $ch['name']; count = [int]$ch['count'] } }
  return $o
}
function Get-Attr($it, [string]$pattern) {
  foreach ($a in $it['attributes']) { if ($a['name'] -match $pattern -and $a['values'] -and @($a['values']).Count) { return [string]@($a['values'])[0] } }
  return ''
}
function ConvertTo-Unix([string]$s) { return [int64]([DateTimeOffset]::Parse($s, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds()) }
function Get-Med($sorted) { if (-not $sorted -or $sorted.Count -eq 0) { return $null }; return $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)] }
function Get-Q($sorted, [double]$q) { if (-not $sorted -or $sorted.Count -eq 0) { return $null }; return $sorted[[int][math]::Floor(($sorted.Count - 1) * $q)] }

function Get-Summary($rows, $meta) {
  $sold = [System.Collections.Generic.List[object]]::new()
  foreach ($r in $rows.Values) { if ($Today - [int][math]::Floor([double]$r[$C.end] / 86400) -le 30) { $sold.Add($r) } }
  $prices = [System.Collections.Generic.List[int]]::new(); $value = [int64]0; $hist = New-Object int[] $HistBands.Count
  $types = New-Object int[] 5; $bidsSum = 0; $bidsN = 0; $company = 0; $freeShip = 0; $over = 0
  $hours = [System.Collections.Generic.List[double]]::new(); $ships = [System.Collections.Generic.List[int]]::new()
  $endDays = New-Object int[] 30; $wdhr = New-Object int[] 168; $brands = @{}; $conds = @{}
  $hourPrice = @{}; for ($h = 0; $h -lt 24; $h++) { $hourPrice[$h] = [System.Collections.Generic.List[int]]::new() }
  foreach ($r in $sold) {
    $p = [int]$r[$C.p]; $prices.Add($p); $value += $p
    for ($b = $HistBands.Count - 1; $b -ge 0; $b--) { if ($p -ge $HistBands[$b]) { $hist[$b]++; break } }
    $types[[int]$r[$C.type]]++
    if ([int]$r[$C.type] -le 2) { $bidsSum += [int]$r[$C.bids]; $bidsN++; if ([int]$r[$C.p0] -gt 0 -and $p -gt [int]$r[$C.p0]) { $over++ } }
    $fl = [int]$r[$C.fl]; if ($fl -band 1) { $company++ }; if ($fl -band 2) { $freeShip++ }
    $hours.Add(([double]$r[$C.end] - [double]$r[$C.start]) / 3600)
    if ([int]$r[$C.ship] -gt 0) { $ships.Add([int]$r[$C.ship]) }
    $ed = [int][math]::Floor([double]$r[$C.end] / 86400); $ix = 29 - ($Today - $ed); if ($ix -ge 0 -and $ix -lt 30) { $endDays[$ix]++ }
    $lt = [TimeZoneInfo]::ConvertTimeFromUtc([DateTimeOffset]::FromUnixTimeSeconds([int64]$r[$C.end]).UtcDateTime, $Tz)
    $wdhr[[int]$lt.DayOfWeek * 24 + $lt.Hour]++
    if ([int]$r[$C.type] -le 2) { $hourPrice[$lt.Hour].Add($p) }
    $br = [string]$r[$C.brand]; if ($br) { if (-not $brands.ContainsKey($br)) { $brands[$br] = [System.Collections.Generic.List[int]]::new() }; $brands[$br].Add($p) }
    $cd = [string]$r[$C.cond]; if ($cd) { $conds[$cd] = 1 + [int]$conds[$cd] }
  }
  $prices.Sort(); $hours.Sort(); $ships.Sort()
  $brandOut = @($brands.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | Select-Object -First 15 | ForEach-Object { $_.Value.Sort(); , @($_.Key, $_.Value.Count, (Get-Med $_.Value)) })
  $condOut = @($conds.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 | ForEach-Object { , @($_.Key, $_.Value) })
  $top = @($sold | Sort-Object { [int]$_[$C.p] } -Descending | Select-Object -First 8 | ForEach-Object { , @([int64]$_[$C.id], $_[$C.t], [int]$_[$C.p], $_[$C.img], [int]$_[$C.bids], [int]$_[$C.type], [int][math]::Floor([double]$_[$C.end] / 86400)) })
  # Budkrig: auktioner som gick långt över utropet.
  $wars = @($sold | Where-Object { [int]$_[$C.type] -le 2 -and [int]$_[$C.p0] -gt 0 -and [int]$_[$C.p] -ge 200 } | Sort-Object { [int]$_[$C.p] / [int]$_[$C.p0] } -Descending | Select-Object -First 8 |
      ForEach-Object { , @([int64]$_[$C.id], $_[$C.t], [int]$_[$C.p], $_[$C.img], [int]$_[$C.bids], [int]$_[$C.p0], [int][math]::Floor([double]$_[$C.end] / 86400)) })
  $hp = @(0..23 | ForEach-Object { $l = $hourPrice[$_]; $l.Sort(); , @($l.Count, (Get-Med $l)) })
  return [ordered]@{
    sub = $meta.sub; name = $meta.name; cat = $meta.cat; catName = $meta.catName; day = $Today; complete = $meta.complete
    active = $meta.active; soldWindow = $meta.soldWindow; sold30 = $sold.Count; soldToday = $endDays[29] + $endDays[28]
    soldWeek = ($endDays[22..28] | Measure-Object -Sum).Sum
    value = $value; p = @((Get-Q $prices 0.1), (Get-Q $prices 0.25), (Get-Med $prices), (Get-Q $prices 0.75), (Get-Q $prices 0.9))
    types = $types; bidsAvg = $(if ($bidsN) { [math]::Round($bidsSum / $bidsN, 1) } else { $null }); overStart = $over; auctions = $bidsN
    hours50 = $(if ($hours.Count) { [math]::Round((Get-Med $hours), 1) } else { $null })
    company = $company; freeShip = $freeShip; ship50 = (Get-Med $ships)
    histBands = $HistBands; hist = $hist; endDays = $endDays; wdhr = $wdhr; hourPrice = $hp
    brands = $brandOut; conds = $condOut; top = $top; wars = $wars
  }
}

$watches = @(Read-Json (Join-Path $DataDir 'bevakningar.json') | Where-Object { $_ -and $_.mode -eq 'tradera' -and $_.enabled -ne $false })
$w = $watches | Where-Object { $_.id -eq $Watch } | Select-Object -First 1
if (-not $w) { Write-Host "Ingen Tradera-bevakning med id $Watch."; return }
if ($w.days) { $Days = [int]$w.days; $Cutoff = $Now.AddDays(-$Days) }
if ($w.keepDays) { $KeepDays = [int]$w.keepDays }; if ($w.maxPages) { $MaxPages = [int]$w.maxPages }
$tcats = Read-Json (Join-Path $DataDir 'tradera-kategorier.json')
$want = @($Tops -split ',' | Where-Object { $_ })

Write-Host "== Tradera: $($w.name) (sålda inom $Days dagar, sparas $KeepDays dagar)" -ForegroundColor Cyan
foreach ($top in $tcats.categories) {
  if ($want.Count -and $want -notcontains [string]$top.id) { continue }
  $t0 = Get-Date; $script:Req = 0
  # Aktiva och sålda per underkategori (två anrop per huvudkategori).
  $active = Get-SubCounts (Get-Payload "https://www.tradera.com/category/$($top.id)")
  $soldCnt = Get-SubCounts (Get-Payload "https://www.tradera.com/category/$($top.id)?itemStatus=Ended")
  $subs = @($top.subs); if ($MaxSubs -gt 0) { $subs = @($subs | Select-Object -First $MaxSubs) }
  foreach ($s in $subs) {
    $sid = [string]$s.id
    $file = Join-Path $DbDir "$($w.id)\$sid.json"; $old = Read-Db $file
    $rows = @{}; if ($old -and $old['rows']) { foreach ($r in $old['rows']) { $rows[[string]$r[0]] = $r } }
    $before = $rows.Count; $complete = $true; $page = 1; $seenNew = 0
    while ($true) {
      try { $res = Get-Listing "https://www.tradera.com/category/$sid`?itemStatus=Ended&sortBy=AddedOn&paging=$page" } catch { $complete = $false; Write-Host "   FEL: $($_.Exception.Message)" -ForegroundColor Red; break }
      if (-not $res.items.Count) { break }
      $older = 0
      foreach ($it in $res.items) {
        $start = ConvertTo-Unix $it['startDate']; $end = ConvertTo-Unix $it['endDate']
        if ($start -lt $Cutoff.ToUnixTimeSeconds()) { $older++ }
        $sp = $it['soldPrice']; if ($null -eq $sp) { continue }
        $id = [string]$it['itemId']
        $img = ''; if ($it['imageUrlTemplate']) { $img = ([string]$it['imageUrlTemplate']) -replace '^https://img\.tradera\.net/\{format\}/', '' }
        $fl = 0; if ($it['sellerIsCompany']) { $fl = $fl -bor 1 }; if ($it['hasFreeShipping']) { $fl = $fl -bor 2 }; if ($it['isAvailableForOffers']) { $fl = $fl -bor 4 }
        $ship = 0; $so = @($it['shippingOptions'] | Where-Object { $_ -and $_['cost'] -gt 0 } | ForEach-Object { [int]$_['cost'] } | Sort-Object); if ($so.Count) { $ship = $so[0] }
        $type = $TypeCode[[string]$it['itemType']]; if (-not $type) { $type = 3 }
        if (-not $rows.ContainsKey($id)) { $seenNew++ }
        $rows[$id] = [object[]]@([int64]$id, [string]$it['shortDescription'], [int]$sp, [int]$it['price'], [int]$it['buyNowPrice'], $type, [int]$it['totalBids'], [int64]$start, [int64]$end, [int]$it['categoryId'], [string]$img, [int]$fl, [int]$ship,
          [string](Get-Attr $it 'brand$'), [string](Get-Attr $it '^condition'))
      }
      # Sidorna är sorterade på uppläggningsdatum: när hela sidan är äldre än fönstret är vi klara.
      if ($older -eq $res.items.Count -or $page -ge $res.pages) { break }
      $page++
      if ($page -gt [math]::Min(125, $MaxPages)) { $complete = $false; break }   # urval: de senast upplagda
    }
    foreach ($id in @($rows.Keys)) { if ($Today - [int][math]::Floor([double]$rows[$id][$C.end] / 86400) -gt $KeepDays) { $rows.Remove($id) } }
    $out = [ordered]@{ v = 1; source = 'tradera'; watch = [ordered]@{ id = "$($w.id)/$sid"; name = "$($top.name) › $($s.name)"; parent = $w.id }
      updatedAt = (Get-Date).ToUniversalTime().ToString('o'); today = $Today; imgBase = 'https://img.tradera.net/250-square/'; urlBase = 'https://www.tradera.com/item/'
      cols = $Cols; rows = @($rows.Values) }
    Write-Db (Join-Path $OutDir "$($w.id)\$sid.json") $out -Fast
    $a = $active[$sid]; $sc = $soldCnt[$sid]
    $sum = Get-Summary $rows @{ sub = $sid; name = $s.name; cat = [string]$top.id; catName = $top.name; complete = $complete
      active = $(if ($a) { $a.count } else { $null }); soldWindow = $(if ($sc) { $sc.count } else { $null }) }
    Write-Db (Join-Path $OutDir "$($w.id)\sum\$sid.json") $sum
    Write-Host ("   {0} › {1}: {2} nya sålda, {3} totalt, {4} sidor{5}" -f $top.name, $s.name, $seenNew, $rows.Count, $page, $(if ($complete) { '' } else { ' (urval)' }))
  }
  Write-Host ("   {0}: {1} anrop, {2:N0} s" -f $top.name, $script:Req, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor Green
}
