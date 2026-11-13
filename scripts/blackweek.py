#!/usr/bin/env python3
"""Black Week-skanner: nya varor som går att köpa i butik och sälja dyrare på Tradera.

Efterfrågan först, inte butikernas reor:
  1. Alla OANVÄNDA saker som sålts på Tradera senaste 30 dagarna (databasen från tradera.ps1).
  2. Varje försäljning kopplas till en exakt produkt hos PriceRunner, via deras sitemap
     (namn och modellnummer måste stämma). Det ger en lista över produkter som bevisat säljs nya.
  3. För de produkterna läses PriceRunners produktsida: alla butikers pris just nu, med frakt och lager.
     Power, NetOnNet, Elgiganten, Jysk, Webhallen, Proshop ... alla butiker som PriceRunner jämför.
     Black Week-priser kommer med automatiskt när butikerna sänker.
  4. Vinst = försiktigt säljpris på Tradera (minst hälften av försäljningarna nådde det, 90 % säkert
     vid minst 10 sålda, annars den billigaste fjärdedelen) minus Tradera-avgift minus lägsta butikspris med frakt.

Hämtar bara det robots.txt tillåter (sitemap och produktsidor), långsamt, med ärlig User-Agent.
Bara Pythons standardbibliotek.

Användning:
  python scripts/blackweek.py --db dbdata                 # allt (sitemaps + produktsidor)
  python scripts/blackweek.py --db dbdata --cache DIR     # sitemaps sparas i DIR (en .txt per fil), bara saknade hämtas
  python scripts/blackweek.py --db dbdata --cache DIR --offline   # bara redan nedladdade sitemaps
Skriver <db>/blackweek/blackweek.json
"""
import argparse, collections, glob, gzip, io, json, math, os, re, sys, time, unicodedata, urllib.request, urllib.error

UA = 'thriftkollen/1.0 (+https://github.com/zoomeckz/thriftkollen)'
PR = 'https://www.pricerunner.se'
SITEMAP = PR + '/se/api/robots-public/public/v1/sitemap/SE/'
# Kategorier där nya saker brukar gå att sälja vidare (PriceRunners kategori-id). Alla id under 100 räknas också
# (mobiler, datorer, ljud, bild, spel, kameror, vitvaror ...).
CATS = {72, 52, 37, 613, 196, 165, 10083, 1244, 1258, 1260, 10028, 461, 1214, 129, 1156, 337, 10001, 1206, 1210, 1266,
        1196, 1264, 1322, 1222, 1228, 1312, 1342, 1198, 1286, 10068, 10003, 1226, 1204, 1216, 1218, 1220, 1288}

FOLD = str.maketrans({'å': 'aa', 'ä': 'ae', 'ö': 'oe', 'æ': 'ae', 'ø': 'oe', 'ü': 'u', 'é': 'e', 'è': 'e', 'á': 'a', 'à': 'a', '’': '', "'": ''})
TOK = re.compile(r'[a-z0-9]+')
UNIT = re.compile(r'^\d+(v|w|kw|gb|tb|mb|mm|cm|m|l|ml|kg|g|mah|hz|tum|st|pack|p)$')
STOP = set('''the and for with och med till av i pa paa en ett den det som fraan from priser pack st styck set kit
ny nytt nya new oanvaend oanvaent oanvaenda oeppnad oeppnat oeppnade inplastad inplastat foerseglad sealed boxed
original orginal aekta helt fint fin bra skick storlek size stl strl version edition gen generation model modell
svart vit vitt vita black white blue blaa red roed green groen grey gray graa rosa pink beige brun brown silver
gold guld navy orange yellow gul lila purple multi multicolour multicolor clear transparent
dam herr barn junior kids women men mens womens unisex ladies one'''.split())

def norm(s):
    s = (s or '').lower().translate(FOLD)
    s = unicodedata.normalize('NFKD', s)
    return ''.join(c for c in s if not unicodedata.combining(c))

def toks(s):
    out = []
    for t in TOK.findall(norm(s)):
        if t in STOP or (len(t) < 2 and not t.isdigit()): continue
        out.append(t)
    return out

def get(url, tries=4, wait=3.0):
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Language': 'sv-SE', 'Accept-Encoding': 'gzip'})
            with urllib.request.urlopen(req, timeout=90) as r:
                b = r.read()
                if r.headers.get('Content-Encoding') == 'gzip': b = gzip.decompress(b)
                return b.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            if e.code == 404: return None
            time.sleep(wait * (k + 1) * (10 if e.code == 429 else 1))
        except Exception:
            time.sleep(wait * (k + 1))
    return None

# ---------- 1. efterfrågan: oanvända sålda på Tradera ----------
def load_tradera(db, days):
    today = int(time.time() // 86400)
    rows = []
    for f in glob.glob(os.path.join(db, 'tradera', '*.json')):
        d = json.load(open(f, encoding='utf-8-sig'))
        if 'rows' not in d: continue
        C = {k: i for i, k in enumerate(d['cols'])}
        for r in d['rows']:
            if r[C['cond']] != 'Oanvänt' or r[C['p']] < 50: continue
            if today - int(r[C['end']] // 86400) > days: continue
            rows.append((int(r[C['id']]), r[C['t']], int(r[C['p']]), int(r[C['end']]), r[C['img']]))
    return rows

# ---------- 2. PriceRunners produkter (sitemap) ----------
def sitemap_files(cache):
    idx = get(SITEMAP + 'sitemap.xml')
    files = sorted(set(re.findall(r'sitemap\.(\d+(?:-\d+)?)\.xml', idx or '')))
    return [f for f in files if int(f.split('-')[0]) < 100 or int(f.split('-')[0]) in CATS]

def load_products(cache, download, vocab, delay):
    os.makedirs(cache, exist_ok=True)
    names = sitemap_files(cache) if download else sorted(os.path.basename(p)[8:-8] for p in glob.glob(os.path.join(cache, 'sitemap.*.xml.txt')))
    df = collections.Counter(); prods = []
    for i, f in enumerate(names):
        path = os.path.join(cache, f'sitemap.{f}.xml.txt')
        if not os.path.exists(path) and download:
            x = get(SITEMAP + f'sitemap.{f}.xml')
            if x is None: continue
            open(path, 'w', encoding='utf-8').write('\n'.join(u.replace(PR, '') for u in re.findall(r'<loc>(https://www\.pricerunner\.se/pl/[^<]+)</loc>', x)))
            time.sleep(delay)
        if not os.path.exists(path): continue
        for u in open(path, encoding='utf-8').read().split('\n'):
            m = re.match(r'/pl/(\d+)-(\d+)/([^/]+)/(.+?)-priser$', u)
            if not m: continue
            tk = toks(m.group(4).replace('-', ' '))
            if len(tk) < 3: continue                            # för allmänt namn (t.ex. "Julkalender 2026")
            for t in set(tk): df[t] += 1
            if any(t in vocab for t in tk): prods.append((u, m.group(3), tk))
        print(f'  sitemap {i + 1}/{len(names)} {f}: {len(prods)} relevanta produkter', file=sys.stderr)
    return prods, df

# ---------- 3. koppla försäljningar till produkter ----------
def match(rows, prods, df, max_df):
    anchors = collections.defaultdict(list)
    for pi, (u, cat, tk) in enumerate(prods):
        for t in set(tk):
            if df[t] <= max_df and len(t) >= 3: anchors[t].append(pi)
    hits = collections.defaultdict(list)
    for row in rows:
        tt = set(toks(row[1]))
        cand = set()
        for t in tt:
            if t in anchors and len(anchors[t]) < 3000: cand.update(anchors[t])
        best, bk = None, None
        for pi in cand:
            tk = set(prods[pi][2])
            common = tk & tt
            have = len(common) / len(tk)
            first = prods[pi][2][0]
            if first not in tt: continue                           # märket (första ordet) måste finnas med
            nums = [t for t in tk if any(c.isdigit() for c in t)]
            if any(t not in tt for t in nums): continue            # alla siffror och modellnummer måste stämma
            if any(df[t] <= 30 and t not in tt for t in tk): continue   # ovanliga ord (t.ex. ditto) måste också finnas
            model = any(df[t] <= 60 and len(t) >= 4 and not UNIT.match(t) for t in nums)   # sällsynt modellnummer (t.ex. 75397, ddf484z)
            if have < (0.5 if model else 0.85): continue
            if not any(df[t] <= max_df for t in common): continue
            key = (model, have, len(common), -len(tk), -pi)
            if bk is None or key > bk: best, bk = pi, key
        if best is not None: hits[best].append(row)
    return hits

def q(s, x): return s[int(math.floor((len(s) - 1) * x))]
def lcb_median(s, alpha=0.10):
    n = len(s); r = 0
    if n > 200: r = int(math.floor(n / 2 - 1.2816 * math.sqrt(n) / 2))
    else:
        pmf, cdf = 0.5 ** n, 0.0
        for j in range(n):
            cdf += pmf
            if cdf > alpha: break
            r = j + 1; pmf = pmf * (n - j) / (j + 1)
    return s[max(0, min(n - 1, r - 1))]

def resale(prices):
    s = sorted(prices)
    return lcb_median(s) if len(s) >= 10 else q(s, 0.25)

def fee(p): return min(200, max(3, p * 0.10))

# ---------- 4. butikspriser från produktsidan ----------
def offers(url):
    h = get(PR + url)
    if not h: return None
    m = re.search(r'<script[^>]*id="initial_payload"[^>]*>', h)
    if not m: return None
    try: d = json.loads(h[m.end():h.find('</script>', m.end())])
    except Exception: return None
    t = json.dumps(d)
    i = t.find('"offers": [')
    if i < 0: return None
    arr, depth, j = None, 0, i + len('"offers": ')
    for k in range(j, len(t)):
        c = t[k]
        if c == '[': depth += 1
        elif c == ']':
            depth -= 1
            if depth == 0: arr = json.loads(t[j:k + 1]); break
    merchants = {}
    mi = t.find('"merchants": {')
    if mi >= 0:
        for mm in re.finditer(r'"(\d+)": \{"id": "\d+", "url": "[^"]*", "name": "([^"]+)"', t[mi:mi + 400000]): merchants[mm.group(1)] = mm.group(2)
    out = []
    for o in arr or []:
        try:
            p = float(o['price']['amount']); ship = float((o.get('shippingCost') or {}).get('amount') or 0)
        except Exception: continue
        out.append({'store': merchants.get(str(o.get('merchantId')), str(o.get('merchantId'))), 'p': round(p), 'ship': round(ship),
                    'stock': o.get('stockStatus'), 'campaign': bool(o.get('campaignPrice'))})
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default='dbdata'); ap.add_argument('--cache', default=None); ap.add_argument('--offline', action='store_true')
    ap.add_argument('--days', type=int, default=30); ap.add_argument('--min-sold', type=int, default=2)
    ap.add_argument('--max-pages', type=int, default=400); ap.add_argument('--delay', type=float, default=2.5)
    ap.add_argument('--max-df', type=int, default=400)
    a = ap.parse_args()
    t0 = time.time()
    rows = load_tradera(a.db, a.days)
    vocab = collections.Counter(t for r in rows for t in set(toks(r[1])))
    print(f'Tradera: {len(rows)} oanvända sålda, {len(vocab)} ord', file=sys.stderr)
    cache = a.cache or os.path.join(a.db, 'blackweek', 'sitemaps')
    prods, df = load_products(cache, not a.offline, vocab, 8.0)
    hits = match(rows, prods, df, a.max_df)
    cands = []
    for pi, rs in hits.items():
        if len(set(r[0] for r in rs)) < a.min_sold: continue
        ps = sorted(r[2] for r in rs)
        rv = resale(ps)
        if rv < 150: continue
        cands.append((pi, rs, ps, rv))
    cands.sort(key=lambda x: -x[3] * min(len(x[2]), 20))
    print(f'Kopplade: {sum(len(v) for v in hits.values())} försäljningar till {len(hits)} produkter, {len(cands)} med minst {a.min_sold} sålda', file=sys.stderr)
    items = []
    for k, (pi, rs, ps, rv) in enumerate(cands[:a.max_pages]):
        u, cat, tk = prods[pi]
        of = offers(u); time.sleep(a.delay)
        if not of: continue
        stock = [o for o in of if o['stock'] in ('IN_STOCK', 'LIMITED_STOCK', None)] or of
        best = min(stock, key=lambda o: o['p'] + o['ship'])
        buy = best['p'] + best['ship']
        med_store = q(sorted(o['p'] + o['ship'] for o in of), .5)
        if not (0.33 <= q(ps, .5) / max(1, med_store) <= 3): continue   # olika produkter under samma namn
        net = rv - fee(rv)
        name = re.sub(r'-', ' ', re.match(r'/pl/\d+-\d+/[^/]+/(.+?)-priser$', u).group(1))
        items.append({'name': name, 'u': u, 'cat': cat.replace('-', ' '), 'sold': {'n': len(ps), 'med': q(ps, .5), 'p25': q(ps, .25), 'p75': q(ps, .75), 'resale': rv},
                      'buy': {'p': buy, 'store': best['store'], 'stock': best['stock'], 'stores': len(of), 'campaign': best['campaign'],
                              'median': med_store},
                      'net': round(net), 'profit': round(net - buy), 'mult': round(net / buy, 2) if buy else None,
                      'ex': [[r[0], r[1][:80], r[2], r[4]] for r in sorted(rs, key=lambda r: -r[3])[:4]]})
        if (k + 1) % 25 == 0: print(f'  produktsidor {k + 1}/{min(len(cands), a.max_pages)}', file=sys.stderr)
    items.sort(key=lambda x: -x['profit'])
    out = {'v': 1, 'updatedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'days': a.days, 'traderaRows': len(rows),
           'products': len(prods), 'matchedProducts': len(hits), 'candidates': len(cands), 'checked': len(items),
           'traderaImg': 'https://img.tradera.net/250-square/', 'traderaUrl': 'https://www.tradera.com/item/', 'prUrl': PR, 'items': items}
    os.makedirs(os.path.join(a.db, 'blackweek'), exist_ok=True)
    json.dump(out, open(os.path.join(a.db, 'blackweek', 'blackweek.json'), 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))
    good = [x for x in items if x['profit'] >= 100]
    print(f'Black Week: {len(items)} produkter kollade, {len(good)} med minst 100 kr vinst, {time.time() - t0:.0f} s', file=sys.stderr)

if __name__ == '__main__':
    main()
