// ==============================================================================
// NusaPixel - Service Worker (Step 14: PWA App Shell Cache)
// Versi cache bernomor: ubah versi saat merilis pembaruan shell
// ==============================================================================

const CACHE_NAME = 'nusapixel-shell-v16';

// Aset app shell yang di-cache saat instalasi
const APP_SHELL = [
  './',
  './index.html',
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
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => {
      // addAll dengan toleransi kegagalan CDN opsional
      return Promise.allSettled(
        APP_SHELL.map(url => cache.add(url).catch(err => console.warn('[SW] Cache miss:', url, err)))
      );
    }).then(() => self.skipWaiting())
  );
});

// Aktivasi: bersihkan versi cache lama
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
// - API Supabase: NETWORK ONLY (tidak pernah di-cache untuk menjamin integritas realtime & RPC)
// - Tile Peta OpenStreetMap: NETWORK ONLY (mematuhi OSM Tile Policy - tidak melakukan caching massal)
// - App Shell & Aset Statis: Cache First / Stale While Revalidate
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
        // Saat offline, kembalikan response kosong agar peta tidak melempar error mentah
        return new Response('', { status: 204, statusText: 'Offline Tile' });
      })
    );
    return;
  }

  // 3. Permintaan Navigasi HTML: Cache First dengan Network Fallback
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req).catch(() => {
        return caches.match('./index.html') || caches.match('./');
      })
    );
    return;
  }

  // 4. Aset App Shell lainnya (CSS, JS, Font, Ikon)
  event.respondWith(
    caches.match(req).then(cachedResponse => {
      if (cachedResponse) {
        // Perbarui di latar belakang jika online (stale-while-revalidate)
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

// Komunikasi dengan klien (misal: skipWaiting manual)
self.addEventListener('message', event => {
  if (event.data && event.data.action === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
