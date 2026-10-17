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
  // Spec «Элементы». Node ids are core handles (ub.handle). Each frame serves its own
  // document; native puts child frames' documents under their <iframe> rows (frameLink).
  {
    const origAdd = EventTarget.prototype.addEventListener;
    const origRemove = EventTarget.prototype.removeEventListener;
    const origAttachShadow = Element.prototype.attachShadow;
    const origFetch = window.fetch;
    const MAX_ROWS = 2000;
    const listenerLists = new WeakMap(); // target -> [{type, listener, capture, once, passive}]
    const shadows = new WeakMap();       // host -> shadow root, closed ones too

    // «Обработчики событий»: recorded from document start; behaviour and `this` unchanged.
    const captureOf = (options) => typeof options === 'boolean' ? options : !!(options && options.capture);
    EventTarget.prototype.addEventListener = function (type, listener, options) {
      if (listener) safe(() => {
        const target = this == null ? window : this;
        const list = listenerLists.get(target) || [];
        const capture = captureOf(options);
        if (!list.some((e) => e.type === String(type) && e.listener === listener && e.capture === capture)) {
          list.push({ type: String(type), listener, capture, once: !!(options && options.once), passive: !!(options && options.passive) });
          listenerLists.set(target, list);
        }
      }, null);
      return origAdd.call(this, type, listener, options);
    };
    EventTarget.prototype.removeEventListener = function (type, listener, options) {
      safe(() => {
        const list = listenerLists.get(this == null ? window : this);
        const capture = captureOf(options);
        const i = list ? list.findIndex((e) => e.type === String(type) && e.listener === listener && e.capture === capture) : -1;
        if (i >= 0) list.splice(i, 1);
      }, null);
      return origRemove.call(this, type, listener, options);
    };
    // Closed shadow roots are only reachable through attachShadow.
    Element.prototype.attachShadow = function (init) {
      const root = origAttachShadow.call(this, init);
      safe(() => shadows.set(this, root), null);
      return root;
    };

    /* elements:pure */
    /// Splits on `separator` outside quotes, brackets and parentheses.
    const splitTop = (text, separator) => {
      const parts = [];
      let depth = 0, quote = null, start = 0;
      for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        if (quote) { if (ch === '\\') i++; else if (ch === quote) quote = null; continue; }
        if (ch === '"' || ch === "'") quote = ch;
        else if (ch === '(' || ch === '[') depth++;
        else if (ch === ')' || ch === ']') depth--;
        else if (ch === separator && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; }
      }
      parts.push(text.slice(start));
      return parts.map((part) => part.trim()).filter(Boolean);
    };
    const compareSpecificity = (x, y) => x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
    /// Selectors Level 4 specificity [ids, classes, types] of one complex selector.
    const specificity = (s) => {
      const result = [0, 0, 0];
      const add = (x) => { result[0] += x[0]; result[1] += x[1]; result[2] += x[2]; };
      const maxOf = (list) => splitTop(list, ',').map(specificity).reduce((m, x) => compareSpecificity(x, m) > 0 ? x : m, [0, 0, 0]);
      let i = 0;
      const ident = () => {
        const start = i;
        while (i < s.length && (/[\w -￿-]/.test(s[i]) || s[i] === '\\')) i += s[i] === '\\' ? 2 : 1;
        return s.slice(start, i);
      };
      const skipString = () => { const q = s[i++]; while (i < s.length && s[i] !== q) i += s[i] === '\\' ? 2 : 1; i++; };
      const args = () => { // at '(': returns the inside, stops after ')'
        const start = i + 1;
        let depth = 0;
        while (i < s.length) {
          const ch = s[i];
          if (ch === '"' || ch === "'") { skipString(); continue; }
          if (ch === '(') depth++;
          else if (ch === ')' && --depth === 0) { i++; return s.slice(start, i - 1); }
          i++;
        }
        return s.slice(start);
      };
      while (i < s.length) {
        const ch = s[i];
        if (ch === '#') { i++; ident(); result[0]++; }
        else if (ch === '.') { i++; ident(); result[1]++; }
        else if (ch === '[') { while (i < s.length && s[i] !== ']') { if (s[i] === '"' || s[i] === "'") skipString(); else i++; } i++; result[1]++; }
        else if (ch === ':') {
          i++;
          if (s[i] === ':') { i++; ident(); if (s[i] === '(') args(); result[2]++; continue; }
          const name = ident().toLowerCase();
          if (['before', 'after', 'first-line', 'first-letter'].includes(name)) { result[2]++; continue; }
          if (s[i] !== '(') { result[1]++; continue; }
          const inner = args();
          if (name === 'where') continue;
          if (['is', 'not', 'has', 'matches', 'any', '-webkit-any'].includes(name)) { add(maxOf(inner)); continue; }
          result[1]++;
          const of = /\bof\b([\s\S]*)$/.exec(inner);
          if (of && (name === 'nth-child' || name === 'nth-last-child')) add(maxOf(of[1]));
        }
        else if (/[\w -￿\\-]/.test(ch)) {
          ident();
          if (s[i] === '|') i++; // a namespace prefix, not a type
          else result[2]++;
        }
        else i++;
      }
      return result;
    };
    /// Index of the `nth` rule with this selector in stylesheet text, or -1.
    const ruleOffset = (text, selector, nth) => {
      const pattern = selector.split(/\s*,\s*/).map((part) => part.trim().replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\s+/g, '\\s+')).join('\\s*,\\s*');
      const regex = new RegExp('(^|[;{}\\s/])(' + pattern + ')\\s*\\{', 'g');
      let match, count = 0;
      while ((match = regex.exec(text))) {
        if (count++ === nth) return match.index + match[1].length;
        regex.lastIndex = match.index + 1;
      }
      return -1;
    };
    /* elements:pure end */

    // Tree rows.
    let overlayHost = null;
    const isFrameElement = (n) => n.nodeType === 1 && (n.localName === 'iframe' || n.localName === 'frame');
    const shadowOf = (n) => shadows.get(n) || n.shadowRoot || null;
    const shown = (n) => n !== overlayHost && !(n.nodeType === 3 && !n.data.trim());
    const kids = (n) => {
      const list = [];
      if (n.nodeType === 1) {
        const root = shadowOf(n);
        if (root) list.push(root);
        if (n.localName === 'template' && n.content) list.push(n.content);
        if (isFrameElement(n)) {
          const doc = safe(() => n.contentDocument, null);
          if (doc) list.push(doc);
          return list;
        }
      }
      for (let c = n.firstChild; c; c = c.nextSibling) if (shown(c)) list.push(c);
      return list;
    };
    const parentOf = (n) => n.parentNode || n.host
      || (n.nodeType === 9 && n !== document ? safe(() => n.defaultView.frameElement, null) : null);
    const known = new WeakSet(); // nodes native has rows for; mutations are reported only for them
    const row = (n) => {
      known.add(n);
      const r = { h: ub.handle(n), t: n.nodeType, n: n.nodeName };
      if (n.nodeType === 1) {
        r.n = n.localName;
        r.a = [...n.attributes].filter((a) => !a.name.startsWith('data-ub-')).map((a) => [a.name, a.value.slice(0, 2000)]);
        if (n.hasAttribute('data-ub-hidden')) r.hid = true;
        if (isFrameElement(n)) r.f = true;
      } else if (n.nodeType === 10) r.n = n.name;
      else if (n.nodeType === 11) r.n = n.host ? '#shadow-root (' + n.mode + ')' : '#document-fragment';
      else if (n.nodeType === 9) r.v = n.URL;
      else r.v = (n.data || '').slice(0, 5000);
      const list = kids(n);
      const only = list.length === 1 && list[0];
      if (n.nodeType === 1 && only && only.nodeType === 3 && only.data.length <= 80 && !only.data.trim().includes('\n')) {
        known.add(only);
        r.it = only.data.trim();
        r.ith = ub.handle(only);
        r.c = 0;
      } else r.c = r.f ? Math.max(list.length, 1) : list.length;
      return r;
    };

    // Mutations, debounced 300 ms (spec).
    let observer = null, observed = new WeakSet(), flushTimer = 0;
    const dirtyChildren = new Set(), dirtyRows = new Set();
    const observe = (root) => {
      if (!observer || observed.has(root)) return;
      observed.add(root);
      observer.observe(root, { childList: true, subtree: true, attributes: true, characterData: true });
    };
    const flush = () => {
      flushTimer = 0;
      const childList = [...dirtyChildren].filter((n) => known.has(n)).map((n) => ub.handle(n));
      const updated = [...dirtyRows].filter((n) => known.has(n)).map(row);
      dirtyChildren.clear();
      dirtyRows.clear();
      if (childList.length || updated.length) ub.send('domChanged', { childList, updated });
    };
    const onMutations = (records) => {
      for (const m of records) {
        if (m.type === 'attributes') {
          if (m.attributeName.startsWith('data-ub-') && m.attributeName !== 'data-ub-hidden') continue;
          dirtyRows.add(m.target);
        } else if (m.type === 'childList') {
          if ([...m.addedNodes, ...m.removedNodes].every((n) => n === overlayHost)) continue;
          dirtyChildren.add(m.target);
          dirtyRows.add(m.target);
        } else {
          dirtyRows.add(m.target);
          if (m.target.parentNode) dirtyRows.add(m.target.parentNode);
        }
      }
      if (!flushTimer && (dirtyChildren.size || dirtyRows.size)) flushTimer = setTimeout(flush, 300);
    };

    // Overlay: highlight with the box model and layout overlays, in a closed shadow root.
    const BOX = { margin: 'rgba(246,178,107,0.66)', border: 'rgba(255,229,153,0.66)', padding: 'rgba(147,196,125,0.55)', content: 'rgba(111,168,220,0.66)' };
    const LAYOUT = '#a347ff';
    const HATCH = 'background:repeating-linear-gradient(45deg,rgba(163,71,255,.3) 0 2px,transparent 2px 6px);';
    let overlayRoot = null, highlighted = null, redrawQueued = false;
    const layoutOn = new Set();
    const sides = (s, prefix, suffix = '') => ['Top', 'Right', 'Bottom', 'Left'].map((k) => parseFloat(s[prefix + k + suffix]) || 0);
    const queueRedraw = () => {
      if (redrawQueued) return;
      redrawQueued = true;
      requestAnimationFrame(redraw);
    };
    const layer = () => {
      if (!overlayHost) {
        overlayHost = document.createElement('ub-devtools-overlay');
        overlayHost.style.cssText = 'all:initial;display:block;position:fixed;inset:0;pointer-events:none;z-index:2147483647;';
        overlayRoot = origAttachShadow.call(overlayHost, { mode: 'closed' });
        origAdd.call(window, 'scroll', queueRedraw, { capture: true, passive: true });
        origAdd.call(window, 'resize', queueRedraw, { passive: true });
      }
      if (!overlayHost.isConnected) (document.documentElement || document).appendChild(overlayHost);
      return overlayRoot;
    };
    const div = (parent, css, text) => {
      const d = document.createElement('div');
      d.style.cssText = css;
      if (text) d.textContent = text;
      parent.appendChild(d);
      return d;
    };
    const fixed = (parent, x, y, w, h, css = '') => div(parent, `position:fixed;box-sizing:border-box;left:${x}px;top:${y}px;width:${Math.max(w, 0)}px;height:${Math.max(h, 0)}px;` + css);
    const tag = (parent, x, y, text) => div(parent, `position:fixed;left:${x}px;top:${y}px;font:10px -apple-system,system-ui,sans-serif;color:#fff;background:${LAYOUT};padding:0 3px;border-radius:2px;white-space:nowrap;`, text);
    const round = (v) => String(+v.toFixed(2));

    const drawHighlight = (root, node) => {
      let rect, s = null;
      if (node.nodeType === 1) { rect = node.getBoundingClientRect(); s = getComputedStyle(node); }
      else if (node.nodeType === 3) { const range = document.createRange(); range.selectNodeContents(node); rect = range.getBoundingClientRect(); }
      else return;
      const zero = [0, 0, 0, 0];
      const m = s ? sides(s, 'margin').map((v) => Math.max(v, 0)) : zero;
      const b = s ? sides(s, 'border', 'Width') : zero, p = s ? sides(s, 'padding') : zero;
      const widths = (w) => w.map((v) => v + 'px').join(' ');
      const outer = fixed(root, rect.left - m[3], rect.top - m[0], rect.width + m[1] + m[3], rect.height + m[0] + m[2], `border:solid ${BOX.margin};border-width:${widths(m)};`);
      const inner = (parent, w, color) => div(parent, `box-sizing:border-box;width:100%;height:100%;border:solid ${color};border-width:${widths(w)};`);
      inner(inner(inner(outer, b, BOX.border), p, BOX.padding), zero, 'transparent').style.background = BOX.content;
      const below = rect.bottom + m[2] + 4;
      const top = below + 22 < innerHeight ? below : Math.max(0, rect.top - m[0] - 26);
      div(root, `position:fixed;left:${Math.max(0, Math.min(rect.left, innerWidth - 320))}px;top:${top}px;font:11px -apple-system,system-ui,sans-serif;background:#fff;color:#222;border:1px solid #ccc;border-radius:3px;padding:2px 6px;white-space:nowrap;box-shadow:0 1px 4px rgba(0,0,0,.25);`,
        nodeText(node) + '   ' + round(rect.width) + ' × ' + round(rect.height));
    };

    const drawLayout = (root, el) => {
      const s = getComputedStyle(el), r = el.getBoundingClientRect();
      const b = sides(s, 'border', 'Width'), p = sides(s, 'padding');
      const x0 = r.left + b[3] + p[3], y0 = r.top + b[0] + p[0];
      const cw = r.width - b[1] - b[3] - p[1] - p[3], ch = r.height - b[0] - b[2] - p[0] - p[2];
      fixed(root, r.left, r.top, r.width, r.height, `border:2px solid ${LAYOUT};`);
      if (s.display.includes('grid')) {
        // Resolved track sizes in px; ponytail: tracks start at the content edge, so
        // justify/align-content offsets are not drawn.
        const tracks = (v) => v === 'none' ? [] : v.replace(/\[[^\]]*\]/g, ' ').trim().split(/\s+/).map(parseFloat).filter((n) => !isNaN(n));
        const cols = tracks(s.gridTemplateColumns), rows = tracks(s.gridTemplateRows);
        const cg = parseFloat(s.columnGap) || 0, rg = parseFloat(s.rowGap) || 0;
        const starts = (list, origin, gap) => { let at = origin; return list.map((size) => { const start = at; at += size + gap; return start; }); };
        const xs = starts(cols, x0 - el.scrollLeft, cg), ys = starts(rows, y0 - el.scrollTop, rg);
        const totalW = cols.reduce((a, v) => a + v, 0) + cg * Math.max(cols.length - 1, 0);
        const totalH = rows.reduce((a, v) => a + v, 0) + rg * Math.max(rows.length - 1, 0);
        cols.forEach((w, i) => rows.forEach((h, j) => fixed(root, xs[i], ys[j], w, h, `border:1px dashed ${LAYOUT};`)));
        if (cg) cols.slice(1).forEach((_, i) => fixed(root, xs[i] + cols[i], ys[0] ?? y0, cg, totalH, HATCH));
        if (rg) rows.slice(1).forEach((_, j) => fixed(root, xs[0] ?? x0, ys[j] + rows[j], totalW, rg, HATCH));
        cols.forEach((w, i) => tag(root, xs[i] + 2, (ys[0] ?? y0) - 15, round(w) + 'px'));
        rows.forEach((h, j) => tag(root, (xs[0] ?? x0) + 2, ys[j] + 2, round(h) + 'px'));
        const areas = [...s.gridTemplateAreas.matchAll(/"([^"]*)"/g)].map((m) => m[1].trim().split(/\s+/));
        const bounds = new Map();
        areas.forEach((names, j) => names.forEach((name, i) => {
          if (name === '.' || i >= cols.length || j >= rows.length) return;
          const a = bounds.get(name) || { c0: i, c1: i, r0: j, r1: j };
          bounds.set(name, { c0: Math.min(a.c0, i), c1: Math.max(a.c1, i), r0: Math.min(a.r0, j), r1: Math.max(a.r1, j) });
        }));
        for (const [name, a] of bounds) {
          const x = xs[a.c0], y = ys[a.r0], w = xs[a.c1] + cols[a.c1] - x, h = ys[a.r1] + rows[a.r1] - y;
          fixed(root, x, y, w, h, `border:2px solid ${LAYOUT};`);
          tag(root, x + w / 2 - 12, y + h / 2 - 7, name);
        }
      } else {
        const items = [...el.children].filter((c) => { const cs = getComputedStyle(c); return cs.display !== 'none' && cs.position !== 'absolute' && cs.position !== 'fixed'; });
        const rects = items.map((c) => c.getBoundingClientRect());
        rects.forEach((ir) => fixed(root, ir.left, ir.top, ir.width, ir.height, `border:1px dashed ${LAYOUT};`));
        const isRow = s.flexDirection.startsWith('row');
        const sorted = [...rects].sort((a, c) => isRow ? a.top - c.top || a.left - c.left : a.left - c.left || a.top - c.top);
        for (let i = 1; i < sorted.length; i++) {
          const a = sorted[i - 1], c = sorted[i];
          if (isRow && Math.abs(a.top - c.top) < 1 && c.left > a.right) fixed(root, a.right, y0, c.left - a.right, ch, HATCH);
          if (!isRow && Math.abs(a.left - c.left) < 1 && c.top > a.bottom) fixed(root, x0, a.bottom, cw, c.top - a.bottom, HATCH);
        }
      }
    };

    // Drawn at once for panel calls; scrolling and the picker coalesce into one frame.
    const redraw = () => {
      redrawQueued = false;
      for (const el of layoutOn) if (!el.isConnected) layoutOn.delete(el);
      if (highlighted && !highlighted.isConnected) highlighted = null;
      if (!highlighted && !layoutOn.size) { if (overlayHost) overlayHost.remove(); return; }
      const root = layer();
      root.replaceChildren();
      for (const el of layoutOn) safe(() => drawLayout(root, el), null);
      if (highlighted) safe(() => drawHighlight(root, highlighted), null);
    };

    // ⇧⌘C picker: the click is swallowed and selects; Esc cancels.
    let picking = false;
    const pickTarget = (event) => {
      let t = event.composedPath()[0];
      if (t && t.nodeType !== 1) t = t.parentElement;
      return t === overlayHost ? null : t;
    };
    const onPickMove = (event) => {
      const t = pickTarget(event);
      // An <iframe>'s own script highlights inside it.
      const next = t && !isFrameElement(t) ? t : null;
      if (next !== highlighted) { highlighted = next; queueRedraw(); }
    };
    const onPickOut = (event) => { if (!event.relatedTarget) { highlighted = null; queueRedraw(); } };
    const onPickEvent = (event) => {
      event.preventDefault();
      event.stopImmediatePropagation();
      if (event.type !== 'click') return;
      const t = pickTarget(event);
      setPicking(false);
      if (t) ub.send('picked', { handle: ub.handle(t) });
    };
    const onPickKey = (event) => {
      if (event.key !== 'Escape') return;
      event.preventDefault();
      event.stopImmediatePropagation();
      setPicking(false);
      ub.send('pickCancel');
    };
    const PICK_SWALLOW = ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu', 'touchstart', 'touchend'];
    const setPicking = (on) => {
      if (on === picking) return;
      picking = on;
      const method = on ? origAdd : origRemove;
      method.call(window, 'mousemove', onPickMove, true);
      method.call(window, 'mouseout', onPickOut, true);
      method.call(window, 'keydown', onPickKey, true);
      for (const type of PICK_SWALLOW) method.call(window, type, onPickEvent, true);
      if (!on) { highlighted = null; queueRedraw(); }
    };

    // Stylesheets the panel owns, per document or shadow root.
    const panelSheets = new Map();     // root -> sheet: hide (H) and forced states
    const inspectorSheets = new Map(); // root -> sheet: rules added with «+»
    const ownSheets = new WeakSet();
    const adopt = (map, node, css) => {
      const root = node.getRootNode();
      let sheet = map.get(root);
      if (!sheet && 'adoptedStyleSheets' in root) {
        sheet = new CSSStyleSheet();
        sheet.replaceSync(css);
        root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet];
        map.set(root, sheet);
        if (map === panelSheets) ownSheets.add(sheet);
      }
      return sheet;
    };

    /// Calls fn(rule, sheet, wraps) for every style rule under `root`, with its
    /// enclosing @media/@supports/@layer/@container/parent-rule preludes.
    const eachRule = (root, fn, unavailable) => {
      const header = (rule) => {
        if (rule instanceof CSSMediaRule) return '@media ' + rule.media.mediaText;
        if (rule instanceof CSSSupportsRule) return '@supports ' + rule.conditionText;
        if (rule instanceof CSSStyleRule) return rule.selectorText;
        if (typeof CSSLayerBlockRule !== 'undefined' && rule instanceof CSSLayerBlockRule) return '@layer ' + rule.name;
        if (typeof CSSContainerRule !== 'undefined' && rule instanceof CSSContainerRule) return '@container ' + rule.conditionText;
        return null;
      };
      const walk = (rules, sheet, wraps) => {
        for (const rule of rules) {
          if (rule instanceof CSSStyleRule) fn(rule, sheet, wraps);
          if (rule instanceof CSSImportRule) { if (rule.styleSheet) walkSheet(rule.styleSheet, wraps); continue; }
          const h = header(rule);
          if (h && rule.cssRules && rule.cssRules.length) walk(rule.cssRules, sheet, [...wraps, h]);
        }
      };
      const walkSheet = (sheet, wraps) => {
        if (ownSheets.has(sheet) || sheet.disabled) return;
        let rules;
        try { rules = sheet.cssRules; } catch { if (unavailable) unavailable(sheet); return; }
        const media = sheet.media && sheet.media.mediaText;
        walk(rules, sheet, media ? [...wraps, '@media ' + media] : wraps);
      };
      for (const sheet of [...(root.styleSheets || []), ...(root.adoptedStyleSheets || [])]) walkSheet(sheet, []);
    };
    const wrapsApply = (wraps, win) => wraps.every((w) =>
      w.startsWith('@media ') ? safe(() => win.matchMedia(w.slice(7)).matches, true)
        : w.startsWith('@supports ') ? safe(() => CSS.supports(w.slice(10)), true)
          : true);

    // Force state: matching rules cloned with the pseudo-class as an attribute selector.
    const PSEUDO = /:(hover|active|focus-visible|focus-within|focus|visited)(?![\w-])/g;
    const forced = new Map(); // element -> Set of states
    const panelCSS = (root) => {
      let css = '[data-ub-hidden]{visibility:hidden !important}\n';
      const states = new Set([...forced.values()].flatMap((set) => [...set]));
      if (!states.size) return css;
      eachRule(root, (rule, sheet, wraps) => {
        const selector = rule.selectorText.replace(PSEUDO, (m, state) => states.has(state) ? '[data-ub-force-' + state + ']' : m);
        if (selector !== rule.selectorText) css += wraps.reduceRight((inner, w) => w + '{' + inner + '}', selector + '{' + rule.style.cssText + '}') + '\n';
      });
      return css;
    };
    const rebuildPanelSheets = () => { for (const [root, sheet] of panelSheets) safe(() => sheet.replaceSync(panelCSS(root)), null); };

    // Styles pane data.
    const INHERITED = new Set('azimuth border-collapse border-spacing caption-side color cursor direction empty-cells font font-family font-feature-settings font-kerning font-size font-size-adjust font-stretch font-style font-variant font-variant-caps font-variant-ligatures font-variant-numeric font-weight hyphens letter-spacing line-break line-height list-style list-style-image list-style-position list-style-type orphans overflow-wrap paint-order quotes tab-size text-align text-align-last text-indent text-rendering text-shadow text-transform text-underline-position visibility white-space widows word-break word-spacing word-wrap writing-mode color-scheme caret-color accent-color -webkit-font-smoothing -webkit-text-fill-color -webkit-text-stroke -webkit-text-stroke-color -webkit-text-stroke-width -webkit-text-size-adjust fill fill-opacity fill-rule stroke stroke-width stroke-opacity stroke-dasharray stroke-linecap stroke-linejoin pointer-events'.split(' '));
    const isInherited = (name) => name.startsWith('--') || INHERITED.has(name);
    const disabledProps = new WeakMap(); // CSSStyleDeclaration -> [{name, value, important, index}]
    const inlineOwner = new WeakMap();   // element.style -> element
    let canvas = null;
    const colorsIn = (value) => {
      const found = [];
      for (const m of value.matchAll(/#[0-9a-f]{3,8}\b|\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\([^()]*\)|\b[a-z]+\b/gi)) {
        const text = m[0];
        if (/^[a-z]+$/i.test(text) && (['inherit', 'initial', 'unset', 'revert', 'currentcolor', 'none', 'auto'].includes(text.toLowerCase()) || !CSS.supports('color', text))) continue;
        if (!CSS.supports('color', text)) continue;
        canvas = canvas || document.createElement('canvas').getContext('2d');
        canvas.fillStyle = '#000';
        canvas.fillStyle = text;
        const v = String(canvas.fillStyle);
        const rgba = v.startsWith('#') ? [1, 3, 5].map((i) => parseInt(v.slice(i, i + 2), 16)).concat(1) : (v.match(/[\d.]+/g) || []).map(Number);
        found.push({ text, index: m.index, rgba: rgba.length === 3 ? rgba.concat(1) : rgba });
        if (found.length >= 4) break;
      }
      return found;
    };
    const declarations = (style) => {
      const out = [];
      for (const part of splitTop(style.cssText, ';')) {
        const colon = part.indexOf(':');
        if (colon < 0) continue;
        const name = part.slice(0, colon).trim();
        let value = part.slice(colon + 1).trim(), important = false;
        const bang = /\s*!\s*important\s*$/i.exec(value);
        if (bang) { important = true; value = value.slice(0, bang.index); }
        if (name) out.push({ name, value, important });
      }
      for (const d of disabledProps.get(style) || []) out.splice(Math.min(d.index, out.length), 0, { name: d.name, value: d.value, important: d.important, disabled: true });
      return out.map((p) => ({ ...p, colors: colorsIn(p.value) }));
    };
    const sheetName = (sheet) => {
      if ([...inspectorSheets.values()].includes(sheet)) return 'inspector-stylesheet';
      if (sheet.href) return sheet.href.split(/[?#]/)[0].split('/').pop() || sheet.href;
      return sheet.ownerNode ? '<style>' : 'adoptedStyleSheets';
    };
    const sheetResource = (sheet) => sheet.href || location.href + ' — ' + sheetName(sheet);
    const sheetTexts = new Map(); // href -> Promise<text | null>
    const sheetText = (sheet) => {
      if (!sheet.href) return Promise.resolve(sheet.ownerNode ? sheet.ownerNode.textContent : null);
      if (!sheetTexts.has(sheet.href)) {
        sheetTexts.set(sheet.href, safe(() => origFetch.call(window, sheet.href, { cache: 'force-cache' }), Promise.reject())
          .then((r) => r.ok ? r.text() : null).catch(() => null));
      }
      return sheetTexts.get(sheet.href);
    };
    /// Matched rules of one element, highest priority first.
    const collect = (root) => {
      const all = [];
      const unavailable = [];
      eachRule(root, (rule, sheet, wraps) => all.push({ rule, sheet, wraps, order: all.length }), (sheet) => unavailable.push(sheet.href || '<style>'));
      return { all, unavailable };
    };
    const matching = (el, all) => {
      const win = el.ownerDocument.defaultView || window;
      const out = [];
      for (const r of all) {
        if (!safe(() => el.matches(r.rule.selectorText), false) || !wrapsApply(r.wraps, win)) continue;
        let best = null;
        for (const part of splitTop(r.rule.selectorText, ',')) {
          if (!safe(() => el.matches(part), false)) continue;
          const sp = specificity(part);
          if (!best || compareSpecificity(sp, best) > 0) best = sp;
        }
        out.push({ ...r, spec: best || [0, 0, 0] });
      }
      return out.sort((a, b) => compareSpecificity(b.spec, a.spec) || b.order - a.order);
    };
    const ruleEntry = (r, nth) => ({
      h: ub.handle(r.rule), selector: r.rule.selectorText, media: r.wraps.filter((w) => w.startsWith('@')).join(' '),
      source: sheetName(r.sheet), href: r.sheet.href || null, spec: r.spec, props: declarations(r.rule.style),
      _sheet: r.sheet, _nth: nth,
    });
    const composedParent = (el) => el.parentElement || (el.parentNode && el.parentNode.host) || null;
    const classOff = new WeakMap(); // element -> classes switched off in the .cls editor

    // Change tracking for «Изменения» (ub.trackChange is in #region changes).
    const docResource = () => location.href;
    const openTag = (el) => '<' + el.localName + [...el.attributes].filter((a) => !a.name.startsWith('data-ub-')).map((a) => ' ' + a.name + '="' + a.value + '"').join('') + '>';
    const trackAttributes = (el, mutate) => ub.trackChange('attrs:' + ub.handle(el), {
      resource: docResource(), title: nodeText(el),
      text: () => openTag(el),
      save: () => [...el.attributes].filter((a) => !a.name.startsWith('data-ub-')).map((a) => [a.name, a.value]),
      restore: (saved) => {
        for (const a of [...el.attributes]) if (!a.name.startsWith('data-ub-')) el.removeAttribute(a.name);
        for (const [k, v] of saved) el.setAttribute(k, v);
      },
    }, mutate);
    const formatRule = (selector, style) => selector + ' {\n' + declarations(style).filter((p) => !p.disabled).map((p) => '  ' + p.name + ': ' + p.value + (p.important ? ' !important' : '') + ';\n').join('') + '}';
    /// Runs `mutate` on a rule's or inline style's declarations, tracked per rule.
    const trackStyle = (owner, mutate) => {
      if (owner instanceof CSSStyleRule) {
        return ub.trackChange('rule:' + ub.handle(owner), {
          resource: sheetResource(owner.parentStyleSheet), title: owner.selectorText,
          text: () => owner.parentStyleSheet ? formatRule(owner.selectorText, owner.style) : '',
          save: () => ({ selector: owner.selectorText, css: owner.style.cssText }),
          restore: (s) => { owner.selectorText = s.selector; owner.style.cssText = s.css; disabledProps.delete(owner.style); },
        }, () => mutate(owner.style));
      }
      const el = inlineOwner.get(owner);
      return ub.trackChange('inline:' + ub.handle(el), {
        resource: docResource(), title: nodeText(el) + ' style',
        text: () => formatRule('element.style', owner),
        save: () => el.getAttribute('style'),
        restore: (s) => { if (s === null) el.removeAttribute('style'); else el.setAttribute('style', s); disabledProps.delete(owner); },
      }, () => mutate(owner));
    };
    const styleOwner = (h) => {
      const owner = ub.object(h);
      if (!(owner instanceof CSSStyleRule) && !inlineOwner.has(owner)) throw new Error('devtools: not a style rule');
      return owner;
    };
    const setDeclaration = (style, name, value) => {
      const bang = /\s*!\s*important\s*$/i.exec(value);
      style.setProperty(name, bang ? value.slice(0, bang.index) : value, bang ? 'important' : '');
    };

    // Accessibility pane: role and name from ARIA, native semantics and content.
    const roleOf = (el) => {
      const explicit = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
      if (explicit) return explicit;
      const name = el.localName;
      const scoped = () => el.closest('article,aside,main,nav,section') ? 'generic' : null;
      switch (name) {
        case 'a': case 'area': return el.hasAttribute('href') ? 'link' : 'generic';
        case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
        case 'header': return scoped() || 'banner';
        case 'footer': return scoped() || 'contentinfo';
        case 'img': return el.getAttribute('alt') === '' ? 'presentation' : 'img';
        case 'section': return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : 'generic';
        case 'select': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
        case 'input': {
          const type = (el.getAttribute('type') || 'text').toLowerCase();
          const list = el.hasAttribute('list');
          return { checkbox: 'checkbox', radio: 'radio', range: 'slider', number: 'spinbutton', button: 'button', submit: 'button', reset: 'button', image: 'button', search: list ? 'combobox' : 'searchbox', hidden: 'none' }[type] || (list ? 'combobox' : 'textbox');
        }
      }
      return {
        article: 'article', aside: 'complementary', button: 'button', datalist: 'listbox', dd: 'definition', details: 'group', dialog: 'dialog', dt: 'term',
        fieldset: 'group', figure: 'figure', form: 'form', hr: 'separator', li: 'listitem', main: 'main', math: 'math', menu: 'list', nav: 'navigation',
        ol: 'list', ul: 'list', optgroup: 'group', option: 'option', output: 'status', p: 'paragraph', progress: 'progressbar', meter: 'meter', search: 'search',
        summary: 'button', table: 'table', tbody: 'rowgroup', thead: 'rowgroup', tfoot: 'rowgroup', td: 'cell', th: 'columnheader', tr: 'row', textarea: 'textbox',
        blockquote: 'blockquote', code: 'code', em: 'emphasis', strong: 'strong', del: 'deletion', ins: 'insertion', sub: 'subscript', sup: 'superscript',
        time: 'time', caption: 'caption', svg: 'graphics-document', html: 'document', body: 'generic', div: 'generic', span: 'generic',
      }[name] || (el.namespaceURI === 'http://www.w3.org/1999/xhtml' ? 'generic' : '');
    };
    const NAME_FROM_CONTENT = new Set('button cell checkbox columnheader gridcell heading link menuitem menuitemcheckbox menuitemradio option radio row rowheader switch tab tooltip treeitem caption term'.split(' '));
    const hiddenFromA11y = (el) => el.getAttribute('aria-hidden') === 'true' || el.hidden || safe(() => getComputedStyle(el).display === 'none' || getComputedStyle(el).visibility === 'hidden', false);
    const squash = (text) => text.replace(/\s+/g, ' ').trim();
    const byIds = (el, attribute) => squash((el.getAttribute(attribute) || '').split(/\s+/).map((id) => id && el.getRootNode().getElementById?.(id)).filter(Boolean).map((ref) => textAlternative(ref, true)).join(' '));
    const contentText = (el) => squash([...el.childNodes].map((c) => c.nodeType === 3 ? c.data : c.nodeType === 1 && !hiddenFromA11y(c) ? textAlternative(c, true) : '').join(' '));
    const textAlternative = (el, nested) => {
      if (!nested && el.hasAttribute('aria-labelledby')) { const t = byIds(el, 'aria-labelledby'); if (t) return t; }
      const label = squash(el.getAttribute('aria-label') || '');
      if (label) return label;
      if (el.localName === 'img' || el.localName === 'area' || (el.localName === 'input' && el.type === 'image')) { if (el.hasAttribute('alt')) return squash(el.alt); }
      if (['input', 'textarea', 'select', 'button', 'meter', 'progress', 'output'].includes(el.localName) && el.labels && el.labels.length && !nested) return squash([...el.labels].map(contentText).join(' '));
      if (el.localName === 'input' && ['button', 'submit', 'reset'].includes(el.type)) return el.value || { submit: 'Submit', reset: 'Reset' }[el.type] || '';
      if (nested && el.localName === 'input') return el.value;
      if (el.localName === 'fieldset') { const legend = el.querySelector(':scope > legend'); if (legend) return contentText(legend); }
      if (el.localName === 'figure') { const caption = el.querySelector(':scope > figcaption'); if (caption) return contentText(caption); }
      if (el.localName === 'table') { const caption = el.querySelector(':scope > caption'); if (caption) return contentText(caption); }
      if (nested || NAME_FROM_CONTENT.has(roleOf(el))) { const t = contentText(el); if (t) return t; }
      return squash(el.getAttribute('title') || el.getAttribute('placeholder') || '');
    };
    const nameSource = (el) => {
      if (el.hasAttribute('aria-labelledby') && byIds(el, 'aria-labelledby')) return 'aria-labelledby';
      if (squash(el.getAttribute('aria-label') || '')) return 'aria-label';
      if (el.hasAttribute('alt')) return 'alt';
      if (el.labels && el.labels.length) return '<label>';
      if (NAME_FROM_CONTENT.has(roleOf(el)) && contentText(el)) return 'содержимого';
      if (el.hasAttribute('title')) return 'title';
      if (el.hasAttribute('placeholder')) return 'placeholder';
      return '';
    };

    ub.module('elements', (ub) => ({
      attach() {
        observer = new MutationObserver(onMutations);
        observed = new WeakSet();
        observe(document);
      },
      detach() {
        if (observer) observer.disconnect();
        observer = null;
        setPicking(false);
        highlighted = null;
        layoutOn.clear();
        queueRedraw();
      },

      // Tree
      document: () => row(document),
      children({ handle }) {
        const n = ub.object(handle);
        if (!n) return [];
        const list = kids(n);
        for (const c of list) if (c.nodeType === 9 || c.nodeType === 11) observe(c);
        return list.slice(0, MAX_ROWS).map(row);
      },
      /// Rows from the document down to the node, for revealing it.
      path({ handle }) {
        const list = [];
        for (let n = ub.object(handle); n; n = parentOf(n)) list.unshift(row(n));
        return list;
      },
      highlight({ handle }) {
        highlighted = (handle && ub.object(handle)) || null;
        redraw();
      },
      pick({ on }) { setPicking(!!on); },
      search({ query }) {
        const lower = query.toLowerCase();
        const matches = new Set();
        safe(() => document.querySelectorAll(query).forEach((n) => matches.add(n)), null);
        safe(() => {
          const result = document.evaluate(query, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
          for (let i = 0; i < result.snapshotLength; i++) matches.add(result.snapshotItem(i));
        }, null);
        const found = [];
        const stack = [document];
        while (stack.length && found.length < 1000) {
          const n = stack.pop();
          const text = n.nodeType === 1 ? (openTag(n) + '</' + n.localName + '>').toLowerCase() : n.nodeType === 3 || n.nodeType === 8 ? n.data.toLowerCase() : '';
          if (n !== document && (matches.has(n) || (lower && text.includes(lower)))) found.push(n);
          if (!isFrameElement(n)) stack.push(...kids(n).reverse());
        }
        return found.map((n) => ub.handle(n));
      },

      // Node actions
      scrollIntoView({ handle }) {
        const n = ub.object(handle);
        const el = n && (n.nodeType === 1 ? n : n.parentElement);
        if (el) el.scrollIntoView({ block: 'center', inline: 'nearest' });
      },
      /// The border box in this frame's viewport, CSS px.
      rect({ handle }) {
        const n = ub.object(handle);
        let r;
        if (n.nodeType === 1) r = n.getBoundingClientRect();
        else { const range = document.createRange(); range.selectNodeContents(n); r = range.getBoundingClientRect(); }
        return { x: r.left, y: r.top, width: r.width, height: r.height };
      },
      /// Where a child frame's viewport starts inside this frame's viewport.
      frameOrigin({ handle }) {
        const el = ub.object(handle), r = el.getBoundingClientRect(), s = getComputedStyle(el);
        return { x: r.left + el.clientLeft + (parseFloat(s.paddingLeft) || 0), y: r.top + el.clientTop + (parseFloat(s.paddingTop) || 0) };
      },
      storeGlobal({ handle }) {
        let i = 1;
        while (('temp' + i) in window) i++;
        const name = 'temp' + i;
        window[name] = ub.object(handle);
        console.log(name, window[name]);
        return name;
      },
      outerHTML({ handle }) {
        const n = ub.object(handle);
        return n.nodeType === 1 ? n.outerHTML : n.nodeType === 9 ? n.documentElement.outerHTML : n.textContent;
      },
      selector({ handle }) {
        const parts = [];
        for (let n = ub.object(handle); n && n.nodeType === 1; n = n.parentElement) {
          if (n.id && n.getRootNode().querySelectorAll('#' + CSS.escape(n.id)).length === 1) { parts.unshift('#' + CSS.escape(n.id)); break; }
          let part = n.localName;
          const siblings = n.parentElement ? [...n.parentElement.children] : [];
          if (siblings.filter((c) => c.localName === n.localName).length > 1) part += ':nth-child(' + (siblings.indexOf(n) + 1) + ')';
          parts.unshift(part);
        }
        return parts.join(' > ');
      },
      /// Breakpoints via Web Inspector need the node found by a selector there.
      mark({ handle, token }) {
        const el = ub.object(handle);
        if (token) el.setAttribute('data-ub-break', token); else el.removeAttribute('data-ub-break');
      },

      // Editing
      /// Replaces attribute `name` (none: adds) with what `text` parses to, e.g. `a="1" b`.
      editAttribute({ handle, name, text }) {
        const el = ub.object(handle);
        const template = document.createElement('template');
        template.innerHTML = '<span ' + text + '></span>';
        const parsed = template.content.firstElementChild ? [...template.content.firstElementChild.attributes] : [];
        trackAttributes(el, () => {
          if (name && !parsed.some((a) => a.name === name)) el.removeAttribute(name);
          for (const a of parsed) el.setAttribute(a.name, a.value);
        });
      },
      setText({ handle, value }) {
        const n = ub.object(handle);
        ub.trackChange('text:' + handle, {
          resource: docResource(), title: nodeText(n.parentNode || n),
          text: () => n.data, save: () => n.data, restore: (s) => { n.data = s; },
        }, () => { n.data = value; });
      },
      setOuterHTML({ handle, html }) {
        const el = ub.object(handle);
        const parent = el.parentNode, prev = el.previousSibling, next = el.nextSibling;
        let added = [];
        ub.trackChange('html:' + handle, {
          resource: docResource(), title: nodeText(el),
          text: () => added.length ? added.map((n) => n.nodeType === 1 ? n.outerHTML : n.textContent).join('') : el.outerHTML,
          save: () => null,
          restore: () => { for (const n of added) n.remove(); parent.insertBefore(el, next && next.parentNode === parent ? next : null); },
        }, () => {
          el.outerHTML = html;
          added = [];
          for (let n = prev ? prev.nextSibling : parent.firstChild; n && n !== next; n = n.nextSibling) added.push(n);
        });
      },
      remove({ handle }) {
        const n = ub.object(handle);
        const html = () => n.nodeType === 1 ? n.outerHTML : n.textContent;
        ub.trackChange('remove:' + handle, {
          resource: docResource(), title: nodeText(n),
          text: () => n.parentNode ? html() : '',
          save: () => ({ parent: n.parentNode, next: n.nextSibling }),
          restore: (s) => s.parent.insertBefore(n, s.next && s.next.parentNode === s.parent ? s.next : null),
        }, () => n.parentNode.removeChild(n));
      },
      /// Moves the node into `parent` before `before` (0: at the end).
      move({ handle, parent, before }) {
        const n = ub.object(handle), target = ub.object(parent), ref = before ? ub.object(before) : null;
        if (!n || !target || n === ref || n.contains(target) || (ref && ref.parentNode !== target)) throw new Error('Узел нельзя переместить сюда');
        const where = () => nodeText(n.parentNode) + ' › ' + nodeText(n) + ' (позиция ' + ([...n.parentNode.childNodes].filter(shown).indexOf(n) + 1) + ')';
        ub.trackChange('move:' + handle, {
          resource: docResource(), title: nodeText(n), text: where,
          save: () => ({ parent: n.parentNode, next: n.nextSibling }),
          restore: (s) => s.parent.insertBefore(n, s.next && s.next.parentNode === s.parent ? s.next : null),
        }, () => target.insertBefore(n, ref));
      },
      toggleHidden({ handle }) {
        const el = ub.object(handle);
        if (!el || el.nodeType !== 1) return;
        adopt(panelSheets, el, panelCSS(el.getRootNode()));
        el.toggleAttribute('data-ub-hidden');
      },
      forceState({ handle, states }) {
        const el = ub.object(handle);
        for (const state of ['hover', 'active', 'focus', 'focus-visible', 'focus-within', 'visited']) el.toggleAttribute('data-ub-force-' + state, states.includes(state));
        if (states.length) forced.set(el, new Set(states)); else forced.delete(el);
        adopt(panelSheets, el, '');
        rebuildPanelSheets();
      },

      // Стили
      async styles({ handle }) {
        const el = ub.object(handle);
        if (!el || el.nodeType !== 1) return null;
        const root = el.getRootNode();
        const { all, unavailable } = collect(root);
        const nth = new Map(); // sheet -> selector -> count, for source lines
        const seen = all.map((r) => {
          const bySelector = nth.get(r.sheet) || new Map();
          nth.set(r.sheet, bySelector);
          const n = bySelector.get(r.rule.selectorText) || 0;
          bySelector.set(r.rule.selectorText, n + 1);
          return n;
        });
        const entries = (target) => matching(target, all).map((r) => ruleEntry(r, seen[r.order]));
        inlineOwner.set(el.style, el);
        const sections = [{ title: null, rules: [{ h: ub.handle(el.style), selector: 'element.style', inline: true, media: '', source: '', props: declarations(el.style) }, ...entries(el)] }];
        for (let a = composedParent(el); a; a = composedParent(a)) {
          if (a.getRootNode() !== root) continue; // ponytail: inherited rules across shadow boundaries are skipped
          inlineOwner.set(a.style, a);
          const rules = [{ h: ub.handle(a.style), selector: 'style attribute', inline: true, media: '', source: '', props: declarations(a.style) }, ...entries(a)]
            .filter((r) => r.props.some((p) => isInherited(p.name)));
          if (rules.length) sections.push({ title: nodeText(a), handle: ub.handle(a), rules });
        }
        // Overridden: the first enabled declaration of a name wins (important before normal
        // within one element); inherited ones only count for inherited properties.
        const winners = new Set();
        sections.forEach((section, index) => {
          const decls = section.rules.flatMap((r) => r.props).filter((p) => !p.disabled && (index === 0 || isInherited(p.name)));
          const local = new Set();
          for (const p of [...decls.filter((d) => d.important), ...decls.filter((d) => !d.important)]) {
            p.overridden = winners.has(p.name) || local.has(p.name);
            local.add(p.name);
          }
          for (const name of local) winners.add(name);
          if (index > 0) for (const r of section.rules) for (const p of r.props) if (!isInherited(p.name)) p.inactive = true;
        });
        // Source lines, from the stylesheet text.
        for (const section of sections) {
          for (const r of section.rules) {
            if (r._sheet) {
              const text = await sheetText(r._sheet);
              const offset = text ? ruleOffset(text, r.selector, r._nth) : -1;
              if (offset >= 0) r.source += ':' + (text.slice(0, offset).split('\n').length);
              r.resource = sheetResource(r._sheet);
            }
            delete r._sheet;
            delete r._nth;
          }
        }
        const off = classOff.get(el) || [];
        return {
          sections,
          unavailable,
          classes: [...[...el.classList].map((name) => ({ name, on: true })), ...off.filter((c) => !el.classList.contains(c)).map((name) => ({ name, on: false }))],
          forced: [...(forced.get(el) || [])],
        };
      },
      /// Sets, renames (oldName) or with an empty name or value removes a declaration.
      setProperty({ rule, name, value, oldName }) {
        const owner = styleOwner(rule);
        trackStyle(owner, (style) => {
          if (oldName && oldName !== name) style.removeProperty(oldName);
          if (!name || !value.trim()) { if (name) style.removeProperty(name); return; }
          setDeclaration(style, name.trim(), value.trim());
        });
      },
      /// Adds `name: value; …` text to a rule.
      addProperties({ rule, text }) {
        const owner = styleOwner(rule);
        trackStyle(owner, (style) => {
          for (const part of splitTop(text, ';')) {
            const colon = part.indexOf(':');
            if (colon > 0) setDeclaration(style, part.slice(0, colon).trim(), part.slice(colon + 1).trim());
          }
        });
      },
      toggleProperty({ rule, name, on }) {
        const owner = styleOwner(rule);
        trackStyle(owner, (style) => {
          const list = disabledProps.get(style) || [];
          if (on) {
            const i = list.findIndex((d) => d.name === name);
            if (i < 0) return;
            const [d] = list.splice(i, 1);
            style.setProperty(d.name, d.value, d.important ? 'important' : '');
          } else {
            const index = declarations(style).filter((p) => !p.disabled).findIndex((p) => p.name === name);
            const decl = declarations(style).find((p) => p.name === name && !p.disabled);
            if (!decl) return;
            list.push({ name, value: decl.value, important: decl.important, index });
            disabledProps.set(style, list);
            style.removeProperty(name);
          }
        });
      },
      setSelector({ rule, text }) {
        const owner = styleOwner(rule);
        if (!(owner instanceof CSSStyleRule)) return;
        trackStyle(owner, () => { owner.selectorText = text; });
      },
      /// «+»: a new rule for the node in the inspector stylesheet of its document.
      addRule({ handle }) {
        const el = ub.object(handle);
        const sheet = adopt(inspectorSheets, el, '');
        const selector = el.id ? '#' + CSS.escape(el.id) : el.localName + [...el.classList].map((c) => '.' + CSS.escape(c)).join('');
        const index = sheet.insertRule(selector + ' {}', sheet.cssRules.length);
        const rule = sheet.cssRules[index];
        ub.trackChange('rule:' + ub.handle(rule), {
          resource: sheetResource(sheet), title: selector, before: '',
          text: () => [...sheet.cssRules].includes(rule) ? formatRule(rule.selectorText, rule.style) : '',
          save: () => null,
          restore: () => { const i = [...sheet.cssRules].indexOf(rule); if (i >= 0) sheet.deleteRule(i); },
        }, () => null);
        return ub.handle(rule);
      },
      setClass({ handle, name, on }) {
        const el = ub.object(handle);
        const off = classOff.get(el) || [];
        trackAttributes(el, () => el.classList.toggle(name, on));
        classOff.set(el, on ? off.filter((c) => c !== name) : [...new Set([...off, name])]);
      },

      // Вычисленные
      computed({ handle }) {
        const el = ub.object(handle);
        if (!el || el.nodeType !== 1) return null;
        const s = getComputedStyle(el), r = el.getBoundingClientRect();
        const props = [];
        for (let i = 0; i < s.length; i++) props.push([s[i], s.getPropertyValue(s[i])]);
        props.sort((a, b) => a[0].localeCompare(b[0]));
        const border = sides(s, 'border', 'Width'), padding = sides(s, 'padding');
        const w = el.offsetWidth ?? r.width, h = el.offsetHeight ?? r.height;
        return {
          props,
          box: {
            margin: sides(s, 'margin'), border, padding,
            width: w - border[1] - border[3] - padding[1] - padding[3], height: h - border[0] - border[2] - padding[0] - padding[2],
            position: s.position === 'static' ? null : ['top', 'right', 'bottom', 'left'].map((k) => s[k]),
            kind: s.position,
          },
        };
      },

      // Обработчики событий
      listeners({ handle, ancestors }) {
        const n = ub.object(handle);
        const targets = [n];
        if (ancestors) { for (let a = parentOf(n); a; a = parentOf(a)) targets.push(a); targets.push(window); }
        const out = [];
        const source = (fn) => safe(() => Function.prototype.toString.call(typeof fn === 'function' ? fn : fn.handleEvent).slice(0, 400), '');
        for (const target of targets) {
          for (const e of listenerLists.get(target) || []) {
            out.push({ type: e.type, target: target === window ? 'Window' : nodeText(target), th: ub.handle(target), fh: ub.handle(e.listener), capture: e.capture, once: e.once, passive: e.passive, source: source(e.listener) });
          }
          for (const key in target) {
            if (!key.startsWith('on')) continue;
            const fn = safe(() => target[key], null);
            if (typeof fn === 'function') out.push({ type: key.slice(2), target: target === window ? 'Window' : nodeText(target), th: ub.handle(target), fh: ub.handle(fn), property: true, source: source(fn) });
          }
        }
        return out;
      },
      removeListener({ target, fn, type, capture, property }) {
        const t = ub.object(target);
        if (property) t['on' + type] = null;
        else t.removeEventListener(type, ub.object(fn), capture);
      },

      // Свойства: own and inherited enumerable keys, which covers DOM attributes.
      properties({ handle }) {
        const value = ub.object(handle);
        if (value === undefined || value === null) return [];
        const keys = new Set();
        safe(() => Object.getOwnPropertyNames(value).forEach((k) => keys.add(k)), null);
        safe(() => { for (const k in value) keys.add(k); }, null);
        const list = [...keys];
        if (!Array.isArray(value)) list.sort();
        return list.slice(0, 1000).map((key) => ({ key, value: ub.preview(safe(() => value[key], undefined), 0) }));
      },

      // Layout
      layout() {
        const out = [];
        const stack = [document.documentElement];
        while (stack.length && out.length < 500) {
          const el = stack.pop();
          if (!el) continue;
          const display = safe(() => getComputedStyle(el).display, '');
          if (/grid|flex/.test(display)) out.push({ h: ub.handle(el), label: nodeText(el), kind: display.includes('grid') ? 'grid' : 'flex', on: layoutOn.has(el) });
          stack.push(...[...el.children].reverse());
          const root = shadowOf(el);
          if (root) stack.push(...[...root.children].reverse());
        }
        return out;
      },
      layoutOverlay({ handle, on }) {
        const el = ub.object(handle);
        if (on) layoutOn.add(el); else layoutOn.delete(el);
        redraw();
      },

      // Доступность
      accessibility({ handle }) {
        const el = ub.object(handle);
        if (!el || el.nodeType !== 1) return null;
        const role = roleOf(el);
        const name = textAlternative(el, false);
        const describedBy = byIds(el, 'aria-describedby');
        const title = squash(el.getAttribute('title') || '');
        const description = describedBy || squash(el.getAttribute('aria-description') || '') || (nameSource(el) !== 'title' ? title : '');
        const focusable = el.tabIndex >= 0 && !el.disabled;
        const properties = [['Фокусируемый', focusable ? 'да' : 'нет'], ['Скрыт', hiddenFromA11y(el) ? 'да' : 'нет']];
        if (role === 'heading') properties.push(['Уровень', el.getAttribute('aria-level') || (el.localName.match(/^h([1-6])$/) || [])[1] || '2']);
        if ('disabled' in el) properties.push(['Отключён', el.disabled ? 'да' : 'нет']);
        if ('checked' in el && /checkbox|radio/.test(el.type)) properties.push(['Отмечен', el.checked ? 'да' : 'нет']);
        if ('required' in el) properties.push(['Обязательный', el.required ? 'да' : 'нет']);
        for (const a of el.attributes) if (a.name.startsWith('aria-') && !['aria-label', 'aria-labelledby', 'aria-describedby', 'aria-description'].includes(a.name)) properties.push([a.name, a.value]);
        const chain = [];
        for (let a = composedParent(el); a; a = composedParent(a)) chain.push({ h: ub.handle(a), role: roleOf(a) || a.localName, name: safe(() => textAlternative(a, false), '').slice(0, 80) });
        return { role: role || 'нет', name, source: name ? nameSource(el) : '', description, properties, chain: chain.reverse() };
      },
    }));
  }
  // #endregion elements

  // #region sources
  // #endregion sources

  // #region network
  // #endregion network

  // #region performance
  // #endregion performance

  // #region application
  // #endregion application

  // #region rendering
  // #endregion rendering

  // #region issues
  // #endregion issues

  // #region security
  // #endregion security

  // #region coverage
  // #endregion coverage

  // #region changes
  // Spec «Изменения»: every edit made from the panel, keyed so repeated edits of one rule
  // or node merge into one entry; «Отменить» restores the state before the first edit.
  {
    const changes = new Map(); // key -> {resource, title, before, text(), state, restore(state)}
    /// Runs `mutate` and reports the change. `info`: {resource, title, text(), save(),
    /// restore(saved), before?}; text() is the current state shown in the diff.
    ub.trackChange = (key, info, mutate) => {
      let change = changes.get(key);
      if (!change) {
        change = { ...info, before: 'before' in info ? info.before : info.text(), state: info.save() };
        changes.set(key, change);
      }
      const result = mutate();
      const after = safe(() => change.text(), '');
      if (after === change.before) {
        changes.delete(key);
        ub.send('change', { id: key, removed: true });
      } else {
        ub.send('change', { id: key, resource: change.resource, title: change.title, before: change.before, after });
      }
      return result;
    };
    ub.module('changes', (ub) => ({
      revert({ id }) {
        const change = changes.get(id);
        if (!change) return;
        changes.delete(id);
        change.restore(change.state);
        ub.send('change', { id, removed: true });
      },
    }));
  }
  // #endregion changes
})();
