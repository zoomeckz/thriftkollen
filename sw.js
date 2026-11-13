// Thriftkollen service worker: appen startar direkt och visar senaste datan även med dålig täckning i butiken.
//  - Själva appen (HTML): nätet först, sparad kopia om nätet inte svarar. Nya versioner kommer alltså direkt.
//  - Databasens filer (raw.githubusercontent.com): sparad kopia direkt, och en ny hämtas i bakgrunden till nästa gång.
//    Undantag: små filer som säger hur färsk datan är (index.json, fynd.json) hämtas alltid från nätet först.
//  - Typsnitt och diagrambibliotek: sparad kopia (ändras aldrig).
//  - GitHub API, Claude och annonsbilder går alltid direkt till nätet och sparas inte.
const SHELL = 'tk-shell-v1', DATA = 'tk-data-v1', STATIC = 'tk-static-v1';
const SHELL_FILES = ['./', 'index.html', 'statistik.html', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png', 'icon-180.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(SHELL_FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => ![SHELL, DATA, STATIC].includes(k)).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

async function networkFirst(req, cacheName) {
  const cache = await caches.open(cacheName);
  try {
    const res = await fetch(req);
    if (res.ok) cache.put(req, res.clone());
    return res;
  } catch (err) {
    const hit = await cache.match(req, { ignoreSearch: true });
    if (hit) return hit;
    throw err;
  }
}
async function staleWhileRevalidate(req, cacheName, event) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req, { ignoreSearch: true });
  const update = fetch(req).then(res => { if (res.ok) cache.put(req, res.clone()); return res; });
  if (hit) { event.waitUntil(update.catch(() => {})); return hit; }
  return update;
}
async function cacheFirst(req, cacheName) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (res.ok || res.type === 'opaque') cache.put(req, res.clone());
  return res;
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin === location.origin) {
    if (req.mode === 'navigate' || url.pathname.endsWith('.html') || url.pathname.endsWith('/')) { e.respondWith(networkFirst(req, SHELL)); return; }
    if (/\.(png|webmanifest)$/.test(url.pathname)) { e.respondWith(cacheFirst(req, SHELL)); return; }
    return;   // lokal förhandsvisning (dbdata/) och allt annat: direkt till nätet
  }
  if (url.hostname === 'raw.githubusercontent.com') {
    if (/\/(index|fynd)\.json$/.test(url.pathname)) { e.respondWith(networkFirst(req, DATA)); return; }
    e.respondWith(staleWhileRevalidate(req, DATA, e)); return;
  }
  if (/^(fonts\.googleapis\.com|fonts\.gstatic\.com|cdn\.jsdelivr\.net)$/.test(url.hostname)) { e.respondWith(cacheFirst(req, STATIC)); return; }
});
