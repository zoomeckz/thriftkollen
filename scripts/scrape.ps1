# Full scrape av alla sökord i data/sokord.json -> data/thriftdata.json
# Lokalt:  Thriftkollen-scrape.bat  (scrapar och pushar till GitHub)
# Valfritt: -Only "lego,walkman"  -Thumbs (inbäddade miniatyrer för Claude-artifacten)  -Push (git commit + push)

param(
  [string]$Only = '',
  [int]$DelayMs = 1000,
  [switch]$Thumbs,
  [switch]$Push
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$termFile = Join-Path $DataDir 'sokord.json'
$outFile  = Join-Path $DataDir 'thriftdata.json'
$terms = @(Read-Json $termFile)
if ($Only) {
  $want = @($Only -split ',' | ForEach-Object { Normalize $_ })
  $terms = @($terms | Where-Object { $want -contains (Normalize $_.q) })
}

# Behåll tidigare data för sökord som inte körs nu (t.ex. med -Only).
$existing = Read-Json $outFile
$byId = [ordered]@{}
if ($existing -and $existing.terms) { foreach ($t in $existing.terms) { $byId[$t.id] = $t } }

$start = Get-Date; $k = 0; $fails = @()
foreach ($t in $terms) {
  $k++
  Write-Host ("[{0,2}/{1}] {2,-30}" -f $k, $terms.Count, $t.q) -NoNewline
  $mustArg = if ($t.must) { [string]$t.must } else { '' }
  $r = Invoke-Term -Q $t.q -Cat $t.cat -Must $mustArg -DelayMs $DelayMs -Thumbs:$Thumbs
  if ($t.source) { $r['source'] = $t.source }
  $fails += @($r.errors | ForEach-Object { "$($t.q): $_" })
  $r.Remove('errors')
  $byId[$r.id] = $r
  Write-Host (Format-Summary $r)
}

# Ta bort sökord som inte längre finns i sokord.json.
$keep = @{}; foreach ($t in @(Read-Json $termFile)) { $keep[(Get-Id $t.q)] = 1 }
$final = @($byId.Values | Where-Object { $keep.ContainsKey($_.id) })

Write-Json $outFile ([ordered]@{ version = 2; generatedAt = (Get-Date).ToUniversalTime().ToString('o'); terms = $final })
Write-Host ""
Write-Host "Klart: $k sökord på $([math]::Round(((Get-Date) - $start).TotalSeconds)) s -> $outFile" -ForegroundColor Green
if ($fails.Count) { Write-Host "Fel ($($fails.Count)):" -ForegroundColor Yellow; $fails | ForEach-Object { Write-Host "  $_" } }
if ($fails.Count -gt [math]::Max(4, $terms.Count)) { throw "För många fel - Blocket eller Tradera verkar blockera." }

if ($Push) {
  Push-Location $RepoRoot
  try {
    git pull --rebase --autostash
    git add data
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) { git commit -m "Scrape $(Get-Date -Format 'yyyy-MM-dd HH:mm')"; git push }
    else { Write-Host 'Inga ändringar att pusha.' }
  } finally { Pop-Location }
}
