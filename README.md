# Thriftkollen

Ett verktyg för att köpa second hand billigt (Skyddsvärnet i Spånga) och sälja vidare på Blocket, Tradera och FB Marketplace.
Appen visar vad som lönar sig att plocka med sig och hur mycket du högst kan betala i butiken. Kravet är minst 100 kr vinst eller x2, efter avgifter.

**Appen:** öppnas via GitHub Pages för det här repot. Lägg den på mobilens hemskärm.

## Så hänger det ihop

| Del | Var | Vad den gör |
|---|---|---|
| `index.html` | GitHub Pages | Appen: katalog, fota vara, lager, statistik, inställningar. |
| `data/sokord.json` | repot | Sökorden som bevakas. Ändras från appen eller för hand. |
| `data/thriftdata.json` | repot | Prisdata per sökord från Tradera (avslutade annonser) och Blocket (aktiva annonser). |
| `data/fynd.json` | repot | Fotade varor: vad Claude såg på bilden och jämförelsen. |
| `uploads/`, `queue/` | repot | Foton från appen och kön som väntar på att scrapas. |
| `scripts/*.ps1` | Actions eller din dator | Scrapern. Windows PowerShell 5.1, inget att installera. |
| `.github/workflows/scrape.yml` | GitHub Actions | Kör scrapen när ett foto kommer in, när du trycker på knappen i appen, och måndag och torsdag kl 06. |

### Fotoflödet

1. Du tar en bild i appen och skriver valfritt vad det är.
2. Appen laddar upp bilden till `uploads/` och en beställning till `queue/`.
3. Actions startar. Claude (`claude-sonnet-5-5`) tittar på bilden och tar fram märke, modell och sökord.
4. Scrapern hämtar samma märke/modell och varutypen i stort från Blocket och Tradera.
5. Resultatet sparas i `data/fynd.json`, och varutypen läggs till som sökord i katalogen.
6. Appen märker att det är klart och visar jämförelsen. Det tar oftast 2–4 minuter.

## Engångsinställning

1. **Hemlighet för bildigenkänning:** Settings → Secrets and variables → Actions → New repository secret.
   Namn `ANTHROPIC_API_KEY`, värde din nyckel från console.anthropic.com. Utan den används bara texten du skriver.
2. **GitHub Pages:** Settings → Pages → Deploy from a branch → `main` / `(root)`.
3. **Nyckel för appen:** skapa en *fine-grained personal access token* som bara gäller det här repot,
   med **Contents: Read and write** och **Actions: Read and write**. Klistra in den i appen under Inställningar → Avancerat.
4. **Spara nyckeln på kontot:** välj ett lösenord under Inställningar → Konto. Nyckeln krypteras i webbläsaren
   (PBKDF2-SHA256, 600 000 varv, AES-GCM-256) och bara den krypterade versionen sparas i data/konto.json.
   På en annan mobil eller dator öppnar du appen och loggar in med lösenordet. Lånar du någons mobil, bocka ur
   "Kom ihåg mig", så glöms nyckeln när fliken stängs.
## Köra scrapen på datorn

Dubbelklicka på `Thriftkollen-scrape.bat`. Den scrapar alla sökord och pushar resultatet till GitHub.
Det är reserv ifall Blocket eller Tradera skulle blockera GitHubs servrar.

## Bra att veta

- Repot är publikt. Prisdata och foton syns för alla som hittar det. Lagret (dina köp) sparas bara i mobilen.
- Tradera-avgiften är satt till 10 %, max 200 kr. Det går att ändra i appen.
- Facebook Marketplace scrapas inte, eftersom det kräver inloggning och Meta förbjuder det.
- Bildigenkänningen kostar ungefär 10–15 öre per bild i API-avgift. Den faktiska kostnaden visas per foto i appen och totalt under Statistik.
