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
  // #endregion application

  // #region rendering
  // #endregion rendering

  // #region issues
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
