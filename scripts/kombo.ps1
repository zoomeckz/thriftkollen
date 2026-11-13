# Gemensam databas för alla källor (Blocket + Tradera) och flipp-listan.
#
# Varje annons delas upp i ord och ordpar ur rubriken ("värmeelement", "maxi cosi", "dualsense").
# Per ord räknas, över alla källor:
#   Blocket: till salu nu (utropspris), försvunna senaste 30 d (= sålda, pris och säljtid)
#   Tradera: sålda senaste 30 d (riktiga slutpriser) och sålda senaste 7 d
# Ett ord är "pålitligt" när priserna hänger ihop (inte spretar) och källorna är överens om nivån,
# alltså när ordet betyder samma sorts vara överallt. Bara pålitliga ord kommer med i flipp-listan.
#
# Filer (på grenen db):
#   kombo/terms.json       alla ord med tillräckligt mycket data (sök "hur går värmeelement?")
#   kombo/flip.json        pålitliga ord + konkreta billiga annonser på Blocket + totaler per dag
#   kombo/trend/NN.json    en rad per dag och ord, uppdelat på 32 filer (NN = hash av ordet)
#
# Användning:  scripts\kombo.ps1 -DbDir dbdata

param([string]$DbDir = 'dbdata', [int]$KeepDays = 365)
. (Join-Path $PSScriptRoot 'lib.ps1')
if (-not [IO.Path]::IsPathRooted($DbDir)) { $DbDir = Join-Path $RepoRoot $DbDir }
$t0 = Get-Date

Add-Type -ReferencedAssemblies System.Core -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

public class KTerm {
  public List<int> BAct = new List<int>(), BGone = new List<int>(), BSell = new List<int>(), TSold = new List<int>(), TShip = new List<int>();
  public int TWeek;
  public int[] S;            // b10 b25 b50 b75 g50 s50 t25 t50 t75
  public int Conf, Cov;
  public int TL, GL, Fair, Src, Ship;   // Ship = median billigaste frakt på Tradera (köparen betalar oftast)   // nedre gräns för medianen (Tradera, Blocket-sålda), rättvist pris, källa (1 Tradera, 2 Blocket-sålda, 4 uppskattat ur utropspris)
}
public class KListing { public long Id; public string T, Img, Loc; public int P, PubDay, Km; public string[] Keys; }

public static class Kombo {
  public static HashSet<string> Stop = new HashSet<string>();
  public static Dictionary<string, KTerm> Terms = new Dictionary<string, KTerm>();
  public static List<KListing> Active = new List<KListing>();
  static HashSet<long> seenB = new HashSet<long>(), seenT = new HashSet<long>();
  public static int Today;
  static readonly Regex Word = new Regex(@"[\p{L}\p{N}]+", RegexOptions.Compiled);
  static readonly Regex Unit = new Regex(@"^\d+(ml|cl|dl|cm|mm|m|w|kw|v|kg|g|st|l|år|kr|x|p|gb|tb|hz|mah|tum)$", RegexOptions.Compiled);
  static readonly Regex Bad = new Regex(@"\b(köpes|sökes|söker|bytes|byte|reservdel\w*|defekt\w*|trasig\w*|fungerar ej|ej fungerande|delar till|endast kartong|tom kartong|spricka|sprucken|skadad|needs|broken|for parts)\b", RegexOptions.Compiled);
  const double HomeLat = 59.39, HomeLon = 17.905;   // Spånga

  public static string[] Keys(string title) {
    if (string.IsNullOrEmpty(title)) return new string[0];
    var w = new List<string>();
    foreach (Match m in Word.Matches(title.ToLowerInvariant())) {
      string s = m.Value;
      if (s.Length < 3 || Stop.Contains(s) || Unit.IsMatch(s)) continue;
      bool digits = true; foreach (char c in s) if (!char.IsDigit(c)) { digits = false; break; }
      if (digits) continue;
      w.Add(s);
    }
    var o = new HashSet<string>(w);
    for (int i = 0; i + 1 < w.Count; i++) if (w[i] != w[i + 1]) o.Add(w[i] + " " + w[i + 1]);
    return o.ToArray();
  }
  static KTerm Get(string k) { KTerm t; if (!Terms.TryGetValue(k, out t)) { t = new KTerm(); Terms[k] = t; } return t; }
  static long L(object o) { return o == null ? 0 : Convert.ToInt64(o); }
  static double D(object o) { return o == null ? double.NaN : Convert.ToDouble(o); }

  // Blocket: rader enligt cols i deep.ps1. Samma annons kan ligga i flera bevakningar, räknas en gång.
  public static int AddBlocket(object[] rows, Dictionary<string, int> C, string imgBase) {
    int n = 0;
    foreach (object o in rows) {
      var r = (object[])o;
      long id = L(r[C["id"]]); if (!seenB.Add(id)) continue;
      int p = (int)L(r[C["p"]]); if (p < 10) continue;
      if ((L(r[C["fl"]]) & 4) != 0) continue;   // företag: andra priser än privatpersoner, räknas inte
      string t = r[C["t"]] as string; var keys = Keys(t); if (keys.Length == 0) continue;
      int gone = (int)L(r[C["gone"]]); int pubDay = (int)Math.Floor(L(r[C["pub"]]) / 86400.0);
      if (gone == 0) {
        foreach (var k in keys) Get(k).BAct.Add(p);
        int cond = (int)L(r[C["cond"]]);
        if (cond != 5 && Today - pubDay <= 21 && !Bad.IsMatch(t.ToLowerInvariant())) {
          double lat = D(r[C["lat"]]), lon = D(r[C["lon"]]);
          int km = double.IsNaN(lat) || double.IsNaN(lon) ? -1 : (int)Math.Round(Math.Sqrt(Math.Pow((lat - HomeLat) * 111, 2) + Math.Pow((lon - HomeLon) * 111 * Math.Cos(HomeLat * Math.PI / 180), 2)));
          string img = r[C["img"]] as string; if (!string.IsNullOrEmpty(img) && img.IndexOf('/') < 0) img = "item/" + id + "/" + img;   // kompakt format: bara uuid
          Active.Add(new KListing { Id = id, T = t, P = p, PubDay = pubDay, Km = km, Img = string.IsNullOrEmpty(img) ? "" : imgBase + img, Loc = (r[C["loc"]] as string) ?? "", Keys = keys });
        }
      } else if (Today - gone <= 30) {
        foreach (var k in keys) { var x = Get(k); x.BGone.Add(p); if (gone >= pubDay) x.BSell.Add(gone - pubDay); }
      }
      n++;
    }
    return n;
  }
  // Tradera: sålda annonser, cols enligt tradera.ps1.
  public static int AddTradera(object[] rows, Dictionary<string, int> C) {
    int n = 0;
    foreach (object o in rows) {
      var r = (object[])o;
      long id = L(r[C["id"]]); if (!seenT.Add(id)) continue;
      int p = (int)L(r[C["p"]]); if (p < 10) continue;
      int endDay = (int)Math.Floor(L(r[C["end"]]) / 86400.0); if (Today - endDay > 30) continue;
      int ship = C.ContainsKey("ship") ? (int)L(r[C["ship"]]) : 0;
      foreach (var k in Keys(r[C["t"]] as string)) { var x = Get(k); x.TSold.Add(p); if (ship > 0) x.TShip.Add(ship); if (Today - endDay < 7) x.TWeek++; }
      n++;
    }
    return n;
  }

  public static double AskToSold = 0.85;   // kalibreras varje natt: Tradera-slutpris / Blocket-utropspris för samma varutyp

  // Nedre 90 %-gräns för medianen, utan antaganden om fördelningen (ordningsstatistika + binomialfördelning).
  // Med n sålda är minst hälften av alla försäljningar >= X(k) med 90 % säkerhet. Kräver minst 10 sålda.
  // r = största rangen (1-baserad) där P(Bin(n, 0,5) <= r - 1) <= alpha. Då gäller P(X(r) <= median) >= 1 - alpha.
  public static int LcbMedian(List<int> s, double alpha) {
    int n = s.Count; if (n < 10) return 0;
    int r;
    if (n > 200) r = (int)Math.Floor(n / 2.0 - 1.2816 * Math.Sqrt(n) / 2.0);   // normalapproximation, avrundad nedåt (försiktig)
    else {
      double pmf = Math.Pow(0.5, n), cdf = 0; r = 0;
      for (int j = 0; j < n; j++) { cdf += pmf; if (cdf > alpha) break; r = j + 1; pmf = pmf * (n - j) / (j + 1); }
    }
    return s[Math.Max(0, Math.Min(n - 1, r - 1))];   // rang r -> index r - 1
  }

  static int Q(List<int> s, double q) { return s.Count == 0 ? 0 : s[(int)Math.Floor((s.Count - 1) * q)]; }

  // Räknar fram statistik och pålitlighet. conf: 3 = Tradera och Blocket överens, 2 = Blocket med sålda (försvunna),
  // 1 = bara Blocket-utropspriser men samlade, 0 = för lite eller för spretigt för att flippa på.
  public static void Compute(int minN) {
    foreach (var k in Terms.Keys.ToList()) {
      var t = Terms[k];
      if (t.BAct.Count + t.BGone.Count + t.TSold.Count < minN) { Terms.Remove(k); continue; }
      t.BAct.Sort(); t.BGone.Sort(); t.BSell.Sort(); t.TSold.Sort(); t.TShip.Sort(); t.Ship = Q(t.TShip, .5);
      t.S = new int[] { Q(t.BAct, .1), Q(t.BAct, .25), Q(t.BAct, .5), Q(t.BAct, .75), Q(t.BGone, .5), Q(t.BSell, .5), Q(t.TSold, .25), Q(t.TSold, .5), Q(t.TSold, .75) };
      int b25 = t.S[1], b50 = t.S[2], b75 = t.S[3], g50 = t.S[4], t25 = t.S[6], t50 = t.S[7], t75 = t.S[8];
      bool bOk = t.BAct.Count >= 8 && b25 > 0 && b75 <= 3.5 * b25;
      bool tOk = bOk && t.TSold.Count >= 8 && t25 > 0 && t75 <= 3.5 * t25 && t50 >= 0.55 * b50 && t50 <= 1.6 * b50;
      bool gOk = bOk && t.BGone.Count >= 8 && g50 >= 0.5 * b50 && g50 <= 1.4 * b50;
      t.Conf = !bOk ? 0 : tOk ? 3 : gOk ? 2 : t.BAct.Count >= 15 ? 1 : 0;
      t.TL = LcbMedian(t.TSold, 0.10); t.GL = LcbMedian(t.BGone, 0.10);
    }
    // Kalibrering: hur mycket lägre är slutpriset på Tradera än utropspriset på Blocket, för samma varutyp?
    var ratios = Terms.Values.Where(t => t.Conf == 3 && t.TSold.Count >= 10).Select(t => (double)t.S[7] / t.S[2]).OrderBy(x => x).ToList();
    if (ratios.Count >= 30) AskToSold = Math.Max(0.5, Math.Min(1.0, ratios[ratios.Count / 2]));
    // Rättvist pris = den försiktigaste av de nedre gränserna från riktiga försäljningar.
    // Blocket-försvunna räknas ner 10 %, eftersom en del togs bort utan att säljas.
    foreach (var t in Terms.Values) {
      var c = new List<int>(); t.Src = 0;
      if (t.Conf == 3 && t.TL > 0) { c.Add(t.TL); t.Src |= 1; }
      if (t.Conf >= 2 && t.GL > 0) { c.Add((int)(t.GL * 0.9)); t.Src |= 2; }
      if (c.Count > 0) t.Fair = c.Min();
      else if (t.Conf >= 1) { t.Fair = (int)(t.S[2] * AskToSold * 0.85); t.Src = 4; }
      else t.Fair = 0;
    }
    // Ett ensamt ord som nästan bara förekommer i ett visst ordpar ("cosi" i "maxi cosi") visas som ordparet.
    foreach (var kv in Terms) {
      int sp = kv.Key.IndexOf(' '); if (sp < 0 || kv.Value.Conf == 0) continue;
      int n2 = kv.Value.BAct.Count + kv.Value.TSold.Count;
      foreach (var u in new[] { kv.Key.Substring(0, sp), kv.Key.Substring(sp + 1) }) {
        KTerm x; if (Terms.TryGetValue(u, out x) && n2 >= 0.7 * (x.BAct.Count + x.TSold.Count)) x.Cov = 1;
      }
    }
  }

  // Säljvärde = rättvist pris. Tradera-avgift (10 %, minst 3, högst 200 kr) dras när priset bygger på Tradera.
  static double Resale(KTerm t, out double fee) {
    fee = (t.Src & 1) != 0 ? Math.Min(200, Math.Max(3, t.Fair * 0.10)) : 0;
    return t.Fair;
  }
  public static object[] TermRows() {
    return Terms.OrderByDescending(kv => kv.Value.BAct.Count + kv.Value.TSold.Count).Select(kv => {
      var t = kv.Value;
      return (object)new object[] { kv.Key, t.BAct.Count, t.S[0], t.S[1], t.S[2], t.S[3], t.BGone.Count, t.S[4], t.S[5], t.TSold.Count, t.S[6], t.S[7], t.S[8], t.TWeek, t.Conf, t.Cov, t.TL, t.GL, t.Fair, t.Src, t.Ship };
    }).ToArray();
  }
  // Konkreta annonser på Blocket som ligger långt under vad varan brukar gå för.
  public static object[] Deals(int max) {
    var o = new List<Tuple<double, object[]>>();
    foreach (var l in Active) {
      KTerm best = null; string bk = null; double bs = 0;
      foreach (var k in l.Keys) {
        KTerm t; if (!Terms.TryGetValue(k, out t) || t.Conf == 0 || t.Fair <= 0) continue;
        double s = t.Conf * 10 + (k.IndexOf(' ') > 0 ? 5 : 0) - (double)t.S[3] / Math.Max(1, t.S[1]);
        if (best == null || s > bs) { best = t; bk = k; bs = s; }
      }
      if (best == null) continue;
      double fee; double r = Resale(best, out fee); double net = r - fee;
      if (l.P < 0.15 * r || l.P > 0.6 * net || net - l.P < 80) continue;
      double w = best.Conf == 3 ? 1 : best.Conf == 2 ? 0.8 : 0.4;
      o.Add(Tuple.Create(w * (net - l.P), new object[] { l.Id, l.T, l.P, l.Img, l.Loc, l.PubDay, l.Km, bk }));
    }
    // De bästa i varje prisklass, så att billiga flippar inte trängs undan av dyra klockor.
    var bands = new[] { 300, 1000, 5000, int.MaxValue };
    var res = new List<object>(); int lo = 0;
    foreach (int hi in bands) {
      int a = lo;
      res.AddRange(o.Where(x => (int)x.Item2[2] >= a && (int)x.Item2[2] < hi).OrderByDescending(x => x.Item1).Take(max / bands.Length).Select(x => (object)x.Item2));
      lo = hi;
    }
    return res.ToArray();
  }
  // Trend per fil (shard): gamla rader (utom dagens, och högst keep dagar bakåt) + en ny rad per ord i dag.
  public static Dictionary<string, object> Trend(object old, int shard, int keep) {
    var o = new Dictionary<string, object>();
    var od = old as Dictionary<string, object>;
    if (od != null) foreach (var kv in od) {
      var rows = kv.Value as object[]; if (rows == null) continue;
      var kept = new List<object>();
      foreach (var x in rows) { var r = x as object[]; if (r == null || r.Length != 8 || !(r[0] is int)) continue; int d = (int)r[0]; if (d == Today || Today - d > keep) continue; kept.Add(r); }
      if (kept.Count > 0) o[kv.Key] = kept;
    }
    foreach (var kv in Terms) {
      var t = kv.Value;
      if (t.Conf == 0 && t.BAct.Count + t.TSold.Count < 40) continue;
      if (Hash(kv.Key) % 32 != shard) continue;
      object l; if (!o.TryGetValue(kv.Key, out l)) { l = new List<object>(); o[kv.Key] = l; }
      ((List<object>)l).Add(new object[] { Today, t.BAct.Count, t.S[2], t.BGone.Count, t.S[4], t.TSold.Count, t.S[7], t.TWeek });
    }
    return o;
  }
  public static uint Hash(string s) {
    uint h = 2166136261; foreach (byte b in Encoding.UTF8.GetBytes(s)) { h ^= b; h *= 16777619; } return h;
  }
}
'@

[Kombo]::Today = [int][math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) / 86400)
foreach ($w in @'
och med till för som från utan inte helt nytt nya ny nyskick skick bra fint fin fina snygg snygga säljes säljs säljer sälj pris
kronor oanvänd oanvänt oanvända använd använt begagnad begagnat storlek stl strl färg vit vitt vita svart svarta grå grått blå blått
röd rött grön gröna brun bruna beige rosa gul små stor stort stora liten litet lilla olika flera styck mycket perfekt nästan aldrig
the and for with from new size black white grey gray blue used good condition fraktar frakt ingår inkl hämtas finns obs har den det
ett är kan alla mer passar endast par set sitt sina din mitt våra ute inne extra super fräsch fräscht äkta original orginal riktigt
typ cirka lite modell märke dam herr barn unisex till salu billigt billig snabb affär bud gratis pent välvårdad välskött hel
moms exkl finans finansiering totalvikt lastar samt köpa köp skyltexemplar demo leverans omgående lager butik
vattentät vattentätt auktion testat otestat testad edition deluxe pro max mini plus lite planta varmvit varmvitt pla hubb utrop utropspris spel paket
'@ -split '\s+' | Where-Object { $_ }) { [void][Kombo]::Stop.Add($w) }

function Get-Cols($d) { $c = New-Object 'System.Collections.Generic.Dictionary[string,int]'; $i = 0; foreach ($x in $d['cols']) { $c[[string]$x] = $i++ }; return , $c }

# ---------- läs in källorna ----------
$watches = @(Read-Json (Join-Path $DataDir 'bevakningar.json') | Where-Object { $_ })
$nB = 0; $nT = 0; $files = 0
foreach ($w in $watches) {
  $paths = if ($w.mode -eq 'alla' -or $w.mode -eq 'tradera') { @(Get-ChildItem (Join-Path $DbDir $w.id) -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object FullName) } else { @(Join-Path $DbDir "$($w.id).json") }
  foreach ($p in $paths) {
    $d = Read-Db $p
    if (-not $d -or -not $d['rows'] -or -not $d['cols']) { continue }
    $files++
    if ($w.mode -eq 'tradera') { $nT += [Kombo]::AddTradera($d['rows'], (Get-Cols $d)) }
    else { $nB += [Kombo]::AddBlocket($d['rows'], (Get-Cols $d), [string]$d['imgBase']) }
  }
}
Write-Host ("Läste {0} filer: {1:N0} Blocket-annonser, {2:N0} sålda på Tradera ({3:N0} s)" -f $files, $nB, $nT, ((Get-Date) - $t0).TotalSeconds)
if ($nB + $nT -eq 0) { Write-Host 'Ingen data, hoppar över.'; return }

[Kombo]::Compute(10)
$termRows = [Kombo]::TermRows()
$deals = [Kombo]::Deals(500)
$day = [Kombo]::Today
$cols = @('k', 'bN', 'b10', 'b25', 'b50', 'b75', 'gN', 'g50', 's50', 'tN', 't25', 't50', 't75', 'tW', 'conf', 'cov', 'tL', 'gL', 'fair', 'src', 'ship')
$out = Join-Path $DbDir 'kombo'
$now = (Get-Date).ToUniversalTime().ToString('o')
Write-Db (Join-Path $out 'terms.json') ([ordered]@{ v = 1; day = $day; updatedAt = $now; sources = @('blocket', 'tradera'); cols = $cols; rows = $termRows }) -Fast

# ---------- trender: en rad per dag och ord ----------
$tcols = @('day', 'bN', 'b50', 'gN', 'g50', 'tN', 't50', 'tW')
for ($n = 0; $n -lt 32; $n++) {
  $file = Join-Path $out ('trend\{0:D2}.json' -f $n)
  $old = Read-Db $file
  $doc = New-Object 'System.Collections.Generic.Dictionary[string,object]'
  $doc['v'] = 1; $doc['cols'] = [string[]]$tcols; $doc['terms'] = [Kombo]::Trend($(if ($old) { $old['terms'] } else { $null }), $n, $KeepDays)
  Write-Db $file $doc -Fast
}

# ---------- flipp-listan och totaler ----------
$flipTerms = @($termRows | Where-Object { [int]$_[14] -gt 0 })
$totFile = Join-Path $out 'flip.json'
$oldFlip = Read-Db $totFile
$total = [System.Collections.ArrayList]@(); if ($oldFlip -and $oldFlip['total']) { foreach ($r in $oldFlip['total']) { if ([int]$r[0] -ne $day) { [void]$total.Add($r) } } }
[void]$total.Add(@($day, $nB, $nT, $flipTerms.Count, $deals.Count))
Write-Db $totFile ([ordered]@{
    v = 2; day = $day; updatedAt = $now; sources = @('blocket', 'tradera'); askToSold = [math]::Round([Kombo]::AskToSold, 3)
    cols = $cols; terms = $flipTerms
    dealCols = @('id', 't', 'p', 'img', 'loc', 'pubDay', 'km', 'k'); deals = $deals; urlBase = 'https://www.blocket.se/recommerce/forsale/item/'
    totalCols = @('day', 'blocket', 'tradera', 'flipTerms', 'deals'); total = @($total | Sort-Object { [int]$_[0] } | Select-Object -Last $KeepDays)
  })
$mb = (Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Kombo: {0:N0} ord, {1:N0} pålitliga att flippa, {2} billiga annonser, {3:N1} MB, {4:N0} s" -f $termRows.Count, $flipTerms.Count, $deals.Count, $mb, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor Green
