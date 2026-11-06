/* MESP Integra — service worker : permet d'ouvrir l'application sans réseau.
   - Page et fichiers de l'application : réseau d'abord (toujours la dernière version), copie locale en secours.
   - Bibliothèques externes (supabase-js, pako) : copie locale d'abord, mise à jour en arrière-plan.
   - Les appels à Supabase (données, authentification, stockage) ne sont JAMAIS interceptés ni mis en cache ici. */
var CACHE = "mesp-v94";
var SHELL = ["./", "index.html", "config.js", "manifest.webmanifest", "icon-192.png", "icon-512.png", "apple-touch-icon.png"];
var CDN = ["cdn.jsdelivr.net", "cdnjs.cloudflare.com"];
/* Bibliothèques chargées par la page : préchargées à l'installation pour que l'application s'ouvre dès la première coupure de réseau. */
var LIBS = ["https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js", "https://cdnjs.cloudflare.com/ajax/libs/pako/2.1.0/pako.min.js"];

self.addEventListener("install", function(e){
  e.waitUntil(caches.open(CACHE).then(function(c){
    return Promise.all(SHELL.map(function(u){ return c.add(new Request(u, {cache:"reload"})).catch(function(){}) })
      .concat(LIBS.map(function(u){ return fetch(new Request(u, {mode:"no-cors"})).then(function(r){ return c.put(new Request(u), r) }).catch(function(){}) })));
  }).then(function(){ return self.skipWaiting() }));
});
self.addEventListener("activate", function(e){
  e.waitUntil(caches.keys().then(function(ks){ return Promise.all(ks.filter(function(k){ return k!==CACHE }).map(function(k){ return caches.delete(k) })) }).then(function(){ return self.clients.claim() }));
});
self.addEventListener("fetch", function(e){
  var req = e.request; if(req.method!=="GET") return;
  var u = new URL(req.url);
  if(u.origin===self.location.origin){
    if(u.pathname.slice(-6)==="/sw.js") return;
    e.respondWith(fetch(req).then(function(r){
      if(r && r.ok){ var cp = r.clone(); caches.open(CACHE).then(function(c){ c.put(req, cp) }) }
      return r;
    }).catch(function(){
      return caches.match(req, {ignoreSearch:true}).then(function(m){ return m || (req.mode==="navigate" ? caches.match("index.html") || caches.match("./") : Response.error()) });
    }));
    return;
  }
  if(CDN.indexOf(u.hostname)>=0){
    e.respondWith(caches.match(req).then(function(m){
      var net = fetch(req).then(function(r){ if(r && (r.ok || r.type==="opaque")){ var cp = r.clone(); caches.open(CACHE).then(function(c){ c.put(req, cp) }) } return r }).catch(function(){ return m });
      return m || net;
    }));
  }
});
