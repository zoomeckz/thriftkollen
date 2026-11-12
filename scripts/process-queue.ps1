# Behandlar foton som appen har laddat upp till queue/:
#  1. Claude tittar på bilden (och din text) och säger vad det är, märke och bra sökord.
#  2. Scrapar samma märke/modell och varutypen i stort på Blocket och Tradera.
#  3. Sparar resultatet i data/fynd.json och lägger varutypen som nytt sökord i katalogen.
# Kräver hemligheten ANTHROPIC_API_KEY för bildigenkänning. Utan den används bara din text.

param([int]$DelayMs = 800)
. (Join-Path $PSScriptRoot 'lib.ps1')

$queueDir = Join-Path $RepoRoot 'queue'
$jobs = @(Get-ChildItem -Path $queueDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $jobs.Count) { Write-Host 'Inga foton i kön.'; return }

function Invoke-Identify([string]$imagePath, [string]$text, [string]$catHint) {
  $key = $env:ANTHROPIC_API_KEY
  if (-not $key) { return $null }
  $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($imagePath))
  $hint = if ($text) { "Användaren beskriver varan så här: `"$text`"." } else { 'Användaren har inte skrivit någon beskrivning.' }
  if ($catHint) { $hint += " Användaren tror att kategorin är: $catHint." }
  $prompt = @"
Du hjälper en person i Stockholm som köper saker på en second hand-butik och säljer dem vidare på Blocket och Tradera.
Identifiera varan på bilden så att vi kan söka fram jämförbara annonser. $hint

Fält:
- name: kort svenskt namn på varan, med märke och modell om de syns (t.ex. "Thule Yepp Maxi barncykelstol").
- brand och model: tom sträng om det inte går att avgöra. Gissa inte fram en modell.
- category: välj en av: $($Cats -join ', ').
- specificQuery: 2-4 ord som hittar samma märke/modell på Blocket och Tradera, skrivet som svenska säljare skriver annonsrubriker. Om märket är okänt: samma som genericQuery.
- specificMust: 1-2 ord som måste stå i annonsrubriken (oftast märket), mellanslagsseparerade. '*' om inget krav.
- genericQuery: 1-3 ord för varutypen i stort på svenska, som det skrivs i annonser (t.ex. "barncykelstol"), för att jämföra prisnivån mellan märken.
- genericMust: ett ord som måste stå i rubriken, eller '*' om rubrikerna varierar för mycket.
- notes: en kort svensk mening om vad som påverkar priset mest för just den här varan.
- confidence: low, medium eller high.
"@
  $schema = [ordered]@{
    type = 'object'; additionalProperties = $false
    required = @('name', 'brand', 'model', 'category', 'specificQuery', 'specificMust', 'genericQuery', 'genericMust', 'notes', 'confidence')
    properties = [ordered]@{
      name = @{ type = 'string' }; brand = @{ type = 'string' }; model = @{ type = 'string' }
      category = @{ type = 'string'; enum = $Cats }
      specificQuery = @{ type = 'string' }; specificMust = @{ type = 'string' }
      genericQuery = @{ type = 'string' }; genericMust = @{ type = 'string' }
      notes = @{ type = 'string' }
      confidence = @{ type = 'string'; enum = @('low', 'medium', 'high') }
    }
  }
  $body = [ordered]@{
    model = 'claude-opus-5-5'
    max_tokens = 8000
    fallbacks = 'default'
    output_config = [ordered]@{ effort = 'low'; format = [ordered]@{ type = 'json_schema'; schema = $schema } }
    messages = @(@{ role = 'user'; content = @(
      [ordered]@{ type = 'image'; source = [ordered]@{ type = 'base64'; media_type = 'image/jpeg'; data = $b64 } },
      [ordered]@{ type = 'text'; text = $prompt }
    ) })
  } | ConvertTo-Json -Depth 20 -Compress
  $headers = @{ 'x-api-key' = $key; 'anthropic-version' = '2026-10-21'; 'anthropic-beta' = 'server-side-fallback-2026-07-01' }
  $resp = Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://api.anthropic.com/v1/messages' -Headers $headers `
    -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 180
  $r = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
  if ($r.stop_reason -eq 'refusal') { throw 'Claude avböjde att identifiera bilden.' }
  $txt = ($r.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
  if (-not $txt) { throw "Tomt svar från Claude (stop_reason: $($r.stop_reason))." }
  $ai = $txt | ConvertFrom-Json
  $ai | Add-Member -NotePropertyName model_used -NotePropertyValue $r.model -Force
  return $ai
}

$fyndFile   = Join-Path $DataDir 'fynd.json'
$thriftFile = Join-Path $DataDir 'thriftdata.json'
$termFile   = Join-Path $DataDir 'sokord.json'
$fynd   = Read-Json $fyndFile;   $items = if ($fynd -and $fynd.items) { @($fynd.items) } else { @() }
$thrift = Read-Json $thriftFile; $tterms = if ($thrift -and $thrift.terms) { @($thrift.terms) } else { @() }
$sokord = @(Read-Json $termFile)

foreach ($f in $jobs) {
  $job = Read-Json $f.FullName
  $id = if ($job.id) { [string]$job.id } else { $f.BaseName }
  Write-Host "== Foto $id" -ForegroundColor Cyan
  $item = [ordered]@{ id = $id; createdAt = $job.createdAt; processedAt = (Get-Date).ToUniversalTime().ToString('o')
    photo = $job.image; text = $job.text; status = 'klar'; message = ''; ai = $null; specific = $null; generic = $null }
  try {
    $imgPath = if ($job.image) { Join-Path $RepoRoot $job.image } else { $null }
    $ai = $null
    if ($imgPath -and (Test-Path $imgPath)) {
      try { $ai = Invoke-Identify $imgPath $job.text $job.cat }
      catch { $item.message = "Bildigenkänningen misslyckades: $($_.Exception.Message)"; Write-Host $item.message -ForegroundColor Yellow }
    }
    if (-not $ai) {
      if (-not $job.text) { throw 'Ingen text och ingen bildigenkänning. Skriv vad det är, eller lägg in ANTHROPIC_API_KEY som hemlighet i repot.' }
      $cat = if ($Cats -contains $job.cat) { $job.cat } else { 'Övrigt' }
      $ai = [pscustomobject]@{ name = $job.text; brand = ''; model = ''; category = $cat; specificQuery = $job.text; specificMust = ''
        genericQuery = $job.text; genericMust = ''; notes = ''; confidence = 'low'; model_used = 'text' }
    }
    $item.ai = $ai
    Write-Host "   $($ai.name)  [$($ai.category)]  specifik: '$($ai.specificQuery)'  generell: '$($ai.genericQuery)'"
    $spec = Invoke-Term -Q $ai.specificQuery -Cat $ai.category -Must $ai.specificMust -DelayMs $DelayMs
    Write-Host ("   specifik  " + (Format-Summary $spec))
    $spec.Remove('errors'); $item.specific = $spec
    if ((Get-Id $ai.genericQuery) -ne (Get-Id $ai.specificQuery)) {
      $gen = Invoke-Term -Q $ai.genericQuery -Cat $ai.category -Must $ai.genericMust -DelayMs $DelayMs
      Write-Host ("   generell  " + (Format-Summary $gen))
      $gen.Remove('errors'); $item.generic = $gen
    } else { $gen = $spec }

    # Lägg varutypen i katalogen och i sökorden, så att den följer med i varje full scrape.
    $gid = Get-Id $ai.genericQuery
    if ($gid -and -not ($sokord | Where-Object { (Get-Id $_.q) -eq $gid })) {
      $sokord += [ordered]@{ q = $ai.genericQuery; cat = $ai.category; must = $ai.genericMust; source = 'foto' }
    }
    $g2 = [ordered]@{}; foreach ($k in $gen.Keys) { $g2[$k] = $gen[$k] }; $g2['source'] = 'foto'
    $tterms = @($tterms | Where-Object { $_.id -ne $gid }) + @([pscustomobject]$g2)
  } catch {
    $item.status = 'fel'; $item.message = $_.Exception.Message
    Write-Host "   FEL: $($item.message)" -ForegroundColor Red
  }
  $items = @([pscustomobject]$item) + @($items | Where-Object { $_.id -ne $id }) | Select-Object -First 300
  Remove-Item $f.FullName -Force
}

Write-Json $fyndFile ([ordered]@{ updatedAt = (Get-Date).ToUniversalTime().ToString('o'); items = @($items) })
Write-Json $thriftFile ([ordered]@{ version = 2; generatedAt = $(if ($thrift) { $thrift.generatedAt } else { (Get-Date).ToUniversalTime().ToString('o') }); terms = @($tterms) })
Write-Json $termFile @($sokord) 4
Write-Host "Klart: $($jobs.Count) foton behandlade." -ForegroundColor Green
