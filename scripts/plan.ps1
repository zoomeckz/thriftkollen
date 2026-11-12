# Delar upp nattens databaskörning i parallella jobb på GitHub.
# Vanliga bevakningar körs i ett jobb. Hela-Blocket-bevakningar delas på underkategorier så att
# varje jobb får ungefär lika många annonser (ca 25 000 st, runt 10 minuter).
#
# Användning:  scripts\plan.ps1 -Watch alla|nya|<id>[,<id>] -DbDir dbdata
# Skriver matrix=... och count=... till $env:GITHUB_OUTPUT (eller skärmen lokalt).

param([string]$Watch = 'alla', [string]$DbDir = 'dbdata', [int]$PerShard = 25000)
. (Join-Path $PSScriptRoot 'lib.ps1')
if (-not [IO.Path]::IsPathRooted($DbDir)) { $DbDir = Join-Path $RepoRoot $DbDir }

$cats = Read-Json (Join-Path $DataDir 'blocket-kategorier.json')
$watches = @(Read-Json (Join-Path $DataDir 'bevakningar.json') | Where-Object { $_ -and $_.enabled -ne $false })
$index = Read-Db (Join-Path $DbDir 'index.json')
$known = @{}; if ($index -and $index['watches']) { foreach ($x in $index['watches']) { $known[$x['id']] = 1 } }
if ($Watch -eq 'nya') { $watches = @($watches | Where-Object { -not $known.ContainsKey($_.id) }) }
elseif ($Watch -and $Watch -ne 'alla') { $ids = $Watch -split ','; $watches = @($watches | Where-Object { $ids -contains $_.id }) }

$include = [System.Collections.Generic.List[object]]::new()
$plain = @($watches | Where-Object { $_.mode -ne 'alla' -and $_.mode -ne 'tradera' })
if ($plain.Count) { $include.Add([ordered]@{ name = "Bevakningar ($($plain.Count))"; watch = (($plain | ForEach-Object { $_.id }) -join ','); subs = '' }) }

foreach ($w in $watches | Where-Object { $_.mode -eq 'alla' }) {
  # Antal annonser per underkategori i området, så att jobben blir lika stora.
  $hits = @{}
  try {
    $u = 'https://www.blocket.se/recommerce/forsale/search/api/search/SEARCH_ID_BAP_COMMON?page=1' + $(if ($w.location) { "&location=$($w.location)" } else { '' })
    $j = (Get-Text $u) | ConvertFrom-Json
    foreach ($c in ($j.filters | Where-Object { $_.name -eq 'category' }).filter_items) { foreach ($s in $c.filter_items) { $hits[$s.value] = [int]$s.hits } }
  } catch { Write-Host "Kunde inte hämta antal per kategori, använder sparade siffror: $($_.Exception.Message)" }
  $subs = @(foreach ($c in $cats.categories) { foreach ($s in $c.subs) {
        $n = if ($hits.ContainsKey($s.value)) { $hits[$s.value] } elseif ($w.location) { [int]($s.hits / 4) } else { [int]$s.hits }
        [pscustomobject]@{ value = $s.value; n = $n + 300 } } })   # +300: varje underkategori kostar några anrop även om den är liten
  $total = ($subs | Measure-Object n -Sum).Sum
  $count = [math]::Max(1, [math]::Min(16, [math]::Ceiling($total / $PerShard)))
  $bins = @(1..$count | ForEach-Object { @{ n = 0; subs = [System.Collections.Generic.List[string]]::new() } })
  foreach ($s in $subs | Sort-Object n -Descending) {
    $b = $bins | Sort-Object { $_.n } | Select-Object -First 1
    $b.n += $s.n; $b.subs.Add($s.value)
  }
  $k = 0
  foreach ($b in $bins | Where-Object { $_.subs.Count }) {
    $k++
    $include.Add([ordered]@{ name = "$($w.name) $k/$count (~$([math]::Round($b.n / 1000))k)"; watch = $w.id; subs = ($b.subs -join ',') })
  }
}

# Tradera: dela huvudkategorierna på 4 jobb efter uppskattat antal sidor (sålda per 8 dagar, max 8 sidor per underkategori).
foreach ($w in $watches | Where-Object { $_.mode -eq 'tradera' }) {
  $tc = Read-Json (Join-Path $DataDir 'tradera-kategorier.json')
  $maxP = if ($w.maxPages) { [int]$w.maxPages } else { 8 }
  $tops = @($tc.categories | ForEach-Object { $n = 2; foreach ($s in $_.subs) { $n += [math]::Min($maxP, [math]::Ceiling(([int]$s.sold / 210 * 8) / 80) + 1) }; [pscustomobject]@{ id = [string]$_.id; n = $n } })
  $count = 4
  $bins = @(1..$count | ForEach-Object { @{ n = 0; subs = [System.Collections.Generic.List[string]]::new() } })
  foreach ($t in $tops | Sort-Object n -Descending) { $b = $bins | Sort-Object { $_.n } | Select-Object -First 1; $b.n += $t.n; $b.subs.Add($t.id) }
  $k = 0
  foreach ($b in $bins | Where-Object { $_.subs.Count }) { $k++; $include.Add([ordered]@{ name = "$($w.name) $k/$count (~$($b.n) sidor)"; watch = $w.id; subs = ($b.subs -join ',') }) }
}

$json = $script:Ser.Serialize((ConvertTo-Plain ([ordered]@{ include = $include.ToArray() })))
Write-Host "Jobb: $($include.Count)"; $include | ForEach-Object { Write-Host "  $($_.name)" }
if ($env:GITHUB_OUTPUT) {
  [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "matrix=$json`ncount=$($include.Count)`n", (New-Object Text.UTF8Encoding $false))
} else { $json }
