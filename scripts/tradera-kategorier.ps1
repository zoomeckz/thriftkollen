# Hämtar Traderas kategoriträd (huvud- och underkategorier) med antal sålda, till data/tradera-kategorier.json.
# Behöver bara köras om Tradera ändrar sina kategorier.
. (Join-Path $PSScriptRoot 'lib.ps1')
function Get-Decoded([string]$url) {
  $h = Get-Text $url; $sb = [Text.StringBuilder]::new()
  foreach ($m in [regex]::Matches($h, 'self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)')) { [void]$sb.Append($script:Ser.DeserializeObject('"' + $m.Groups[1].Value + '"')) }
  return $sb.ToString()
}
$t = Get-Decoded 'https://www.tradera.com/categories'
$nodes = @{}
foreach ($m in [regex]::Matches($t, '\{"id":(\d+),"parentId":(\d+|null),"name":"((?:[^"\\]|\\.)*)","level":(\d)')) {
  $id = $m.Groups[1].Value; if (-not $nodes.ContainsKey($id)) { $nodes[$id] = @{ id = [int]$id; parent = $m.Groups[2].Value; name = $script:Ser.DeserializeObject('"' + $m.Groups[3].Value + '"'); level = [int]$m.Groups[4].Value } }
}
$tops = @($nodes.Values | Where-Object { $_.level -eq 1 } | Sort-Object name)
$out = foreach ($top in $tops) {
  Start-Sleep -Milliseconds 400
  $sold = @{}
  $e = Get-Decoded "https://www.tradera.com/category/$($top.id)?itemStatus=Ended"
  $i = $e.IndexOf('"activeCategory":')
  foreach ($m in [regex]::Matches($e.Substring([math]::Max(0, $i)), '\{"id":(\d+),"name":"(?:[^"\\]|\\.)*","url":"[^"]*","sortOrder":\d+,"children":\[\],"isSelected":false,"count":(\d+)')) { $sold[$m.Groups[1].Value] = [int]$m.Groups[2].Value }
  $subs = @($nodes.Values | Where-Object { $_.level -eq 2 -and $_.parent -eq [string]$top.id } | Sort-Object name | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; sold = [int]$sold[[string]$_.id] } })
  [ordered]@{ id = $top.id; name = $top.name; sold = ($subs | ForEach-Object { $_.sold } | Measure-Object -Sum).Sum; subs = $subs }
  Write-Host "$($top.name): $($subs.Count) underkategorier"
}
Write-Json (Join-Path $DataDir 'tradera-kategorier.json') ([ordered]@{ fetchedAt = (Get-Date).ToUniversalTime().ToString('o'); categories = @($out) }) 6
