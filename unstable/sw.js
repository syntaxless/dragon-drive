// Unstable preview: its own cache, and it only clears its own old caches so the live app's cache is left alone.
const C="dragondrive-unstable-82b996d";const ASSETS=["./","index.html","manifest.webmanifest","icon.svg","apple-touch-icon.png","icon-192.png","icon-512.png","vendor/maplibre/maplibre-gl.js","vendor/maplibre/maplibre-gl.css"];
self.addEventListener("install",e=>{e.waitUntil(caches.open(C).then(c=>c.addAll(ASSETS)));self.skipWaiting()});
self.addEventListener("activate",e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x.startsWith("dragondrive-unstable-82b996d")&&x!==C).map(x=>caches.delete(x)))));self.clients.claim()});
self.addEventListener("fetch",e=>{if(e.request.method!=="GET")return;e.respondWith(fetch(e.request).then(r=>{const cp=r.clone();if(new URL(e.request.url).origin===location.origin)caches.open(C).then(c=>c.put(e.request,cp));return r}).catch(()=>caches.match(e.request)))});
