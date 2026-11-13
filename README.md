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

### Databasen (djupscrape)

Under fliken **Databas** skapar du bevakningar: en Blocket-kategori (eller underkategori), ett område och valfritt sökord och prisintervall.
.github/workflows/databas.yml kör scripts/deep.ps1 varje natt kl 04 och när du trycker "Kör nu".

- Hämtar **alla** annonser. Blocket visar max 2 500 per sökning, så stora kategorier delas upp per län och prisintervall.
- Per annons: rubrik, pris, första pris och prishistorik, bild, antal bilder, ort, län, koordinater, märke, skick,
  frakt, köp nu, privat/företag, publiceringstid, först sedd, senast sedd och när den försvann.
- Statistik i appen: medianpris, säljtid, säljgrad, prissänkningar, per skick/märke/ort/län, privat mot företag,
  frakt, antal bilder, publiceringsdag, ord i rubriken, nya och försvunna per dag, underprissatta annonser och avstånd från Spånga.
- Databasen ligger på grenen db som en enda commit utan historik, så att repot inte växer varje natt.

### Hela Blocket, Tradera och stora statistiken

- **Hela Blocket** (`mode: "alla"` i data/bevakningar.json): alla underkategorier i ett område, en fil per underkategori.
  Stockholms län är ca 335 000 annonser. Körningen delas av scripts/plan.ps1 i ca 15 parallella jobb.
  Stora sökningar delas per kommun och sedan per prisintervall tills varje del ryms.
- **Tradera** (`mode: "tradera"`, scripts/tradera.ps1): sålda annonser med riktiga slutpriser i hela Sverige.
  Varje natt hämtas allt som sålts inom 8 dagar från att det lades upp, högst 8 sidor (640 st) per underkategori.
  Antalet till salu och Traderas egen räkning av sålda hämtas för alla 485 underkategorier.
  Kategorierna ligger i data/tradera-kategorier.json (scripts/tradera-kategorier.ps1 hämtar om dem).
- scripts/aggregate.ps1 bygger `overview.json` (läget i dag) och `trend.json` (en rad per natt) som statistiksidan läser.
- **statistik.html** är stora statistiken, byggd för datorskärm: nyckeltal, trädkarta, trender, pris mot fart,
  heatmap över veckodag och timme, karta, prisfördelning, märken, fynd, budkrig och en sorterbar tabell.
- Facebook Marketplace hämtas inte. Det kräver inloggning och Meta förbjuder automatisk insamling.

### Flippa: gemensam databas för Blocket och Tradera

scripts/kombo.ps1 körs sist i nattens databaskörning och slår ihop källorna per **varutyp**: ord och ordpar ur rubrikerna
("värmeelement", "maxi cosi", "babolat"). Bara privatpersoner räknas på Blocket.

- Per varutyp: till salu på Blocket (låg/median/hög), sålda på Blocket (försvunna annonser, pris och säljtid),
  sålda på Tradera senaste 30 dagarna (riktiga slutpriser) och sålda senaste veckan.
- **Pålitlighet:** *Säker* = Tradera-sålda och Blocket är överens om prisnivån och priserna spretar inte.
  *Blocket-sålda* = bygger på sålda Blocket-annonser. *Bara utropspris* = bara vad folk begär, osäkert (dolt som standard).
- Fliken **Flippa** i appen visar varutyper som klarar din vinstregel (köp i billigaste fjärdedelen eller för ditt butikspris,
  sälj för vad det brukar gå för), billiga annonser på Blocket just nu och sök på valfritt ord. Trenden per varutyp växer varje natt.
- Filer på grenen db: `kombo/flip.json` (appen), `kombo/terms.json` (alla ord), `kombo/trend/NN.json` (en rad per dag och ord).
- **Rättvist pris** = nedre 90 %-gränsen för medianen av sålda (ordningsstatistika, minst 10 sålda): minst hälften av
  försäljningarna nådde det priset, med 90 % säkerhet. Tradera-slutpriser och försvunna Blocket-annonser (minus 10 %).
  Den lägsta gränsen används. För få sålda: Blocket-median × kalibrerad kvot slutpris/utropspris × 0,85, märkt *Uppskattad*.
- **Facebook Marketplace** (`data/fb.json`): utropspriser i Stockholm för de bästa kandidaterna, kollade för hand i webbläsaren
  (inte automatiskt, Meta tillåter inte det). Visar var man kan köpa billigt och hur mycket som redan ligger ute.
- Knappen **Flippa** bredvid Meny öppnar listan direkt.

### Grenar

- **main**: appen, skripten och inställningar (bevakningar, kategorier, kontot). GitHub Pages bygger härifrån.
- **data**: det som ändras ofta: katalogen (`data/thriftdata.json`), fotade varor (`data/fynd.json`), sökord, kön av foton,
  bilderna och ditt krypterade lager (`data/lager.json`). Ligger här så att varje foto inte bygger om hela sidan.
- **db**: databasen (Blocket, Tradera, kombo). En enda commit utan historik som skrivs om varje natt.

### I mobilen

- **Installera appen:** öppna sidan i Safari/Chrome och välj "Lägg till på hemskärmen". Den startar snabbare och visar
  senaste datan även med dålig täckning (sw.js sparar appen och databasfilerna).
- **Direktsvar på foton:** lägg in en Claude-nyckel under Inställningar → Konto. Då känner mobilen igen varan direkt och
  slår upp priset i den stora databasen på några sekunder. Den fulla scrapen körs fortfarande på GitHub, utan dubbel kostnad.
- **Sök i allt:** sökrutan visar också träffar i den stora databasen (Blocket + Tradera, rättvist pris och max i butik).
- **Annonshjälp:** "Skriv annons" på fotade varor och i lagret ger rubrik, beskrivning och priser för Blocket och Tradera.
- **Lagret på kontot:** sparas krypterat (AES-GCM, nyckeln ligger i ditt lösenordsskyddade konto) och synkas mellan enheter.
- **Din statistik** i lagret: vinst per månad, plattform och kategori, vinst per dag i lager och hur väl appens uppskattningar stämmer.
- **Frakt:** under Dina regler väljer du förpackningskostnad och om du bjuder på frakten. Flippa vet vad frakten brukar kosta per varutyp.
- **Vakt:** om nattens databaskörning inte har gått (GitHub tappar ibland schemalagda körningar) startar appen den när du öppnar den inloggad.

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
