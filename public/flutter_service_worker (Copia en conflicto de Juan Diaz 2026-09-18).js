// Service worker "de retirada" del panel REWIND.
//
// Hasta la 1.4.235 la web se compilaba con el service worker de Flutter, que
// guarda la app en el navegador y la sigue sirviendo después de desplegar una
// versión nueva: se veía la versión antigua hasta recargar un par de veces
// (2026-09-18). Desde la 1.4.236 la web se compila con --pwa-strategy=none,
// que ya no registra ninguno, pero los navegadores que tenían el antiguo lo
// conservan. Cuando van a comprobar si hay uno nuevo reciben este: borra la
// caché que dejó el anterior, se da de baja él mismo y recarga las pestañas
// abiertas para que carguen la versión del servidor.
//
// tool/deploy lo copia sobre build/web/flutter_service_worker.js después de
// compilar: Flutter deja ese archivo vacío con --pwa-strategy=none.
self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
      await self.registration.unregister();
      const windows = await self.clients.matchAll({ type: 'window' });
      for (const w of windows) w.navigate(w.url);
    })(),
  );
});
