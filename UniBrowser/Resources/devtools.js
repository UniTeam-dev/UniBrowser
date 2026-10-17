// UniBrowser developer tools: the page script.
// Runs at document start in every frame, in the page world (DevToolsSession.script).
// Hooks collect entries into ring buffers; nothing is posted until the panel calls
// __ubDevtools.attach(). Contract for panel modules: docs/devtools-architecture.md.
(() => {
  'use strict';
  if (window.__ubDevtools) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ubDevtools;
  if (!handler) return;
  const postNative = (message) => handler.postMessage(message);

  const ub = {};
  ub.frame = Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
  ub.attached = false;
  const modules = new Map(); // name -> object of functions (+ optional attach/detach)
  const rings = [];          // every ring, drained in order on attach

  // #region core

  /// Posts to native, only while the panel is attached.
  ub.send = (type, payload = {}) => {
    if (ub.attached) postNative({ ...payload, type, frame: ub.frame });
  };

  /// A ring buffer of `max` entries of one message type: buffered while detached,
  /// streamed while attached. attach() returns the buffered ones as messages.
  ub.ring = (type, max) => {
    const items = [];
    const ring = {
      push(payload) {
        if (ub.attached) return ub.send(type, payload);
        items.push(payload);
        if (items.length > max) items.shift();
      },
      drain: () => items.splice(0).map((payload) => ({ ...payload, type, frame: ub.frame })),
    };
    rings.push(ring);
    return ring;
  };

  // Handle registry: lets native refer to page objects (expand a value, select a node).
  // ponytail: handles hold their objects until the page unloads; add release() if pages
  // that log in a loop for hours run out of memory.
  const objects = new Map();
  const handles = new WeakMap();
  let nextHandle = 1;
  ub.handle = (object) => {
    let id = handles.get(object);
    if (!id) {
      id = nextHandle++;
      handles.set(object, id);
      objects.set(id, object);
    }
    return id;
  };
  ub.object = (handle) => objects.get(handle);

  const MAX_KEYS = 100;
  const safe = (fn, fallback) => { try { return fn(); } catch { return fallback; } };
  const nodeText = (node) => {
    if (node.nodeType === Node.TEXT_NODE) return '#text "' + node.textContent.slice(0, 50) + '"';
    if (node.nodeType === Node.DOCUMENT_NODE) return '#document';
    if (node.nodeType !== Node.ELEMENT_NODE) return node.nodeName;
    let text = '<' + node.localName;
    if (node.id) text += '#' + node.id;
    if (typeof node.className === 'string' && node.className.trim()) text += '.' + node.className.trim().split(/\s+/).join('.');
    return text + '>';
  };

  /// The keys and values one level down, for previews and for expanding a handle.
  const entriesOf = (value) => {
    if (value instanceof Map) return [...value].slice(0, MAX_KEYS + 1).map(([k, v], i) => [String(i), { key: k, value: v }]);
    if (value instanceof Set) return [...value].slice(0, MAX_KEYS + 1).map((v, i) => [String(i), v]);
    const keys = safe(() => Object.keys(value), []);
    if (value instanceof Error) keys.unshift('message', 'stack');
    return keys.slice(0, MAX_KEYS + 1).map((key) => [key, safe(() => value[key], undefined)]);
  };

  /// JSON-safe preview: {type, text, handle?, entries?: [{key, value}], more?}.
  /// Objects are expanded `depth` levels; deeper ones keep only a handle.
  ub.preview = (value, depth = 3) => {
    const type = value === null ? 'null' : typeof value;
    switch (type) {
      case 'null': case 'undefined': return { type, text: String(value) };
      case 'string': return { type, text: value };
      case 'number': case 'boolean': return { type, text: String(value) };
      case 'bigint': return { type, text: value + 'n' };
      case 'symbol': return { type, text: value.toString() };
      case 'function': return { type, text: 'ƒ ' + (value.name || '') + '()', handle: ub.handle(value) };
    }
    const handle = ub.handle(value);
    if (safe(() => value instanceof Node, false)) return { type: 'node', text: nodeText(value), handle };
    let text;
    if (value instanceof Error) text = value.name + ': ' + value.message;
    else if (Array.isArray(value)) text = 'Array(' + value.length + ')';
    else if (value instanceof Map || value instanceof Set) text = value.constructor.name + '(' + value.size + ')';
    else text = safe(() => value.constructor && value.constructor.name, '') || 'Object';
    const result = { type: value instanceof Error ? 'error' : Array.isArray(value) ? 'array' : 'object', text, handle };
    if (depth > 0) {
      const entries = entriesOf(value);
      result.more = entries.length > MAX_KEYS;
      result.entries = entries.slice(0, MAX_KEYS).map(([key, v]) => ({ key, value: ub.preview(v, depth - 1) }));
    }
    return result;
  };

  /// Registers a panel module. `factory(ub)` returns its functions; native calls them as
  /// "<name>.<function>" with one JSON-able argument. Optional attach()/detach() hooks
  /// run when the panel opens and closes.
  ub.module = (name, factory) => { modules.set(name, factory(ub)); };

  ub.module('core', () => ({
    /// The next level of a previewed object.
    expand: ({ handle }) => {
      const value = ub.object(handle);
      if (value === undefined || value === null || typeof value !== 'object' && typeof value !== 'function') return [];
      return entriesOf(value).slice(0, MAX_KEYS).map(([key, v]) => ({ key, value: ub.preview(v, 0) }));
    },
  }));

  Object.defineProperty(window, '__ubDevtools', {
    value: Object.freeze({
      /// Native RPC: callAsyncJavaScript("return await __ubDevtools.call(name, args)").
      call: async (name, args) => {
        const dot = name.indexOf('.');
        const module = modules.get(name.slice(0, dot));
        const fn = module && module[name.slice(dot + 1)];
        if (typeof fn !== 'function') throw new Error('devtools: no function ' + name);
        return await fn.call(module, args || {});
      },
      /// Starts streaming and returns everything buffered so far, oldest first.
      attach: () => {
        const messages = rings.flatMap((ring) => ring.drain());
        ub.attached = true;
        for (const module of modules.values()) safe(() => module.attach && module.attach(), null);
        return messages;
      },
      detach: () => {
        ub.attached = false;
        for (const module of modules.values()) safe(() => module.detach && module.detach(), null);
      },
    }),
  });

  // hello is the one message sent while detached: native needs every frame's WKFrameInfo
  // to attach it when the panel opens.
  postNative({ type: 'hello', frame: ub.frame, url: location.href, isTop: window === top });

  // #endregion core

  // #region frames
  // Spec «Frames»: a child frame tells its parent its id; the parent finds the <iframe>
  // whose contentWindow posted it. Works cross-origin.
  const frameLinks = ub.ring('frameLink', 500);
  if (window !== top) safe(() => parent.postMessage({ __ubFrame: ub.frame }, '*'), null);
  window.addEventListener('message', (event) => {
    const child = event.data && event.data.__ubFrame;
    if (typeof child !== 'string') return;
    event.stopImmediatePropagation();
    // ponytail: iframes inside shadow roots are not found; walk shadow roots when Elements needs them.
    const iframe = [...document.querySelectorAll('iframe, frame')].find((el) => el.contentWindow === event.source);
    if (iframe) frameLinks.push({ child, element: ub.handle(iframe) });
  }, true);
  // #endregion frames

  // #region console
  // Foundation stub: plain log levels only. The Console panel owns this region.
  const consoleEntries = ub.ring('console', 500);
  for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
    const original = console[level];
    if (typeof original !== 'function') continue;
    console[level] = function (...args) {
      safe(() => consoleEntries.push({ level, args: args.map((arg) => ub.preview(arg)), time: Date.now() }), null);
      return original.apply(this, args);
    };
  }
  // #endregion console

  // #region elements
  // #endregion elements

  // #region sources
  // #endregion sources

  // #region network
  // Spec «Сеть». fetch/XMLHttpRequest/WebSocket wrappers and resource timing entries.
  // Every 'network' message is an update {id, url, ...fields}; native merges them by
  // frame + id. Bodies and WebSocket frames are captured only while attached.
  // Throttling, blocking and «Отключить кэш» come from native via network.configure
  // while the panel is open; detach() turns them off.
  {
    const ring = ub.ring('network', 500);
    const MAX_BODY = 1000000;
    const defaults = { blocked: [], offline: false, latency: 0, down: 0, up: 0, noStore: false };
    const config = { ...defaults };
    let nextId = 1;
    const now = () => performance.timeOrigin + performance.now();
    const absolute = (url) => safe(() => new URL(url, location.href).href, String(url));
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));
    const throttled = () => config.latency > 0 || config.down > 0;
    /// When a response of `down` bytes to a request of `up` bytes sent at `start` may arrive
    /// (bandwidths in bytes per ms).
    const arrival = (start, down, up) => start + config.latency
      + (config.up > 0 ? up / config.up : 0) + (config.down > 0 ? down / config.down : 0);
    /// Patterns with `*`, matched anywhere in the URL, like the tab's content rule list.
    const globRegex = (pattern) => new RegExp(pattern.split('*')
      .map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*'), 'i');
    const blockReason = (url) => config.offline ? 'Офлайн'
      : config.blocked.some((re) => re.test(url)) ? 'Заблокировано' : null;

    /// The page's call site: the first stack line below our wrapper.
    const initiator = () => {
      const lines = (new Error().stack || '').split('\n').slice(2).filter((line) => /:\d+/.test(line) && !line.includes('[native code]'));
      return { initiator: (lines[0] || '').replace(/^[^@]*@/, '').replace(/:\d+$/, ''), stack: lines.slice(0, 20).join('\n') };
    };

    const size = (body) => body == null ? 0 : typeof body === 'string' ? new Blob([body]).size
      : body instanceof Blob ? body.size : body.byteLength !== undefined ? body.byteLength : String(body).length;
    const isForm = (body) => typeof FormData !== 'undefined' && body instanceof FormData;
    /// A request body as text: strings and forms as they are (forms url-encoded), binary as its size.
    const bodyText = (body) => {
      if (body == null) return null;
      if (typeof body === 'string') return body.slice(0, MAX_BODY);
      if (body instanceof URLSearchParams) return body.toString();
      if (isForm(body)) {
        return [...body].map(([key, value]) => encodeURIComponent(key) + '=' + encodeURIComponent(
          typeof value === 'string' ? value : '(файл ' + value.name + ', ' + value.size + ' Б)')).join('&');
      }
      if (body instanceof Document) return safe(() => new XMLSerializer().serializeToString(body).slice(0, MAX_BODY), null);
      return '(двоичные данные, ' + size(body) + ' Б)';
    };
    const textual = (type) => !type || /^text\/|json|javascript|ecmascript|xml|x-www-form-urlencoded|svg|graphql|csv/i.test(type);
    const base64 = (buffer) => {
      const bytes = new Uint8Array(buffer);
      let text = '';
      for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      return btoa(text);
    };
    /// Reads a response (a clone): text up to 1 MB, images as base64, other binary as its size.
    const readBody = async (response) => {
      const type = response.headers.get('content-type') || '';
      const length = Number(response.headers.get('content-length')) || 0;
      if (length > MAX_BODY) return { size: length };
      // ponytail: a stream without Content-Length is read whole before the 1 MB cut.
      const buffer = await response.arrayBuffer();
      if (textual(type)) return { size: buffer.byteLength, body: new TextDecoder().decode(buffer.slice(0, MAX_BODY)) };
      if (/^image\//i.test(type) && buffer.byteLength <= MAX_BODY) return { size: buffer.byteLength, body: base64(buffer), base64: true };
      return { size: buffer.byteLength };
    };
    const headerList = (text) => text.trim().split(/[\r\n]+/).filter(Boolean).map((line) => {
      const colon = line.indexOf(':');
      return [line.slice(0, colon).trim(), line.slice(colon + 1).trim()];
    });

    // fetch/XHR wait here (by URL) for their resource timing entry, which has the phases.
    const awaitingTiming = new Map();
    const expectTiming = (url, id) => { awaitingTiming.set(url, [...(awaitingTiming.get(url) || []), id]); };

    // --- fetch
    const originalFetch = window.fetch;
    if (typeof originalFetch === 'function') {
      window.fetch = function fetch(input, init) {
        let request;
        try { request = new Request(input, init); } catch { return originalFetch.apply(this, arguments); }
        const id = 'f' + nextId++;
        const start = now();
        const url = request.url;
        const entry = { id, kind: 'fetch', url, method: request.method, start, ...initiator(),
          requestHeaders: safe(() => [...request.headers], []) };
        const blocked = blockReason(url);
        if (blocked) {
          ring.push({ ...entry, error: blocked, blocked: true, end: now() });
          return Promise.reject(new TypeError('Load failed'));
        }
        if (config.noStore && request.cache !== 'only-if-cached') request = new Request(request, { cache: 'no-store' });
        const body = init && init.body;
        const capture = ub.attached;
        if (capture && body != null) entry.requestBody = bodyText(body);
        if (capture && isForm(body)) entry.form = true;
        ring.push(entry);
        if (capture && body == null && input instanceof Request && !['GET', 'HEAD'].includes(request.method)) {
          request.clone().text().then((text) => ring.push({ id, url, requestBody: text.slice(0, MAX_BODY) }), () => {});
        }
        expectTiming(url, id);
        const upBytes = size(body);
        return originalFetch.call(this, request).then(async (response) => {
          const update = { id, url, status: response.status, statusText: response.statusText,
            responseHeaders: [...response.headers], mimeType: response.headers.get('content-type') || '',
            responseURL: response.url };
          if (!throttled()) {
            ring.push(update);
            if (capture && ub.attached) readBody(response.clone()).then((read) => ring.push({ id, url, end: now(), ...read }), () => {});
            return response;
          }
          const read = await readBody(response.clone()).catch(() => ({ size: 0 }));
          await sleep(arrival(start, read.size || 0, upBytes) - now());
          ring.push({ ...update, end: now(), ...(capture && ub.attached ? read : { size: read.size }) });
          return response;
        }, (error) => {
          ring.push({ id, url, error: String(error && error.message || error), end: now() });
          throw error;
        });
      };
    }

    // --- XMLHttpRequest
    const XHR = window.XMLHttpRequest;
    const xhrState = new WeakMap();
    const replayed = new WeakSet(); // events we re-dispatch after a throttling delay
    const xhrSize = (xhr) => safe(() => {
      if (xhr.responseType === '' || xhr.responseType === 'text') return new Blob([xhr.responseText]).size;
      const response = xhr.response;
      return response == null ? 0 : response instanceof Blob ? response.size
        : response.byteLength !== undefined ? response.byteLength : new Blob([JSON.stringify(response)]).size;
    }, 0);
    const xhrBody = (xhr) => safe(() => {
      const type = xhr.responseType;
      if (type === '' || type === 'text') return { size: xhrSize(xhr), body: xhr.responseText.slice(0, MAX_BODY) };
      if (type === 'json') return { size: xhrSize(xhr), body: JSON.stringify(xhr.response).slice(0, MAX_BODY) };
      if (type === 'document') return { body: xhr.response ? xhr.response.documentElement.outerHTML.slice(0, MAX_BODY) : '' };
      return { size: xhrSize(xhr) };
    }, {});
    /// Throttling: capture listeners at the target run before the page's, so they hold the
    /// request's events and re-dispatch them once latency + size ÷ bandwidth has passed.
    // ponytail: readyState/responseText show the response during the delay; a page that
    // polls them instead of listening sees it early.
    const holdEvents = (xhr, start, upBytes) => {
      const held = [];
      const hold = (event) => {
        if (replayed.has(event)) return;
        event.stopImmediatePropagation();
        held.push(event);
        if (event.type !== 'loadend') return;
        sleep(arrival(start, xhrSize(xhr), upBytes) - now()).then(() => {
          for (const original of held) {
            const copy = original instanceof ProgressEvent
              ? new ProgressEvent(original.type, { lengthComputable: original.lengthComputable, loaded: original.loaded, total: original.total })
              : new Event(original.type);
            replayed.add(copy);
            xhr.dispatchEvent(copy);
          }
        });
      };
      for (const type of ['readystatechange', 'progress', 'load', 'error', 'abort', 'timeout', 'loadend']) {
        xhr.addEventListener(type, hold, true);
      }
    };
    if (XHR) {
      const proto = XHR.prototype;
      const { open, send, setRequestHeader } = proto;
      proto.open = function (method, url, async) {
        xhrState.set(this, { method: String(method).toUpperCase(), url: absolute(url), headers: [], async: async !== false });
        return open.apply(this, arguments);
      };
      proto.setRequestHeader = function (name, value) {
        const state = xhrState.get(this);
        if (state) state.headers.push([String(name), String(value)]);
        return setRequestHeader.apply(this, arguments);
      };
      proto.send = function (body) {
        const state = xhrState.get(this);
        if (!state) return send.apply(this, arguments);
        const xhr = this;
        const id = 'x' + nextId++;
        const url = state.url;
        const start = now();
        // XHR has no cache mode; same-origin requests take the header without a preflight.
        if (config.noStore && safe(() => new URL(url).origin === location.origin, false)) {
          setRequestHeader.call(this, 'Cache-Control', 'no-cache');
          state.headers.push(['Cache-Control', 'no-cache']);
        }
        const entry = { id, kind: 'xhr', url, method: state.method, start, ...initiator(), requestHeaders: state.headers.slice() };
        const capture = ub.attached;
        if (capture && body != null) entry.requestBody = bodyText(body);
        if (capture && isForm(body)) entry.form = true;
        // A blocked XHR is failed by the tab's content rule list; this only names the reason.
        const blocked = blockReason(url);
        ring.push(entry);
        expectTiming(url, id);
        let failure = null;
        this.addEventListener('error', () => { failure = blocked || 'Ошибка сети'; });
        this.addEventListener('abort', () => { failure = 'Отменено'; });
        this.addEventListener('timeout', () => { failure = 'Время ожидания истекло'; });
        this.addEventListener('loadend', () => {
          const update = { id, url, end: now(), status: xhr.status, statusText: xhr.statusText,
            responseHeaders: safe(() => headerList(xhr.getAllResponseHeaders()), []),
            mimeType: safe(() => xhr.getResponseHeader('content-type') || '', ''), responseURL: xhr.responseURL };
          if (failure) update.error = failure;
          if (failure && blocked) update.blocked = true;
          Object.assign(update, capture && ub.attached ? xhrBody(xhr) : { size: xhrSize(xhr) });
          ring.push(update);
        });
        if (state.async && throttled()) holdEvents(this, start, size(body));
        return send.apply(this, arguments);
      };
    }

    // --- WebSocket
    const OriginalWebSocket = window.WebSocket;
    if (typeof OriginalWebSocket === 'function') {
      const socketIds = new WeakMap();
      const frameData = (data) => typeof data === 'string'
        ? { data: data.slice(0, MAX_BODY), length: data.length }
        : { data: '(двоичный кадр, ' + size(data) + ' Б)', binary: true, length: size(data) };
      const WebSocket = function WebSocket(url, protocols) {
        if (!new.target) return OriginalWebSocket.apply(this, arguments); // throws like the original
        const socket = arguments.length > 1 ? new OriginalWebSocket(url, protocols) : new OriginalWebSocket(url);
        const id = 'w' + nextId++;
        const wsURL = socket.url;
        socketIds.set(socket, id);
        const protocolList = protocols == null ? [] : [].concat(protocols);
        ring.push({ id, kind: 'websocket', url: wsURL, method: 'GET', start: now(), ...initiator(),
          requestHeaders: protocolList.length ? [['Sec-WebSocket-Protocol', protocolList.join(', ')]] : [] });
        socket.addEventListener('open', () => ring.push({ id, url: wsURL, status: 101, statusText: 'Switching Protocols',
          responseHeaders: [['Sec-WebSocket-Protocol', socket.protocol], ['Sec-WebSocket-Extensions', socket.extensions]].filter(([, v]) => v) }));
        socket.addEventListener('message', (event) => {
          if (!replayed.has(event) && ub.attached) ub.send('networkFrame', { id, outgoing: false, time: now(), ...frameData(event.data) });
        }, true);
        socket.addEventListener('error', () => ring.push({ id, url: wsURL, error: blockReason(wsURL) || 'Ошибка соединения' }));
        socket.addEventListener('close', (event) => ring.push({ id, url: wsURL, end: now(), closeCode: event.code, closeReason: event.reason }));
        // Throttling: incoming messages are re-dispatched after latency + size ÷ bandwidth, in order.
        let queue = Promise.resolve();
        socket.addEventListener('message', (event) => {
          if (replayed.has(event) || !throttled()) return;
          event.stopImmediatePropagation();
          const received = now();
          queue = queue.then(() => sleep(arrival(received, size(event.data), 0) - now())).then(() => {
            const copy = new MessageEvent('message', { data: event.data, origin: event.origin, lastEventId: event.lastEventId });
            replayed.add(copy);
            socket.dispatchEvent(copy);
          });
        }, true);
        return socket;
      };
      WebSocket.prototype = OriginalWebSocket.prototype;
      Object.setPrototypeOf(WebSocket, OriginalWebSocket);
      const originalSend = OriginalWebSocket.prototype.send;
      OriginalWebSocket.prototype.send = function (data) {
        const id = socketIds.get(this);
        if (id && ub.attached) ub.send('networkFrame', { id, outgoing: true, time: now(), ...frameData(data) });
        return originalSend.apply(this, arguments);
      };
      window.WebSocket = WebSocket;
    }

    // --- resource timing: everything else, plus the phases of fetch/XHR and the document
    const kindOf = (url, initiatorType) => {
      const path = safe(() => new URL(url).pathname.toLowerCase(), '');
      if (/\.css$/.test(path)) return 'stylesheet';
      if (/\.m?js$/.test(path)) return 'script';
      if (/\.(png|jpe?g|gif|webp|avif|svg|ico|bmp)$/.test(path)) return 'image';
      if (/\.(woff2?|ttf|otf|eot)$/.test(path)) return 'font';
      if (/\.(mp4|webm|mov|m4v|mp3|m4a|aac|ogg|oga|wav|flac|m3u8)$/.test(path)) return 'media';
      switch (initiatorType) {
        case 'script': return 'script';
        case 'img': case 'image': case 'input': return 'image';
        case 'video': case 'audio': case 'track': return 'media';
        case 'iframe': case 'frame': return 'document';
        default: return 'other';
      }
    };
    /// HAR timings in ms, -1 when unknown. Cross-origin resources without
    /// Timing-Allow-Origin report zero phases, so only the total is known.
    const timingsOf = (e) => {
      if (!e.requestStart) return { blocked: -1, dns: -1, connect: -1, ssl: -1, send: 0, wait: -1, receive: Math.max(0, e.duration) };
      const dns = Math.max(0, e.domainLookupEnd - e.domainLookupStart);
      const connect = Math.max(0, e.connectEnd - e.connectStart);
      const ssl = e.secureConnectionStart > 0 ? Math.max(0, e.connectEnd - e.secureConnectionStart) : -1;
      const wait = Math.max(0, e.responseStart - e.requestStart);
      const receive = Math.max(0, e.responseEnd - e.responseStart);
      return { blocked: Math.max(0, e.duration - dns - connect - wait - receive), dns, connect, ssl, send: 0, wait, receive };
    };
    const resourceUpdate = (e) => ({
      url: e.name, start: performance.timeOrigin + e.startTime, end: performance.timeOrigin + e.startTime + e.duration,
      timings: timingsOf(e), transferSize: e.transferSize || 0, encodedSize: e.encodedBodySize || 0,
      decodedSize: e.decodedBodySize || 0, protocol: e.nextHopProtocol || '',
      ...(e.responseStatus ? { status: e.responseStatus } : {}),
    });
    safe(() => {
      const observer = new PerformanceObserver((list) => {
        for (const e of list.getEntries()) {
          if (e.entryType === 'navigation') {
            // Native merges this into the document entry from WKNavigationResponse.
            ring.push({ id: 'nav', kind: 'document', method: 'GET', ...resourceUpdate(e), url: location.href });
            continue;
          }
          const isRequest = e.initiatorType === 'fetch' || e.initiatorType === 'xmlhttprequest';
          const waiting = isRequest && awaitingTiming.get(e.name);
          if (waiting && waiting.length) {
            const id = waiting.shift();
            if (!waiting.length) awaitingTiming.delete(e.name);
            const update = resourceUpdate(e);
            delete update.start; // the wrapper's start is the call itself
            ring.push({ id, ...update });
          } else if (!isRequest) {
            ring.push({ id: 'r' + nextId++, kind: kindOf(e.name, e.initiatorType), method: 'GET', initiator: e.initiatorType, ...resourceUpdate(e) });
          }
        }
      });
      observer.observe({ type: 'resource', buffered: true });
      observer.observe({ type: 'navigation', buffered: true });
    }, null);

    ub.module('network', () => ({
      /// The tab's settings, sent to every frame while the panel is open.
      configure({ blocked = [], offline = false, latency = 0, down = 0, up = 0, noStore = false }) {
        Object.assign(config, { blocked: blocked.map(globRegex), offline, latency, down, up, noStore });
      },
      /// «Повторить запрос»: the same method, headers and body, through the wrappers.
      replay({ kind, method, url, headers = [], body, form }) {
        let payload = body == null || method === 'GET' || method === 'HEAD' ? undefined : body;
        if (form && payload !== undefined) {
          const data = new FormData();
          for (const [key, value] of new URLSearchParams(payload)) data.append(key, value);
          payload = data;
          headers = headers.filter(([name]) => name.toLowerCase() !== 'content-type');
        }
        headers = headers.filter(([name]) => !/^(cookie|host|content-length|origin|referer|user-agent)$/i.test(name));
        if (kind === 'xhr') {
          const xhr = new XMLHttpRequest();
          xhr.open(method, url);
          for (const [name, value] of headers) safe(() => xhr.setRequestHeader(name, value), null);
          xhr.send(payload);
        } else {
          window.fetch(url, { method, headers, body: payload }).catch(() => {});
        }
        return true;
      },
      /// A response body the wrappers did not read (spec: loaded like Источники).
      async body({ url }) {
        const response = await originalFetch.call(window, url, { cache: 'force-cache', credentials: 'include' });
        return { ...await readBody(response), mimeType: response.headers.get('content-type') || '', status: response.status };
      },
      detach() { Object.assign(config, defaults); },
    }));
  }
  // #endregion network

  // #region performance
  // #endregion performance

  // #region application
  // #endregion application

  // #region rendering
  // #endregion rendering

  // #region issues
  // Spec «Проблемы»: CSP violations, mixed content, failed loads, cookies the browser
  // refused, unlabeled form fields, deprecations. Each 'issue' is {kind, text, url?,
  // source?, line?, column?, element?}; the same issue is reported once per document.
  {
    const ring = ub.ring('issue', 300);
    const seen = new Set();
    const report = (issue) => {
      const key = [issue.kind, issue.text, issue.url, issue.source, issue.line, issue.element].join('|');
      if (seen.has(key)) return;
      seen.add(key);
      ring.push(issue);
    };
    const describe = (el) => {
      let text = '<' + el.localName;
      for (const name of ['id', 'name', 'type', 'class']) if (el.getAttribute(name)) text += ' ' + name + '="' + el.getAttribute(name) + '"';
      return text + '>';
    };

    document.addEventListener('securitypolicyviolation', (e) => report({
      kind: 'csp', url: e.blockedURI, source: e.sourceFile, line: e.lineNumber, column: e.columnNumber,
      text: 'Политика безопасности контента (' + (e.disposition === 'report' ? 'только отчёт' : 'блокировка')
        + ') нарушена директивой «' + (e.effectiveDirective || e.violatedDirective) + '»: '
        + (e.blockedURI || 'встроенный код') + (e.sample ? ' — ' + e.sample : ''),
      detail: e.originalPolicy,
    }), true);

    // Mixed content: http: loads on an https: page (WebKit upgrades or blocks most of them).
    const insecure = (url) => /^(http|ws):/i.test(url || '');
    if (location.protocol === 'https:') {
      safe(() => new PerformanceObserver((list) => {
        for (const e of list.getEntries()) {
          if (insecure(e.name)) report({ kind: 'mixed', url: e.name, text: 'Смешанное содержимое: ресурс загружен по HTTP на странице HTTPS' });
        }
      }).observe({ type: 'resource', buffered: true }), null);
    }

    // WebKit upgrades or blocks http: subresources, so their entries show https: or none;
    // the element's own attribute still says http:.
    const checkMixed = (e) => {
      const el = e.target;
      if (location.protocol !== 'https:' || !(el instanceof Element)) return;
      const raw = el.getAttribute('src') || el.getAttribute('href') || '';
      if (insecure(raw)) report({ kind: 'mixed', url: raw, element: ub.handle(el), text: 'Смешанное содержимое: ' + describe(el) + ' запрашивает ресурс по HTTP (WebKit повысил до HTTPS или заблокировал)' });
    };
    window.addEventListener('load', checkMixed, true);

    // Failed loads of elements (img, script, link, media); fetch/XHR failures come from Сеть.
    window.addEventListener('error', (e) => {
      checkMixed(e);
      const el = e.target;
      if (!(el instanceof Element)) return;
      const url = el.currentSrc || el.src || el.href || '';
      report({ kind: 'failed', url, element: ub.handle(el), text: 'Не удалось загрузить ресурс ' + describe(el) });
    }, true);

    // Cookies written from JS that the browser did not keep.
    const cookie = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
    if (cookie && cookie.set && cookie.get) {
      const check = (doc, value) => {
        const [pair, ...parts] = value.split(';');
        const name = pair.slice(0, pair.indexOf('=') < 0 ? pair.length : pair.indexOf('=')).trim();
        const attrs = new Map(parts.map((part) => {
          const eq = part.indexOf('=');
          return eq < 0 ? [part.trim().toLowerCase(), ''] : [part.slice(0, eq).trim().toLowerCase(), part.slice(eq + 1).trim()];
        }));
        const expires = attrs.has('expires') ? Date.parse(attrs.get('expires')) : NaN;
        if (attrs.has('max-age') && Number(attrs.get('max-age')) <= 0 || expires < Date.now()) return; // a deletion
        const kept = cookie.get.call(doc).split(';').some((item) => item.trim().split('=')[0] === name);
        if (kept) return;
        const sameSite = (attrs.get('samesite') || '').toLowerCase();
        const domain = (attrs.get('domain') || '').replace(/^\./, '').toLowerCase();
        const host = location.hostname.toLowerCase();
        let reason = 'браузер отклонил cookie';
        if (attrs.has('httponly')) reason = 'cookie с HttpOnly нельзя записать из JavaScript';
        else if (sameSite === 'none' && !attrs.has('secure')) reason = 'SameSite=None требует атрибут Secure';
        else if (attrs.has('secure') && location.protocol !== 'https:') reason = 'Secure cookie нельзя записать со страницы HTTP';
        else if (/^__(secure|host)-/i.test(name) && !attrs.has('secure')) reason = 'префикс ' + name.split('-')[0] + '- требует Secure';
        else if (domain && host !== domain && !host.endsWith('.' + domain)) reason = 'домен ' + domain + ' не совпадает с ' + host;
        else if (window !== top && safe(() => top.location.hostname, null) === null) reason = 'сторонний контекст: WebKit блокирует сторонние cookie';
        report({ kind: 'cookie', url: location.href, text: 'Cookie «' + name + '» не сохранена: ' + reason, detail: value.slice(0, 500) });
      };
      Object.defineProperty(Document.prototype, 'cookie', {
        configurable: true, enumerable: cookie.enumerable, get: cookie.get,
        set(value) {
          cookie.set.call(this, value);
          safe(() => check(this, String(value)), null);
        },
      });
    }

    // Form fields without a label or without autocomplete where it matters.
    const NEEDS_AUTOCOMPLETE = /(^|[-_ ])(name|first|last|email|e-mail|phone|tel|address|street|city|zip|postal|country|card|cc|user(name)?|login|password|birthday|organization|company)($|[-_ ])/i;
    const scanForms = () => {
      for (const field of document.querySelectorAll('input, select, textarea')) {
        const type = (field.getAttribute('type') || '').toLowerCase();
        if (['hidden', 'submit', 'button', 'reset', 'image'].includes(type)) continue;
        const labelled = (field.labels && field.labels.length) || field.getAttribute('aria-label')
          || field.getAttribute('aria-labelledby') || field.getAttribute('title');
        if (!labelled) report({ kind: 'label', element: ub.handle(field), text: 'Поле формы без метки: ' + describe(field) });
        const hint = [field.name, field.id, type].join(' ');
        if (field.localName === 'input' && !field.hasAttribute('autocomplete') && !field.form?.hasAttribute('autocomplete')
            && (['email', 'tel', 'password'].includes(type) || NEEDS_AUTOCOMPLETE.test(hint))) {
          report({ kind: 'autocomplete', element: ub.handle(field), text: 'Нет атрибута autocomplete у ' + describe(field) });
        }
      }
      if (location.protocol === 'https:') {
        for (const el of document.querySelectorAll('[src], link[href]')) checkMixed({ target: el });
        for (const form of document.querySelectorAll('form[action]')) {
          if (insecure(form.action)) report({ kind: 'mixed', element: ub.handle(form), url: form.action, text: 'Форма на странице HTTPS отправляется по HTTP' });
        }
      }
    };
    document.addEventListener('DOMContentLoaded', () => safe(scanForms, null));

    // Deprecated APIs and interventions WebKit reports.
    if (typeof ReportingObserver === 'function') {
      safe(() => new ReportingObserver((reports) => {
        for (const r of reports) {
          report({ kind: r.type === 'deprecation' ? 'deprecation' : 'intervention', text: r.body.message || r.body.id,
            url: r.url, source: r.body.sourceFile, line: r.body.lineNumber, column: r.body.columnNumber });
        }
      }, { types: ['deprecation', 'intervention'], buffered: true }).observe(), null);
    }

    ub.module('issues', () => ({
      attach() { if (document.readyState !== 'loading') safe(scanForms, null); },
      /// Scrolls the affected element into view and outlines it for a moment.
      reveal({ handle }) {
        const el = ub.object(handle);
        if (!(el instanceof Element)) return false;
        el.scrollIntoView({ block: 'center', behavior: 'smooth' });
        const old = el.style.outline;
        el.style.outline = '2px solid #e5484d';
        setTimeout(() => { el.style.outline = old; }, 1500);
        return true;
      },
    }));
  }
  // #endregion issues

  // #region security
  // #endregion security

  // #region coverage
  // #endregion coverage

  // #region changes
  // #endregion changes
})();
