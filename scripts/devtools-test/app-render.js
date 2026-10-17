// Cases for «Приложение» and «Рендеринг»: storage of every kind, a service worker, and a
// probe that shows what the page sees (media features, time zone, locale, position).
(() => {
  const frame = window === top ? 'main' : 'frame';
  localStorage.setItem(frame + ':local', JSON.stringify({ at: location.origin, n: 1 }));
  localStorage.setItem(frame + ':long', 'x'.repeat(2000));
  sessionStorage.setItem(frame + ':session', 'session value');
  document.cookie = frame + '_cookie=1; path=/; max-age=86400';
  document.cookie = frame + '_lax=2; path=/; SameSite=Lax';
  if (window !== top) return;

  // IndexedDB: 250 records for paging, plus an out-of-line-key store.
  const open = indexedDB.open('ub-test-db', 1);
  open.onupgradeneeded = () => {
    const db = open.result;
    const items = db.createObjectStore('items', { keyPath: 'id', autoIncrement: true });
    items.createIndex('by-name', 'name');
    db.createObjectStore('kv');
  };
  open.onsuccess = () => {
    const db = open.result;
    const tx = db.transaction(['items', 'kv'], 'readwrite');
    const items = tx.objectStore('items');
    items.count().onsuccess = (e) => {
      if (e.target.result) return;
      for (let i = 0; i < 250; i++) items.add({ name: 'item ' + i, tags: ['a', 'b'], at: new Date(2026, 0, 1 + i) });
      tx.objectStore('kv').put({ nested: { deep: true } }, 'config');
      tx.objectStore('kv').put(new Uint8Array(16), ['array', 'key']);
    };
    tx.oncomplete = () => db.close();
  };

  if (window.caches) caches.open('ub-test-cache').then((c) => c.addAll(['/', '/frame.html', '/app-render.js'])).catch(() => {});
  if (navigator.serviceWorker) navigator.serviceWorker.register('/sw.js').catch((e) => console.warn('sw:', e.message));

  // Probe, refreshed every second so live overrides show up.
  const probe = document.getElementById('render-probe');
  const show = () => {
    const mq = (q) => q + ' → ' + matchMedia(q).matches;
    probe.textContent = [
      'JavaScript выполняется',
      mq('(prefers-reduced-motion: reduce)'),
      mq('(prefers-contrast: more)'),
      mq('print'),
      mq('(prefers-color-scheme: dark)'),
      'new Date(): ' + new Date().toString(),
      'new Date(2026, 6, 1, 12): ' + new Date(2026, 6, 1, 12).toISOString(),
      'getTimezoneOffset: ' + new Date().getTimezoneOffset(),
      'Intl timeZone: ' + Intl.DateTimeFormat().resolvedOptions().timeZone,
      'Intl locale: ' + Intl.DateTimeFormat().resolvedOptions().locale + ' · ' + (1234567.89).toLocaleString(),
      'navigator.language(s): ' + navigator.language + ' ' + JSON.stringify(navigator.languages),
      'innerWidth × innerHeight: ' + innerWidth + ' × ' + innerHeight,
      'userAgent: ' + navigator.userAgent,
    ].join('\n');
  };
  show();
  setInterval(show, 1000);
  document.getElementById('geo').onclick = () => navigator.geolocation.getCurrentPosition(
    (p) => { document.getElementById('geo-out').textContent = p.coords.latitude + ', ' + p.coords.longitude; },
    (e) => { document.getElementById('geo-out').textContent = 'ошибка ' + e.code + ': ' + e.message; },
  );
})();
