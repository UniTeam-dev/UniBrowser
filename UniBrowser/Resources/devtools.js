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
  // Spec «Производительность»: while recording, rAF timestamps (top frame only: every frame
  // has its own rAF) and every entry type PerformanceObserver supports here. Times are this
  // frame's performance.now(); native shifts them by timeOrigin to line frames up.
  ub.module('performance', (ub) => {
    const MAX_FRAMES = 36000; // 10 min at 60 fps
    const MAX_ENTRIES = 5000;
    let recording = null;

    const plain = (e) => {
      const out = { type: e.entryType, name: String(e.name).slice(0, 2000), start: e.startTime, duration: e.duration };
      if (e.entryType === 'resource' || e.entryType === 'navigation') {
        Object.assign(out, {
          initiator: e.initiatorType, transfer: e.transferSize, size: e.decodedBodySize,
          dnsStart: e.domainLookupStart, dnsEnd: e.domainLookupEnd, connectStart: e.connectStart, connectEnd: e.connectEnd,
          requestStart: e.requestStart, responseStart: e.responseStart, responseEnd: e.responseEnd,
        });
      }
      if (e.entryType === 'navigation') {
        Object.assign(out, {
          domInteractive: e.domInteractive, dcl: e.domContentLoadedEventEnd, load: e.loadEventEnd, navigation: e.type,
        });
      }
      if (e.entryType === 'largest-contentful-paint') {
        out.start = e.renderTime || e.loadTime || e.startTime;
        out.size = e.size;
        out.url = e.url;
        if (e.element) out.element = ub.preview(e.element, 0).text;
      }
      if ('processingStart' in e) Object.assign(out, { processingStart: e.processingStart, processingEnd: e.processingEnd });
      if (e.entryType === 'layout-shift') out.value = e.value;
      return out;
    };

    const types = () => safe(() => [...PerformanceObserver.supportedEntryTypes], []);

    return {
      /// `buffered`: also the entries since this document started (reload-and-record, and
      /// frames that appear during a recording).
      start({ buffered = false } = {}) {
        if (recording) this.stop();
        const rec = { frames: [], entries: [], observers: [], start: buffered ? 0 : performance.now() };
        recording = rec;
        const collect = (list) => {
          for (const e of list.getEntries()) if (rec.entries.length < MAX_ENTRIES) rec.entries.push(plain(e));
        };
        if (window === top) {
          const tick = (time) => {
            if (recording !== rec) return;
            if (rec.frames.length < MAX_FRAMES) rec.frames.push(time);
            rec.raf = requestAnimationFrame(tick);
          };
          rec.raf = requestAnimationFrame(tick);
        }
        for (const type of types()) {
          safe(() => {
            const observer = new PerformanceObserver(collect);
            // 'event' only reports interactions over the threshold; 16 ms is the minimum.
            observer.observe(type === 'event' ? { type, buffered, durationThreshold: 16 } : { type, buffered });
            rec.observers.push({ observer, collect });
          }, null);
        }
        return { start: rec.start, timeOrigin: performance.timeOrigin, types: types() };
      },

      stop() {
        const rec = recording;
        if (!rec) return null;
        recording = null;
        cancelAnimationFrame(rec.raf);
        for (const { observer, collect } of rec.observers) {
          safe(() => collect({ getEntries: () => observer.takeRecords() }), null);
          observer.disconnect();
        }
        return {
          start: rec.start, end: performance.now(), timeOrigin: performance.timeOrigin,
          frames: rec.frames, entries: rec.entries, url: location.href, isTop: window === top,
        };
      },

      /// Page load summary: navigation timing, first paints, LCP (buffered).
      async load() {
        const nav = performance.getEntriesByType('navigation')[0];
        const paints = Object.fromEntries(performance.getEntriesByType('paint').map((e) => [e.name, e.startTime]));
        let lcp = null;
        if (types().includes('largest-contentful-paint')) {
          lcp = await new Promise((resolve) => {
            let last = null;
            const observer = new PerformanceObserver((list) => { const all = list.getEntries(); if (all.length) last = all[all.length - 1]; });
            safe(() => observer.observe({ type: 'largest-contentful-paint', buffered: true }), null);
            setTimeout(() => { observer.disconnect(); resolve(last && plain(last)); }, 100);
          });
        }
        return {
          navigation: nav ? plain(nav) : null,
          fp: paints['first-paint'], fcp: paints['first-contentful-paint'], lcp,
          resources: performance.getEntriesByType('resource').length, url: location.href,
        };
      },
    };
  });
  // #endregion performance

  // #region application
  // Spec «Приложение»: Web Storage, IndexedDB, Cache Storage, service workers, manifest link,
  // storage estimate and frame info of this frame. Cookies and site data are native (WebKit API).
  ub.module('application', (ub) => {
    const area = (kind) => (kind === 'session' ? sessionStorage : localStorage);
    const request = (r) => new Promise((resolve, reject) => {
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => reject(r.error);
    });
    // Opens an existing database; never creates one (the upgrade is aborted).
    const openDB = (name) => new Promise((resolve, reject) => {
      const r = indexedDB.open(name);
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => reject(r.error || new Error('Нет такой базы'));
      r.onblocked = () => reject(new Error('База занята другой вкладкой'));
      r.onupgradeneeded = () => r.transaction.abort();
    });
    const withStore = async (db, store, mode, fn) => {
      const conn = await openDB(db);
      try {
        const tx = conn.transaction(store, mode);
        const done = new Promise((resolve, reject) => {
          tx.oncomplete = resolve;
          tx.onerror = tx.onabort = () => reject(tx.error || new Error('Транзакция прервана'));
        });
        const result = await fn(tx.objectStore(store));
        await done;
        return result;
      } finally {
        conn.close();
      }
    };
    // One line of text for a key or value in a table; 1000 characters at most.
    const summary = (value) => {
      let text;
      try {
        text = JSON.stringify(value, (key, v) => {
          if (v instanceof ArrayBuffer) return 'ArrayBuffer(' + v.byteLength + ')';
          if (ArrayBuffer.isView(v)) return v.constructor.name + '(' + v.length + ')';
          if (typeof Blob !== 'undefined' && v instanceof Blob) return v.constructor.name + '(' + v.size + ')';
          if (v instanceof Map) return Object.fromEntries(v);
          if (v instanceof Set) return [...v];
          if (typeof v === 'bigint') return v + 'n';
          return v;
        });
      } catch { text = undefined; }
      if (value instanceof Date) text = 'Date(' + safe(() => value.toISOString(), 'Invalid Date') + ')';
      if (text === undefined) text = String(value);
      return text.length > 1000 ? text.slice(0, 1000) + '…' : text;
    };
    const worker = (w) => (w ? { scriptURL: w.scriptURL, state: w.state } : null);
    const registration = async (scope) =>
      (await navigator.serviceWorker.getRegistrations()).find((r) => r.scope === scope);

    return {
      info: () => ({
        url: location.href,
        origin: location.origin,
        title: document.title,
        secure: !!window.isSecureContext,
        isolated: !!window.crossOriginIsolated,
        manifest: (document.querySelector('link[rel~="manifest"]') || {}).href || null,
      }),

      storage({ kind }) {
        const s = area(kind);
        const items = [];
        for (let i = 0; i < s.length && i < 2000; i++) {
          const key = s.key(i);
          items.push({ key, value: s.getItem(key) });
        }
        return { items, total: s.length };
      },
      storageSet({ kind, key, value, oldKey }) {
        const s = area(kind);
        if (oldKey != null && oldKey !== key) s.removeItem(oldKey);
        s.setItem(key, value);
        return true;
      },
      storageRemove: ({ kind, key }) => { area(kind).removeItem(key); return true; },
      storageClear: ({ kind }) => { area(kind).clear(); return true; },

      async databases() {
        if (!window.indexedDB || !indexedDB.databases) return [];
        const result = [];
        for (const { name, version } of await indexedDB.databases()) {
          try {
            const conn = await openDB(name);
            const names = [...conn.objectStoreNames];
            let stores = [];
            if (names.length) {
              const tx = conn.transaction(names, 'readonly');
              stores = await Promise.all(names.map(async (store) => {
                const os = tx.objectStore(store);
                return {
                  name: store,
                  keyPath: Array.isArray(os.keyPath) ? os.keyPath.join(', ') : os.keyPath,
                  autoIncrement: os.autoIncrement,
                  indexes: [...os.indexNames],
                  count: await request(os.count()),
                };
              }));
            }
            result.push({ name, version: conn.version, stores });
            conn.close();
          } catch (error) {
            result.push({ name, version, stores: [], error: String(error && error.message || error) });
          }
        }
        return result;
      },
      records({ db, store, offset = 0, limit = 100 }) {
        return withStore(db, store, 'readonly', async (os) => {
          const total = request(os.count());
          const rows = await new Promise((resolve, reject) => {
            const rows = [];
            let skipped = offset === 0;
            const r = os.openCursor();
            r.onerror = () => reject(r.error);
            r.onsuccess = () => {
              const cursor = r.result;
              if (!cursor) return resolve(rows);
              if (!skipped) {
                skipped = true;
                return cursor.advance(offset);
              }
              rows.push({ key: summary(cursor.key), value: summary(cursor.value), handle: ub.handle({ key: cursor.primaryKey }) });
              if (rows.length >= limit) return resolve(rows);
              cursor.continue();
            };
          });
          return { rows, total: await total };
        });
      },
      deleteRecord: ({ db, store, handle }) =>
        withStore(db, store, 'readwrite', (os) => request(os.delete(ub.object(handle).key))).then(() => true),
      clearStore: ({ db, store }) => withStore(db, store, 'readwrite', (os) => request(os.clear())).then(() => true),
      deleteDatabase: ({ db }) => new Promise((resolve, reject) => {
        const r = indexedDB.deleteDatabase(db);
        r.onsuccess = () => resolve('deleted');
        r.onerror = () => reject(r.error);
        r.onblocked = () => resolve('blocked');
      }),

      async caches() {
        if (!window.caches) return [];
        const result = [];
        for (const name of await caches.keys()) {
          const cache = await caches.open(name);
          const requests = await cache.keys();
          const entries = [];
          for (const req of requests.slice(0, 500)) {
            const res = await cache.match(req, { ignoreVary: true });
            const header = (h) => (res && res.headers.get(h)) || '';
            entries.push({ url: req.url, status: res ? res.status : 0, type: header('content-type'), size: header('content-length'), date: header('date') });
          }
          result.push({ name, total: requests.length, entries });
        }
        return result;
      },
      cacheDeleteEntry: async ({ cache, url }) => (await caches.open(cache)).delete(url, { ignoreVary: true }),
      cacheDelete: ({ cache }) => caches.delete(cache),

      async serviceWorkers() {
        if (!navigator.serviceWorker) return [];
        return (await navigator.serviceWorker.getRegistrations()).map((r) => ({
          scope: r.scope,
          active: worker(r.active),
          waiting: worker(r.waiting),
          installing: worker(r.installing),
          updateViaCache: r.updateViaCache,
        }));
      },
      async unregister({ scope }) {
        const r = await registration(scope);
        return r ? r.unregister() : false;
      },
      async update({ scope }) {
        const r = await registration(scope);
        if (r) await r.update();
        return !!r;
      },

      async estimate() {
        const s = navigator.storage;
        if (!s || !s.estimate) return null;
        const e = await s.estimate();
        return { usage: e.usage, quota: e.quota, persisted: s.persisted ? await s.persisted() : null };
      },
    };
  });
  // #endregion application

  // #region rendering
  // Spec «Рендеринг»: emulated media features, vision deficiency, geolocation, timezone and
  // locale. RenderingModel keeps the state per tab and delivers it twice: a user script that
  // runs before this file defines window.__ubRenderingState (so overrides hold from document
  // start on every reload, before page scripts), and rendering.apply(state) for the live page.
  /* pure:start (checked by scripts/rendering_check.mjs) */
  const renderingPure = (OrigDate, OrigDTF) => {
    const TRUE = '(min-width: 0px)';
    const FALSE = '(min-width: 1000000px)';
    const formatters = new Map();
    const formatter = (timeZone) => {
      let f = formatters.get(timeZone);
      if (!f) {
        f = new OrigDTF('en-US', {
          timeZone, hourCycle: 'h23', era: 'short',
          year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric',
        });
        formatters.set(timeZone, f);
      }
      return f;
    };
    const offsets = new Map();
    const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const pad = (n, width = 2) => String(n).padStart(width, '0');

    const pure = {
      /// A media query list with each emulated feature test replaced by an always-true or
      /// always-false test; with `print` on, the types print and screen flip. The engine then
      /// evaluates the rest (`not`, `and`, other features) as usual.
      rewriteMedia(text, media) {
        let out = String(text).replace(/\(\s*(prefers-reduced-motion|prefers-contrast)\s*(?::\s*([a-z-]+)\s*)?\)/gi, (all, name, value) => {
          const emulated = media[name.toLowerCase()];
          if (!emulated) return all;
          const on = value ? value.toLowerCase() === emulated : emulated !== 'no-preference';
          return on ? TRUE : FALSE;
        });
        if (media.print) {
          let depth = 0;
          out = out.replace(/[()]|\b(?:print|screen)\b/gi, (token) => {
            if (token === '(') depth++;
            else if (token === ')') depth--;
            else if (depth === 0) return 'all and ' + (token.toLowerCase() === 'print' ? TRUE : FALSE);
            return token;
          });
        }
        return out;
      },

      /// local − UTC of `timeZone` at UTC time `ms`, in ms. Cached per 15 minutes: every
      /// zone changes offset on a quarter hour.
      zoneOffset(timeZone, ms) {
        const key = timeZone + ' ' + Math.floor(ms / 900000);
        let offset = offsets.get(key);
        if (offset !== undefined) return offset;
        const t = Math.floor(ms / 1000) * 1000;
        const p = {};
        for (const { type, value } of formatter(timeZone).formatToParts(t)) p[type] = value;
        const year = /^B/.test(p.era) ? 1 - p.year : +p.year;
        const d = new OrigDate(0);
        d.setUTCFullYear(year, p.month - 1, +p.day);
        d.setUTCHours(+p.hour, +p.minute, +p.second, 0);
        offset = d.getTime() - t;
        if (offsets.size > 5000) offsets.clear();
        offsets.set(key, offset);
        return offset;
      },
      /// The UTC time whose wall-clock reading in `timeZone` is `local` (given as UTC ms).
      toUTC(timeZone, local) {
        const guess = local - pure.zoneOffset(timeZone, local);
        return local - pure.zoneOffset(timeZone, guess);
      },
      /// Date.prototype.toString / toDateString / toTimeString in `timeZone`.
      dateString(timeZone, t, part = 'full') {
        if (t !== t) return 'Invalid Date';
        const offset = pure.zoneOffset(timeZone, t);
        const l = new OrigDate(t + offset);
        const y = l.getUTCFullYear();
        const date = DAYS[l.getUTCDay()] + ' ' + MONTHS[l.getUTCMonth()] + ' ' + pad(l.getUTCDate()) + ' ' + (y < 0 ? '-' + pad(-y, 6) : pad(y, 4));
        const minutes = Math.round(Math.abs(offset) / 60000);
        const name = (new OrigDTF('en-US', { timeZone, timeZoneName: 'long' }).formatToParts(t).find((x) => x.type === 'timeZoneName') || {}).value;
        const time = pad(l.getUTCHours()) + ':' + pad(l.getUTCMinutes()) + ':' + pad(l.getUTCSeconds()) +
          ' GMT' + (offset < 0 ? '-' : '+') + pad(Math.floor(minutes / 60)) + pad(minutes % 60) + (name ? ' (' + name + ')' : '');
        return part === 'date' ? date : part === 'time' ? time : date + ' ' + time;
      },
    };
    return pure;
  };
  /* pure:end */

  {
    const OrigDate = Date;
    const OrigDTF = Intl.DateTimeFormat;
    const R = renderingPure(OrigDate, OrigDTF);
    let state = { media: {}, vision: null, geolocation: null, timezone: null, locale: null };
    const mediaActive = () => Object.values(state.media).some(Boolean);

    // matchMedia answers for the emulated features; `media` keeps the page's query text.
    const origMatchMedia = window.matchMedia;
    if (origMatchMedia) {
      window.matchMedia = function matchMedia(query) {
        if (!mediaActive() || arguments.length === 0) return origMatchMedia.apply(this, arguments);
        const list = origMatchMedia.call(this, R.rewriteMedia(String(query), state.media));
        safe(() => Object.defineProperty(list, 'media', { value: String(query), configurable: true }), null);
        return list;
      };
    }

    // Stylesheets: @media rules (and media of <link>/<style>/@import) are rewritten in place,
    // so the cascade order stays the page's own; turning the emulation off restores them.
    const originals = new Map(); // MediaList -> original text
    const rewriteList = (list) => {
      if (!list) return;
      const original = originals.has(list) ? originals.get(list) : list.mediaText;
      if (!original) return;
      const next = mediaActive() ? R.rewriteMedia(original, state.media) : original;
      if (next === original && !originals.has(list)) return;
      if (!originals.has(list)) originals.set(list, original);
      if (list.mediaText !== next) list.mediaText = next;
      if (next === original) originals.delete(list);
    };
    const walkRules = (rules) => {
      for (const rule of rules) {
        if (rule.media && (rule instanceof CSSMediaRule || rule instanceof CSSImportRule)) rewriteList(rule.media);
        if (rule.styleSheet) walkSheet(rule.styleSheet);
        if (rule.cssRules) walkRules(rule.cssRules);
      }
    };
    const walkSheet = (sheet) => {
      if (sheet.ownerNode) safe(() => rewriteList(sheet.media), null);
      const rules = safe(() => sheet.cssRules, null); // cross-origin sheets throw
      if (rules) safe(() => walkRules(rules), null);
    };
    const applyMedia = () => {
      if (!mediaActive() && !originals.size) return;
      for (const sheet of document.styleSheets) walkSheet(sheet);
      for (const sheet of document.adoptedStyleSheets || []) walkSheet(sheet);
    };
    // New <style>/<link> while emulating; stops when the emulation is off.
    // ponytail: stylesheets in shadow roots are not rewritten; walk them if someone needs it.
    let observer = null;
    const onSheetLoad = (event) => { if (event.target.nodeName === 'LINK') applyMedia(); };
    const watchSheets = () => {
      const on = mediaActive();
      if (on && !observer) {
        observer = new MutationObserver((records) => {
          if (records.some((r) => r.target.nodeName === 'STYLE' || [...r.addedNodes].some((n) => n.nodeName === 'STYLE' || n.nodeName === 'LINK'))) applyMedia();
        });
        observer.observe(document, { childList: true, subtree: true, characterData: true });
        document.addEventListener('load', onSheetLoad, true);
      } else if (!on && observer) {
        observer.disconnect();
        observer = null;
        document.removeEventListener('load', onSheetLoad, true);
      }
    };

    // Vision deficiency: a filter on the top document's root element (iframes are inside it).
    // Matrices: Machado et al. 2009, severity 1.
    const MATRICES = {
      protanopia: '0.152286 1.052583 -0.204868 0 0 0.114503 0.786281 0.099216 0 0 -0.003882 -0.048116 1.051998 0 0 0 0 0 1 0',
      deuteranopia: '0.367322 0.860646 -0.227968 0 0 0.280085 0.672501 0.047413 0 0 -0.011820 0.042940 0.968881 0 0 0 0 0 1 0',
      tritanopia: '1.255528 -0.076749 -0.178779 0 0 -0.078411 0.930809 0.147602 0 0 0.004733 0.691367 0.303900 0 0 0 0 0 1 0',
    };
    const applyVision = () => {
      if (window !== top) return;
      const root = document.documentElement;
      if (!root || document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', applyVision, { once: true });
        return;
      }
      for (const old of document.querySelectorAll('[data-ub-vision]')) old.remove();
      const vision = state.vision;
      if (!vision) return;
      let filter = vision === 'blurred' ? 'blur(2px)' : vision === 'achromatopsia' ? 'grayscale(1)' : null;
      if (!filter && MATRICES[vision]) {
        const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('data-ub-vision', '');
        svg.setAttribute('aria-hidden', 'true');
        svg.setAttribute('style', 'position:absolute;width:0;height:0;overflow:hidden');
        svg.innerHTML = '<filter id="__ub-vision"><feColorMatrix type="matrix" values="' + MATRICES[vision] + '"/></filter>';
        root.appendChild(svg);
        filter = 'url(#__ub-vision)';
      }
      if (!filter) return;
      const style = document.createElement('style');
      style.setAttribute('data-ub-vision', '');
      style.textContent = 'html { filter: ' + filter + ' !important; }';
      root.appendChild(style);
    };

    // Geolocation: answers from the override, asynchronously like the real API.
    const geo = window.Geolocation && Geolocation.prototype;
    if (geo && geo.getCurrentPosition) {
      const original = { get: geo.getCurrentPosition, watch: geo.watchPosition, clear: geo.clearWatch };
      const FAKE_WATCH = 1e9;
      let nextWatch = FAKE_WATCH;
      const answer = (success, error) => setTimeout(() => {
        const g = state.geolocation;
        if (g === 'unavailable') {
          if (typeof error === 'function') error({ code: 2, message: 'Position unavailable', PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
          return;
        }
        const coords = { latitude: g.latitude, longitude: g.longitude, accuracy: 150, altitude: null, altitudeAccuracy: null, heading: null, speed: null };
        const position = { coords: { ...coords, toJSON: () => coords }, timestamp: OrigDate.now() };
        position.toJSON = () => ({ coords, timestamp: position.timestamp });
        if (typeof success === 'function') success(position);
      });
      geo.getCurrentPosition = function getCurrentPosition(success, error) {
        if (!state.geolocation) return original.get.apply(this, arguments);
        answer(success, error);
      };
      geo.watchPosition = function watchPosition(success, error) {
        if (!state.geolocation) return original.watch.apply(this, arguments);
        answer(success, error);
        return ++nextWatch;
      };
      geo.clearWatch = function clearWatch(id) {
        if (id > FAKE_WATCH) return;
        return original.clear.apply(this, arguments);
      };
    }

    // Timezone and locale: Date, Intl, toLocale*String and navigator.language(s). Installed
    // only once an override is set, then each wrapper passes through while it is off.
    let intlInstalled = false;
    const installIntl = () => {
      if (intlInstalled) return;
      intlInstalled = true;
      const proto = OrigDate.prototype;
      const { getTime, setTime } = proto;
      const getTimezoneOffset = proto.getTimezoneOffset;
      const zoned = (fn) => function (...args) {
        return state.timezone ? fn.call(this, state.timezone, getTime.call(this), args) : fn.original.apply(this, args);
      };
      const wrap = (name, fn) => {
        fn.original = proto[name];
        const wrapper = zoned(fn);
        Object.defineProperty(wrapper, 'name', { value: name });
        proto[name] = wrapper;
      };
      for (const unit of ['FullYear', 'Month', 'Date', 'Day', 'Hours', 'Minutes', 'Seconds', 'Milliseconds']) {
        const getUTC = proto['getUTC' + unit];
        wrap('get' + unit, (zone, t) => (t !== t ? NaN : getUTC.call(new OrigDate(t + R.zoneOffset(zone, t)))));
        if (unit === 'Day') continue;
        const setUTC = proto['setUTC' + unit];
        wrap('set' + unit, function (zone, t, args) {
          if (t !== t && unit !== 'FullYear') return NaN;
          const shifted = new OrigDate(t !== t ? 0 : t + R.zoneOffset(zone, t));
          const local = setUTC.apply(shifted, args);
          return setTime.call(this, local !== local ? NaN : R.toUTC(zone, local));
        });
      }
      wrap('getYear', function (zone, t) { return t !== t ? NaN : this.getFullYear() - 1900; });
      wrap('getTimezoneOffset', (zone, t) => (t !== t ? NaN : -R.zoneOffset(zone, t) / 60000));
      wrap('toString', (zone, t) => R.dateString(zone, t));
      wrap('toDateString', (zone, t) => R.dateString(zone, t, 'date'));
      wrap('toTimeString', (zone, t) => R.dateString(zone, t, 'time'));

      // Default locale and time zone for every Intl constructor and toLocale*String.
      const withDefaults = (args, zoneAware) => {
        if (state.locale && args[0] === undefined) args[0] = state.locale;
        const options = args[1];
        if (zoneAware && state.timezone && (options === undefined || (typeof options === 'object' && options !== null && options.timeZone === undefined))) {
          args[1] = { ...options, timeZone: state.timezone };
        }
        return args;
      };
      for (const name of ['DateTimeFormat', 'NumberFormat', 'Collator', 'PluralRules', 'RelativeTimeFormat', 'ListFormat', 'DisplayNames', 'Segmenter']) {
        const C = Intl[name];
        if (typeof C !== 'function') continue;
        const zoneAware = name === 'DateTimeFormat';
        Intl[name] = new Proxy(C, {
          construct: (target, args, newTarget) => Reflect.construct(target, withDefaults(args, zoneAware), newTarget),
          apply: (target, self, args) => Reflect.apply(target, self, withDefaults(args, zoneAware)),
        });
      }
      for (const [owner, names, zoneAware] of [
        [proto, ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString'], true],
        [Number.prototype, ['toLocaleString'], false],
        [window.BigInt && BigInt.prototype, ['toLocaleString'], false],
      ]) {
        for (const name of names) {
          const original = owner && owner[name];
          if (typeof original !== 'function') continue;
          owner[name] = { [name](...args) { return original.apply(this, withDefaults(args, zoneAware)); } }[name];
        }
      }
      const localeCompare = String.prototype.localeCompare;
      String.prototype.localeCompare = {
        localeCompare(that, locales, options) {
          return localeCompare.call(this, that, locales === undefined && state.locale ? state.locale : locales, options);
        },
      }.localeCompare;

      let languages = null;
      for (const name of ['language', 'languages']) {
        const descriptor = Object.getOwnPropertyDescriptor(Navigator.prototype, name);
        if (!descriptor || !descriptor.get) continue;
        const get = descriptor.get;
        Object.defineProperty(Navigator.prototype, name, {
          ...descriptor,
          get() {
            if (!state.locale) return get.call(this);
            if (name === 'language') return state.locale;
            if (!languages || languages[0] !== state.locale) languages = Object.freeze([state.locale]);
            return languages;
          },
        });
      }

      // The Date constructor and Date.parse read wall-clock times in the zone.
      // ponytail: a string is taken as local time unless it is date-only ISO or names Z, an
      // offset, GMT or UTC; abbreviations like "EST" are read in the emulated zone.
      const parse = function parse(text) {
        const t = OrigDate.parse(text);
        const zone = state.timezone;
        if (!zone || t !== t) return t;
        const s = String(text).trim();
        if (/^[+-]?\d{4,6}(-\d\d(-\d\d)?)?$/.test(s) || /(z|[+-]\d\d:?\d\d|\b(gmt|utc)\b[+-]?\d*)\s*(\(.*\))?$/i.test(s)) return t;
        // Native read it in the system zone: take that wall-clock reading into the emulated zone.
        return R.toUTC(zone, t - getTimezoneOffset.call(new OrigDate(t)) * 60000);
      };
      const ZonedDate = function Date(...args) {
        const zone = state.timezone;
        if (!new.target) return zone ? R.dateString(zone, OrigDate.now()) : OrigDate();
        if (zone && args.length >= 2) {
          const local = OrigDate.UTC(...args);
          return Reflect.construct(OrigDate, [local !== local ? NaN : R.toUTC(zone, local)], new.target);
        }
        if (zone && args.length === 1 && typeof args[0] === 'string') return Reflect.construct(OrigDate, [parse(args[0])], new.target);
        return Reflect.construct(OrigDate, args, new.target);
      };
      Object.defineProperty(ZonedDate, 'length', { value: 7 });
      ZonedDate.prototype = proto;
      ZonedDate.now = OrigDate.now;
      ZonedDate.UTC = OrigDate.UTC;
      ZonedDate.parse = parse;
      Object.defineProperty(proto, 'constructor', { value: ZonedDate, writable: true, configurable: true });
      window.Date = ZonedDate;
    };

    const setState = (next) => {
      const valid = (fn) => { try { fn(); return true; } catch { return false; } };
      const timezone = typeof next.timezone === 'string' && next.timezone && valid(() => new OrigDTF('en-US', { timeZone: next.timezone })) ? next.timezone : null;
      const locale = typeof next.locale === 'string' && next.locale && valid(() => Intl.getCanonicalLocales(next.locale)) ? next.locale : null;
      const g = next.geolocation;
      state = {
        media: next.media && typeof next.media === 'object' ? next.media : {},
        vision: typeof next.vision === 'string' ? next.vision : null,
        geolocation: g === 'unavailable' || (g && Number.isFinite(g.latitude) && Number.isFinite(g.longitude)) ? g : null,
        timezone,
        locale,
      };
      if (timezone || locale) installIntl();
      watchSheets();
      applyMedia();
      applyVision();
    };

    const initial = window.__ubRenderingState;
    if (initial) {
      delete window.__ubRenderingState;
      safe(() => setState(initial), null);
    }
    ub.module('rendering', () => ({
      apply(next) { setState(next); return true; },
    }));
  }
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
  // Spec «Покрытие»: a CSS rule is used if its selector matches something while recording
  // (checked on start, after each mutation batch, on hover/focus, and on stop). Rules are
  // found by parsing the sheet's text, so unused ranges are offsets into that text.
  // coverage:parser-start (scripts/coverage_check.mjs tests this part)
  /// Paren-aware split of a selector list.
  const splitList = (list) => {
    const parts = [];
    let depth = 0, from = 0;
    for (let i = 0; i < list.length; i++) {
      const c = list[i];
      if (c === '(' || c === '[') depth++;
      else if (c === ')' || c === ']') depth--;
      else if (c === ',' && depth === 0) { parts.push(list.slice(from, i).trim()); from = i + 1; }
    }
    parts.push(list.slice(from).trim());
    return parts;
  };

  /// Style rules of a CSS text, in source order: {selector, start, end, children}. `start` is
  /// the selector's first character, `end` is after the closing brace. Rules inside @media,
  /// @supports, @layer, @container, @scope become rules of the enclosing level; nested rules
  /// (CSS nesting) are children with the selector resolved. Other at-rules are skipped.
  const parseCSS = (text) => {
    const n = text.length;
    const rules = [];
    const stack = [{ kind: 'root', rules, selector: null }];
    const GROUPS = ['media', 'supports', 'layer', 'container', 'scope', 'document', '-moz-document', 'starting-style'];
    const skipBlank = (i, end) => {
      for (;;) {
        while (i < end && /\s/.test(text[i])) i++;
        if (text[i] === '/' && text[i + 1] === '*') { const close = text.indexOf('*/', i + 2); i = close < 0 ? end : close + 2; } else return i;
      }
    };
    const nest = (selector, parent) => splitList(selector)
      .map((part) => part.includes('&') ? part.replaceAll('&', ':is(' + parent + ')') : ':is(' + parent + ') ' + part)
      .join(', ');
    let preludeStart = 0;
    let i = 0;
    while (i < n) {
      const c = text[i];
      if (c === '/' && text[i + 1] === '*') {
        const close = text.indexOf('*/', i + 2);
        i = close < 0 ? n : close + 2;
      } else if (c === '"' || c === "'") {
        i++;
        while (i < n && text[i] !== c && text[i] !== '\n') i += text[i] === '\\' ? 2 : 1;
        i++;
      } else if (c === '\\') {
        i += 2;
      } else if (c === '{') {
        const start = skipBlank(preludeStart, i);
        const prelude = text.slice(start, i).trim();
        const top = stack[stack.length - 1];
        let frame;
        if (top.kind === 'opaque') {
          frame = { kind: 'opaque' };
        } else if (prelude[0] === '@') {
          const name = (/^@([\w-]+)/.exec(prelude) || [])[1];
          frame = GROUPS.includes(String(name).toLowerCase()) ? { kind: 'group', rules: top.rules, selector: top.selector } : { kind: 'opaque' };
        } else {
          const selector = top.selector ? nest(prelude, top.selector) : prelude;
          const rule = { selector, start, end: n, children: [] };
          top.rules.push(rule);
          frame = { kind: 'style', rules: rule.children, selector, rule };
        }
        stack.push(frame);
        preludeStart = ++i;
      } else if (c === '}') {
        if (stack.length > 1) { const frame = stack.pop(); if (frame.rule) frame.rule.end = i + 1; }
        preludeStart = ++i;
      } else if (c === ';') {
        preludeStart = ++i;
      } else {
        i++;
      }
    }
    return rules;
  };

  /// What querySelector can test: pseudo-elements dropped, an emptied compound becomes `*`.
  const matchable = (selector) => splitList(selector
    .replace(/::[\w-]+(\([^)]*\))?/g, '')
    .replace(/:(before|after|first-line|first-letter)\b/gi, ''))
    .map((part) => !part ? '*' : /[>+~]$/.test(part) ? part + ' *' : part)
    .join(', ');

  /// Line ranges (1-based, inclusive, merged) covered by offset ranges of `text`.
  const lineRanges = (text, ranges) => {
    const starts = [0];
    for (let i = text.indexOf('\n'); i >= 0; i = text.indexOf('\n', i + 1)) starts.push(i + 1);
    const lineOf = (offset) => {
      let lo = 0, hi = starts.length - 1;
      while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= offset) lo = mid; else hi = mid - 1; }
      return lo + 1;
    };
    const lines = [];
    for (const [from, to] of ranges) {
      const a = lineOf(from), b = lineOf(Math.max(from, to - 1));
      const last = lines[lines.length - 1];
      if (last && a <= last[1] + 1) last[1] = Math.max(last[1], b); else lines.push([a, b]);
    }
    return lines;
  };
  // coverage:parser-end

  ub.module('coverage', (ub) => {
    const DYNAMIC = /:(hover|active|focus|focus-visible|focus-within)\b/;
    const fetchText = ub.nativeFetch || window.fetch; // merge: Сеть may expose the unwrapped fetch as ub.nativeFetch
    const utf8 = (text) => new TextEncoder().encode(text).length;
    let rec = null;

    const matches = (rule) => {
      try { return !!document.querySelector(matchable(rule.selector)); } catch { return false; }
    };

    const sheetsOf = () => {
      const all = [];
      const add = (sheet) => {
        all.push(sheet);
        for (const rule of safe(() => [...sheet.cssRules], [])) if (rule.styleSheet) add(rule.styleSheet);
      };
      for (const sheet of [...document.styleSheets, ...safe(() => document.adoptedStyleSheets, [])]) add(sheet);
      return all;
    };

    const load = async (sheet, key) => {
      const node = sheet.ownerNode;
      const item = { key, url: sheet.href || location.href, rules: [] };
      if (!sheet.href && node && node.localName === 'style') {
        item.text = node.textContent;
        item.inline = [...document.querySelectorAll('style')].indexOf(node);
      } else {
        if (sheet.href) {
          try {
            const response = await fetchText(sheet.href, { cache: 'force-cache', credentials: 'include' });
            if (response.ok) item.text = await response.text();
          } catch { /* cross-origin without CORS: try the CSSOM */ }
        }
        if (item.text === undefined) {
          const rules = safe(() => [...sheet.cssRules], null);
          if (rules) {
            item.text = rules.map((rule) => rule.cssText).join('\n');
            item.rebuilt = true; // not the file's text: offsets don't match Источники
          } else {
            item.error = 'Нет доступа к правилам (другой источник без CORS)';
          }
        }
        if (!sheet.href) item.constructed = true;
      }
      if (item.text !== undefined) {
        item.rules = parseCSS(item.text);
        item.total = utf8(item.text);
      }
      return item;
    };

    /// Marks rules that match now; only unused ones are tested. `dynamicOnly` after hover/focus.
    const check = (dynamicOnly) => {
      const visit = (rules) => {
        for (const rule of rules) {
          if (!rule.used && (!dynamicOnly || DYNAMIC.test(rule.selector))) rule.used = matches(rule);
          if (rule.used) visit(rule.children);
        }
      };
      for (const item of rec.items.values()) visit(item.rules);
    };

    const summary = (item, withRanges) => {
      const out = { key: item.key, url: item.url, total: item.total || 0, unused: 0 };
      for (const field of ['inline', 'rebuilt', 'constructed', 'error']) if (item[field] !== undefined) out[field] = item[field];
      if (item.text === undefined) return out;
      const ranges = [];
      const walk = (rules) => { for (const rule of rules) if (rule.used) walk(rule.children); else ranges.push([rule.start, rule.end]); };
      walk(item.rules);
      out.unused = ranges.reduce((sum, [from, to]) => sum + utf8(item.text.slice(from, to)), 0);
      if (withRanges) {
        out.ranges = ranges;
        out.lines = lineRanges(item.text, ranges);
      }
      return out;
    };

    const discover = async () => {
      for (const sheet of sheetsOf()) {
        if (rec.keys.has(sheet)) continue;
        const key = rec.nextKey++;
        rec.keys.set(sheet, key);
        rec.items.set(key, await load(sheet, key));
      }
    };

    const results = (withRanges) => [...rec.items.values()].map((item) => summary(item, withRanges));

    // Re-check after DOM changes, at most every 250 ms; live totals go to the panel.
    const schedule = (dynamicOnly) => {
      if (!rec || rec.timer) return;
      rec.timer = setTimeout(async () => {
        if (!rec) return;
        rec.timer = null;
        if (!dynamicOnly) await discover();
        if (!rec) return;
        check(dynamicOnly);
        ub.send('coverage', { sheets: results(false) });
      }, 250);
    };
    const onPointer = () => schedule(true);

    return {
      async start() {
        if (rec) this.stop();
        rec = { items: new Map(), keys: new WeakMap(), nextKey: 1, timer: null };
        const current = rec;
        await discover();
        if (rec !== current) return [];
        check(false);
        rec.observer = new MutationObserver(() => schedule(false));
        rec.observer.observe(document, { subtree: true, childList: true, attributes: true });
        for (const type of ['mouseover', 'focusin', 'mousedown']) document.addEventListener(type, onPointer, { capture: true, passive: true });
        return results(false);
      },

      /// Final check; returns every sheet with its unused ranges and lines.
      stop() {
        if (!rec) return [];
        clearTimeout(rec.timer);
        rec.observer && rec.observer.disconnect();
        for (const type of ['mouseover', 'focusin', 'mousedown']) document.removeEventListener(type, onPointer, { capture: true });
        check(false);
        const out = results(true);
        rec = null;
        return out;
      },
    };
  });
  // #endregion coverage

  // #region changes
  // #endregion changes
})();
