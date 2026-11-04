// ==============================================================================
// NusaPixel - Service Worker (Step 14: PWA App Shell Cache)
// Versi cache bernomor: ubah versi saat merilis pembaruan shell
// ==============================================================================

const CACHE_NAME = 'nusapixel-shell-v27';

// Aset app shell yang di-cache saat instalasi
const APP_SHELL = [
  './',
  './index.html',
  './game.html',
  './beranda.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
  'https://fonts.googleapis.com/css2?family=Nunito:wght@700;800;900&display=swap'
];

// Instalasi: unduh dan simpan aset app shell ke cache
self.addEventListener('install', event => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => {
      return Promise.allSettled(
        APP_SHELL.map(url => cache.add(url).catch(err => console.warn('[SW] Cache miss:', url, err)))
      );
    })
  );
});

// Aktivasi: bersihkan versi cache lama seketika dan klaim semua klien
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => {
      return Promise.all(
        keys.map(key => {
          if (key !== CACHE_NAME) {
            return caches.delete(key);
          }
        })
      );
    }).then(() => self.clients.claim())
  );
});

// Strategi Pengambilan (Fetch):
// - API Supabase: NETWORK ONLY
// - Tile Peta OpenStreetMap: NETWORK ONLY
// - Dokumen HTML (Game, Beranda, dll): NETWORK FIRST (Selalu ambil kode terbaru dari server!)
// - Aset Statis (CSS, Ikon, Library): Stale-While-Revalidate
self.addEventListener('fetch', event => {
  const req = event.request;
  const url = new URL(req.url);

  // 1. Jangan cache API Supabase (database, auth, realtime)
  if (url.hostname.includes('supabase.co')) {
    return; // biarkan browser menangani secara langsung (network only)
  }

  // 2. Tile OpenStreetMap: jangan cache massal (kebijakan OSM), fallback jika offline
  if (url.hostname.includes('tile.openstreetmap.org')) {
    event.respondWith(
      fetch(req).catch(() => {
        return new Response('', { status: 204, statusText: 'Offline Tile' });
      })
    );
    return;
  }

  // 3. Dokumen HTML: NETWORK FIRST (menjamin pembaruan game langsung aktif tanpa nyangkut di cache)
  const isHtml = req.mode === 'navigate' ||
                 (req.headers.get('accept') && req.headers.get('accept').includes('text/html')) ||
                 url.pathname.endsWith('.html') ||
                 url.pathname === '/game' ||
                 url.pathname === '/play';

  if (isHtml) {
    event.respondWith(
      fetch(req)
        .then(res => {
          if (res && res.status === 200) {
            const copy = res.clone();
            caches.open(CACHE_NAME).then(c => c.put(req, copy));
          }
          return res;
        })
        .catch(async () => {
          return (await caches.match(req)) || (await caches.match('./game.html')) || (await caches.match('./index.html'));
        })
    );
    return;
  }

  // 4. Aset App Shell lainnya (CSS, JS Library, Font, Ikon)
  event.respondWith(
    caches.match(req).then(cachedResponse => {
      if (cachedResponse) {
        fetch(req).then(networkResponse => {
          if (networkResponse && networkResponse.status === 200) {
            caches.open(CACHE_NAME).then(cache => cache.put(req, networkResponse));
          }
        }).catch(() => {});
        return cachedResponse;
      }
      return fetch(req);
    })
  );
});

// Komunikasi dengan klien (skipWaiting instan saat ada update)
self.addEventListener('message', event => {
  if (event.data && (event.data.action === 'SKIP_WAITING' || event.data.type === 'SKIP_WAITING')) {
    self.skipWaiting();
  }
});
