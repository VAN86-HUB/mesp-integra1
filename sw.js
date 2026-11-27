// Service worker MongongoWay : l'app s'ouvre même avec une connexion faible.
const VERSION = 'mongongo-v32';
const COQUILLE = [
  './', './index.html', './style.css', './app.js', './manifest.json',
  './icon-192.png', './icon-512.png', './fond.jpg'
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(COQUILLE)));
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((cles) =>
      Promise.all(cles.filter((k) => k !== VERSION && k !== 'mongongo-hors-ligne').map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Fichiers de l'app : réseau d'abord, sinon la copie en cache.
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== self.location.origin) return;
  // Toujours vérifier auprès du serveur s'il y a une nouvelle version (sans attendre le cache du navigateur)
  const frais = e.request.mode === 'navigate'
    ? fetch(e.request.url, { cache: 'no-cache', credentials: 'same-origin' })
    : fetch(new Request(e.request, { cache: 'no-cache' }));
  e.respondWith(
    frais
      .then((rep) => {
        const copie = rep.clone();
        caches.open(VERSION).then((c) => c.put(e.request, copie));
        return rep;
      })
      .catch(() => caches.match(e.request).then((r) => r || caches.match('./index.html')))
  );
});

// Notifications de l'administrateur (nouvelles demandes à valider)
self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { corps: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.titre || 'MongongoWay', {
    body: d.corps || 'Une demande attend votre validation.',
    icon: 'icon-192.png', badge: 'icon-192.png', tag: d.tag || 'mongongo', renotify: true,
    vibrate: [200, 100, 200], requireInteraction: d.tag === 'demandes-admin' || d.tag === 'direct', data: { lien: d.lien || '#/admin' }
  }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const cible = new URL('./' + (e.notification.data && e.notification.data.lien || '#/admin'), self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((fen) => {
    const f = fen.find((c) => c.url.startsWith(self.registration.scope));
    if (f) return f.focus().then(() => f.navigate ? f.navigate(cible) : null).catch(() => self.clients.openWindow(cible));
    return self.clients.openWindow(cible);
  }));
});
