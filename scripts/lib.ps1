# Gemensamma funktioner för Thriftkollen-scrapern (Windows PowerShell 5.1, inget att installera).
# Filen är sparad som UTF-8 med BOM så att å, ä och ö läses rätt.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
# Utan detta skriver PowerShell 5.1 ibland listor som {"value":[...],"Count":n} i JSON.
Remove-TypeData System.Array -ErrorAction SilentlyContinue

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:DataDir  = Join-Path $script:RepoRoot 'data'
$script:Utf8     = New-Object System.Text.UTF8Encoding $false
$script:UA       = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$script:Cats     = @('Möbler & stolar', 'Porslin & glas', 'Elektronik & retro', 'Kläder & märken', 'Barn & fritid', 'Övrigt')

function Read-Json([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  return ([IO.File]::ReadAllText($path, $script:Utf8) | ConvertFrom-Json)
}
function Write-Json([string]$path, $obj, [int]$depth = 10) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
  [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $obj -Depth $depth -Compress), $script:Utf8)
}

function Get-Text([string]$url) {
  $r = Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{ 'User-Agent' = $script:UA; 'Accept-Language' = 'sv-SE,sv;q=0.9' } -TimeoutSec 30
  return [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}

function Normalize([string]$s) {
  if (-not $s) { return '' }
  $d = $s.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
  $d = [regex]::Replace($d, '\p{Mn}', '')
  $d = [regex]::Replace($d, "[^\p{L}\p{N} ]+", '')
  return [regex]::Replace($d, '\s+', ' ').Trim()
}
function Get-Id([string]$q) { return ((Normalize $q) -replace ' ', '-') }

$script:Exclude = @('kopes', 'sokes', 'trasig', 'defekt', 'reservdel', 'reservdelar', 'byte', 'hyres', 'uthyres')

function Test-Relevant([string]$title, [string[]]$must) {
  $n = ' ' + (Normalize $title) + ' '
  foreach ($x in $script:Exclude) { if ($n.Contains(" $x ")) { return $false } }
  foreach ($m in $must) { if (-not $n.Contains($m)) { return $false } }
  return $true
}

function Get-Quantile($arr, [double]$q) {
  $pos = ($arr.Count - 1) * $q; $lo = [math]::Floor($pos); $hi = [math]::Ceiling($pos)
  return $arr[$lo] + ($arr[$hi] - $arr[$lo]) * ($pos - $lo)
}
function Get-Stats([double[]]$prices) {
  $p = @($prices | Where-Object { $_ -gt 0 } | Sort-Object)
  if ($p.Count -eq 0) { return $null }
  if ($p.Count -ge 5) {
    $q1 = Get-Quantile $p 0.25; $q3 = Get-Quantile $p 0.75; $iqr = $q3 - $q1
    $lo = $q1 - 1.5 * $iqr; $hi = $q3 + 1.5 * $iqr
    $p = @($p | Where-Object { $_ -ge $lo -and $_ -le $hi })
  }
  return [ordered]@{
    n = $p.Count; med = [math]::Round((Get-Quantile $p 0.5))
    p25 = [math]::Round((Get-Quantile $p 0.25)); p75 = [math]::Round((Get-Quantile $p 0.75))
    min = [math]::Round($p[0]); max = [math]::Round($p[-1])
    prices = @($p | ForEach-Object { [math]::Round($_) })
  }
}

function Get-Blocket([string]$term, [string[]]$must) {
  $q = [uri]::EscapeDataString($term)
  $j = (Get-Text "https://www.blocket.se/recommerce/forsale/search/api/search/SEARCH_ID_BAP_COMMON?q=$q") | ConvertFrom-Json
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $items = @()
  foreach ($d in $j.docs) {
    if (-not $d.price -or -not $d.price.amount) { continue }
    if ($d.trade_type -and $d.trade_type -notmatch 'ljes$') { continue }   # bara "Säljes"
    if ($d.flags -contains 'retailer') { continue }
    if (-not (Test-Relevant $d.heading $must)) { continue }
    $img = $null
    if ($d.image -and $d.image.url) { $img = $d.image.url -replace '/dynamic/default/', '/dynamic/320w/' }
    $items += [ordered]@{
      s = 'b'; t = $d.heading; p = [int]$d.price.amount; img = $img
      u = $d.canonical_url; loc = $d.location
      age = [math]::Round(($now - [double]$d.timestamp) / 86400000, 1)
    }
  }
  $total = 0
  if ($j.metadata -and $j.metadata.result_size) { $total = [int]$j.metadata.result_size.match_count }
  return @{ items = $items; total = $total; url = "https://www.blocket.se/recommerce/forsale/search?q=$q" }
}

function Get-Tradera([string]$term, [string[]]$must) {
  $q = [uri]::EscapeDataString($term)
  $html = Get-Text "https://www.tradera.com/search?q=$q&itemStatus=Ended"
  $chunks = $html -split 'data-item-card-id="'
  $items = @(); $seen = @{}
  for ($i = 1; $i -lt $chunks.Count; $i++) {
    $c = $chunks[$i]
    $m = [regex]::Match($c, '^(\d+)"'); if (-not $m.Success) { continue }
    $id = $m.Groups[1].Value
    if ($seen.ContainsKey($id)) { continue }; $seen[$id] = 1
    $tm = [regex]::Match($c, 'title="([^"]+)"'); if (-not $tm.Success) { continue }
    $title = [System.Net.WebUtility]::HtmlDecode($tm.Groups[1].Value)
    $pm = [regex]::Match($c, 'data-testid="price">([\d\s ]+)\s*kr'); if (-not $pm.Success) { continue }
    $price = [int]([regex]::Replace($pm.Groups[1].Value, '\D', ''))
    if ($price -le 0) { continue }
    if (-not (Test-Relevant $title $must)) { continue }
    $href = [regex]::Match($c, 'href="(/item/[^"]+)"').Groups[1].Value
    $img = [regex]::Match($c, '(https://img\.tradera\.net/250-square/[^ "]+)').Groups[1].Value
    if (-not $img) { $img = [regex]::Match($c, 'src="(https://img\.tradera\.net/[^"]+)"').Groups[1].Value }
    $items += [ordered]@{ s = 't'; t = $title; p = $price; img = $img; u = "https://www.tradera.com$href"; type = [regex]::Match($c, 'data-item-type="([^"]+)"').Groups[1].Value }
  }
  return @{ items = $items; url = "https://www.tradera.com/search?q=$q&itemStatus=Ended" }
}

# Gör en liten JPEG-miniatyr som data-URI. Behövs bara för Claude-artifacten, som inte får ladda externa bilder.
function Get-Thumb([string]$url, [int]$size = 200) {
  if (-not $url) { return $null }
  try {
    Add-Type -AssemblyName System.Drawing
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $r = Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{ 'User-Agent' = $script:UA } -TimeoutSec 20
    $ms = New-Object System.IO.MemoryStream (, $r.Content)
    $src = [System.Drawing.Image]::FromStream($ms)
    $side = [math]::Min($src.Width, $src.Height)
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $size, $size), (New-Object System.Drawing.Rectangle ([int](($src.Width - $side) / 2)), ([int](($src.Height - $side) / 2)), $side, $side), [System.Drawing.GraphicsUnit]::Pixel)
    $ep = New-Object System.Drawing.Imaging.EncoderParameters 1
    $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]62)
    $out = New-Object System.IO.MemoryStream
    $bmp.Save($out, $codec, $ep)
    $g.Dispose(); $bmp.Dispose(); $src.Dispose(); $ms.Dispose()
    return 'data:image/jpeg;base64,' + [Convert]::ToBase64String($out.ToArray())
  } catch { return $null }
}

# Hämtar och sammanställer ett sökord från båda sajterna.
# $Must: ord som måste finnas i annonsens titel. Tomt = sökordets egna ord. '*' = inget krav.
function Invoke-Term([string]$Q, [string]$Cat, [string]$Must = '', [int]$DelayMs = 1000, [switch]$Thumbs) {
  $mustSrc = if ($Must) { $Must } else { $Q }
  $mustWords = if ($mustSrc -eq '*') { @() } else { @((Normalize $mustSrc) -split ' ' | Where-Object { $_.Length -ge 2 }) }
  $errors = @()
  $b = $null; $tr = $null
  try { $b = Get-Blocket $Q $mustWords } catch { $errors += "Blocket: $($_.Exception.Message)" }
  Start-Sleep -Milliseconds $DelayMs
  try { $tr = Get-Tradera $Q $mustWords } catch { $errors += "Tradera: $($_.Exception.Message)" }
  Start-Sleep -Milliseconds $DelayMs

  $bItems = if ($b) { @($b.items) } else { @() }
  $tItems = if ($tr) { @($tr.items) } else { @() }
  $bStats = Get-Stats ([double[]]@($bItems | ForEach-Object { $_.p }))
  $tStats = Get-Stats ([double[]]@($tItems | ForEach-Object { $_.p }))
  if ($bStats) {
    $ages = @($bItems | ForEach-Object { $_.age } | Sort-Object)
    $bStats['ageMed'] = $ages[[math]::Floor(($ages.Count - 1) / 2)]
    $bStats['total'] = $b.total
  }
  # Exempelannonser: de som ligger närmast medianpriset är mest representativa.
  $pick = @()
  foreach ($src in @(@{ it = $tItems; st = $tStats }, @{ it = $bItems; st = $bStats })) {
    if (-not $src.st) { continue }
    $med = $src.st.med
    $pick += @($src.it | Where-Object { $_.img } | Sort-Object { [math]::Abs($_.p - $med) } | Select-Object -First 4)
  }
  if ($Thumbs) {
    foreach ($l in $pick) { $u = $l.img -replace '/250-square/', '/small-square/'; $l.img = Get-Thumb $u }
    $pick = @($pick | Where-Object { $_.img })
  }
  return [ordered]@{
    id = Get-Id $Q; q = $Q; cat = $Cat; must = $mustSrc
    scrapedAt = (Get-Date).ToUniversalTime().ToString('o')
    tradera = [ordered]@{ stats = $tStats; url = $(if ($tr) { $tr.url } else { $null }) }
    blocket = [ordered]@{ stats = $bStats; url = $(if ($b) { $b.url } else { $null }) }
    listings = $pick
    errors = $errors
  }
}

function Format-Summary($r) {
  $t = $r.tradera.stats; $b = $r.blocket.stats
  $tm = if ($t) { "$($t.med) kr ($($t.n))" } else { '-' }
  $bm = if ($b) { "$($b.med) kr ($($b.n))" } else { '-' }
  return ("Tradera {0,-16} Blocket {1}" -f $tm, $bm)
}

# ---------- Snabb JSON för databasen (JavaScriptSerializer är ca 50x snabbare än ConvertFrom-Json) ----------
Add-Type -AssemblyName System.Web.Extensions
$script:Ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:Ser.MaxJsonLength = [int]::MaxValue
# PowerShell lindar in värden från pipelines i PSObject, som serialiseraren inte klarar. Packa upp dem.
function ConvertTo-Plain($o) {
  if ($null -eq $o) { return $null }
  if ($o -is [System.Management.Automation.PSObject]) { $o = $o.PSObject.BaseObject }
  if ($o -is [string] -or $o -is [ValueType]) { return $o }
  if ($o -is [System.Collections.IDictionary]) { $h = [ordered]@{}; foreach ($k in @($o.Keys)) { $h[[string]$k] = ConvertTo-Plain $o[$k] }; return $h }
  if ($o -is [System.Collections.IEnumerable]) { $l = [System.Collections.Generic.List[object]]::new(); foreach ($x in $o) { $l.Add((ConvertTo-Plain $x)) }; return , $l.ToArray() }
  if ($o -is [System.Management.Automation.PSCustomObject] -or $o.GetType().Name -eq 'PSCustomObject') { $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Plain $p.Value }; return $h }
  return $o
}
function Read-Db([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  return $script:Ser.DeserializeObject([IO.File]::ReadAllText($path, $script:Utf8))
}
function Write-Db([string]$path, $obj, [switch]$Fast) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $plain = if ($Fast) { $obj } else { ConvertTo-Plain $obj }
  [IO.File]::WriteAllText($path, $script:Ser.Serialize($plain), $script:Utf8)
}