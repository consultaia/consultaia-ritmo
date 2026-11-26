/* Ritmo — service worker: funciona offline e mostra os avisos como notificação do sistema */
const CACHE='ritmo-v13';
const FILES=['./','./index.html','./manifest.json','./icon-192.png','./icon-512.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(FILES)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==CACHE&&x!=='ritmo-dados').map(x=>caches.delete(x)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  if(e.request.method!=='GET'||new URL(e.request.url).origin!==location.origin)return; /* Supabase nunca passa pelo cache */
  /* rede primeiro (pega atualizações), cache se estiver offline */
  e.respondWith(fetch(e.request).then(r=>{const c=r.clone();caches.open(CACHE).then(x=>x.put(e.request,c));return r}).catch(()=>caches.match(e.request).then(r=>r||caches.match('./index.html'))));
});
/* Push sem conteúdo: o servidor só acorda o aparelho; o texto do lembrete vem da lista guardada pelo app. */
const pad=n=>String(n).padStart(2,'0');
const dsl=d=>d.getFullYear()+'-'+pad(d.getMonth()+1)+'-'+pad(d.getDate());
const pdt=(s,min)=>{const[a,b,c]=s.split('-').map(Number);return new Date(a,b-1,c,0,min||0)};
function devidos(lista,vistos,now){
  const hoje=dsl(now),out=[];
  lista.forEach(r=>{
    let occ=null;
    if(!r.rep)occ=pdt(r.date,r.time);
    else if(r.date<=hoje){const o=pdt(r.date,0);if(r.rep==='dia'||(r.rep==='semana'&&o.getDay()===now.getDay())||(r.rep==='mes'&&o.getDate()===now.getDate()))occ=pdt(hoje,r.time)}
    if(!occ)return;
    const dif=now-occ,k=r.id+'|'+dsl(occ);
    if(dif>=-90000&&dif<=30*60000&&!vistos.includes(k))out.push({r,k});
  });
  return out;
}
async function aoPush(){
  const c=await caches.open('ritmo-dados');
  const ler=async(n,d)=>{try{const x=await c.match(n);return x?await x.json():d}catch(e){return d}};
  const lista=await ler('avisos.json',[]),vistos=await ler('vistos.json',[]),dev=devidos(lista,vistos,new Date());
  if(!dev.length)return self.registration.showNotification('Ritmo',{body:'⏰ Você tem um lembrete agora. Toque para ver.',icon:'icon-192.png',badge:'icon-192.png',tag:'rem-geral'});
  await c.put('vistos.json',new Response(JSON.stringify(vistos.concat(dev.map(x=>x.k)).slice(-200))));
  await Promise.all(dev.map(({r})=>self.registration.showNotification('Ritmo',{body:'⏰ '+r.t,icon:'icon-192.png',badge:'icon-192.png',vibrate:[200,100,200],tag:'rem-'+r.id})));
}
self.addEventListener('push',e=>e.waitUntil(aoPush()));
self.addEventListener('notificationclick',e=>{e.notification.close();
  e.waitUntil(self.clients.matchAll({type:'window'}).then(l=>l.length?l[0].focus():self.clients.openWindow('./')))});
