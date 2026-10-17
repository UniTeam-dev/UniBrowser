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
  // Spec «Консоль»: every console method, uncaught errors and rejections, and what the
  // panel's input needs (command-line API, completion, saving values as globals).
  // Message `console`: {level, method, args: [preview], time, stack?: [{fn, url, line, column}],
  // table?: {columns, rows: [{key, cells: {column: preview}}]}, collapsed?}.
  const consoleEntries = ub.ring('console', 500);

  /// "fn@url:line:col" lines of a WebKit stack into frames (line/column 1-based).
  const parseStack = (stack) => String(stack || '').split('\n').filter(Boolean).map((line) => {
    const at = line.indexOf('@');
    const fn = at >= 0 ? line.slice(0, at) : '';
    const place = at >= 0 ? line.slice(at + 1) : line;
    const match = place.match(/^(.*):(\d+):(\d+)$/);
    return match ? { fn, url: match[1], line: +match[2], column: +match[3] } : { fn, url: place, line: 0, column: 0 };
  });
  // Called right inside a console wrapper: drops this function and the wrapper.
  const callerStack = () => {
    const stack = new Error().stack;
    return safe(() => parseStack(stack).slice(2), []);
  };

  // %c colours normalised by a canvas, so native gets #rrggbb / rgba().
  const colorContext = safe(() => document.createElement('canvas').getContext('2d'), null);
  const cssColor = (value) => {
    if (!value || !colorContext) return undefined;
    colorContext.fillStyle = '#000001';
    colorContext.fillStyle = value;
    return colorContext.fillStyle === '#000001' ? undefined : colorContext.fillStyle;
  };
  const parseStyle = (css) => {
    const span = document.createElement('span');
    span.style.cssText = css;
    const style = {};
    const color = cssColor(span.style.color), background = cssColor(span.style.backgroundColor || span.style.background);
    if (color) style.color = color;
    if (background) style.background = background;
    if (/^(bold|[6-9]00)$/.test(span.style.fontWeight)) style.bold = true;
    if (span.style.fontStyle === 'italic') style.italic = true;
    const size = parseFloat(span.style.fontSize);
    if (size > 0) style.size = Math.min(size, 40);
    return style;
  };

  /// console.log's format string (%s %d %i %f %o %O %c) applied: previews, strings styled.
  const formatArgs = (args) => {
    if (typeof args[0] !== 'string' || !args[0].includes('%')) return args.map((arg) => ub.preview(arg));
    const rest = args.slice(1);
    const out = [];
    let style, text = '';
    const flush = () => {
      if (text) out.push(style ? { type: 'string', text, style } : { type: 'string', text });
      text = '';
    };
    const parts = args[0].split(/(%[sdifoOc%])/);
    for (const part of parts) {
      if (!/^%[sdifoOc%]$/.test(part) || (part !== '%%' && !rest.length)) { text += part; continue; }
      if (part === '%%') { text += '%'; continue; }
      const arg = rest.shift();
      switch (part[1]) {
        case 's': text += typeof arg === 'string' ? arg : (arg !== null && typeof arg === 'object' ? ub.preview(arg, 0).text : String(arg)); break;
        case 'd': case 'i': text += String(typeof arg === 'number' ? Math.trunc(arg) : parseInt(arg, 10)); break;
        case 'f': text += String(parseFloat(arg)); break;
        case 'c': flush(); style = safe(() => parseStyle(String(arg)), undefined); break;
        default: flush(); out.push(ub.preview(arg));
      }
    }
    flush();
    return out.concat(rest.map((arg) => ub.preview(arg)));
  };

  /// console.table's rows: index column, one column per key (or `columns`), "Value" for primitives.
  const tableOf = (data, columns) => {
    if (data === null || typeof data !== 'object') return undefined;
    const keys = [], rows = [];
    let hasValue = false;
    const source = data instanceof Map ? [...data] : data instanceof Set ? [...data].map((v, i) => [i, v])
      : Object.keys(data).map((k) => [k, safe(() => data[k], undefined)]);
    for (const [key, row] of source.slice(0, MAX_KEYS)) {
      const cells = {};
      if (row !== null && typeof row === 'object') {
        for (const k of Object.keys(row).slice(0, 50)) {
          if (Array.isArray(columns) && !columns.includes(k)) continue;
          if (!keys.includes(k)) keys.push(k);
          cells[k] = ub.preview(safe(() => row[k], undefined), 0);
        }
      } else {
        hasValue = true;
        cells.Value = ub.preview(row, 0);
      }
      rows.push({ key: String(key), cells });
    }
    const ordered = Array.isArray(columns) ? columns.map(String).filter((c) => keys.includes(c)) : keys;
    return { columns: hasValue ? ordered.concat('Value') : ordered, rows };
  };

  const timers = new Map(), counters = new Map();
  const consoleMethods = {
    log: 'log', info: 'info', warn: 'warn', error: 'error', debug: 'debug', dir: 'log', dirxml: 'log',
    table: 'log', group: 'log', groupCollapsed: 'log', groupEnd: 'log', time: 'log', timeLog: 'log',
    timeEnd: 'log', count: 'log', countReset: 'log', assert: 'error', trace: 'log', clear: 'log',
  };
  /// The message for one console call, or undefined when the call prints nothing.
  const consoleMessage = (method, args, stack) => {
    const message = { level: consoleMethods[method], method, time: Date.now(), stack };
    const label = args.length && args[0] !== undefined ? String(args[0]) : 'default';
    switch (method) {
      case 'table': message.table = tableOf(args[0], args[1]); message.args = [ub.preview(args[0])]; break;
      case 'dir': case 'dirxml': message.args = [ub.preview(args[0])]; break;
      case 'group': case 'groupCollapsed':
        message.method = 'group';
        message.collapsed = method === 'groupCollapsed';
        message.args = args.length ? formatArgs(args) : [{ type: 'string', text: 'console.group' }];
        break;
      case 'groupEnd': case 'clear': message.args = []; break;
      case 'time':
        if (timers.has(label)) return { ...message, level: 'warn', args: [{ type: 'string', text: `Таймер «${label}» уже существует` }] };
        timers.set(label, performance.now());
        return undefined;
      case 'timeLog': case 'timeEnd': {
        if (!timers.has(label)) return { ...message, level: 'warn', args: [{ type: 'string', text: `Таймера «${label}» нет` }] };
        const ms = performance.now() - timers.get(label);
        if (method === 'timeEnd') timers.delete(label);
        message.args = [{ type: 'string', text: `${label}: ${ms.toFixed(3)} ms` }].concat(method === 'timeLog' ? args.slice(1).map((a) => ub.preview(a)) : []);
        break;
      }
      case 'count': {
        const count = (counters.get(label) || 0) + 1;
        counters.set(label, count);
        message.args = [{ type: 'string', text: `${label}: ${count}` }];
        break;
      }
      case 'countReset': counters.delete(label); return undefined;
      case 'assert':
        if (args[0]) return undefined;
        message.args = [{ type: 'string', text: 'Assertion failed' + (args.length > 1 ? ':' : '') }].concat(formatArgs(args.slice(1)));
        break;
      default: message.args = formatArgs(args);
    }
    return message;
  };
  for (const method of Object.keys(consoleMethods)) {
    const original = console[method];
    if (typeof original !== 'function') continue;
    console[method] = function (...args) {
      const stack = callerStack();
      safe(() => {
        const message = consoleMessage(method, args, stack);
        if (message) consoleEntries.push(message);
      }, null);
      return original.apply(this, args);
    };
  }

  // Uncaught errors (not resource load errors: those are plain Events) and rejections.
  // Errors of input typed in the panel are shown as its result, not as uncaught: a failed
  // parse is reported without a file ("Script error."), and statements run synchronously
  // between console.install and console.uninstall.
  let consoleRuns = 0, statementsRunning = false;
  window.addEventListener('error', (event) => {
    if (!(event instanceof ErrorEvent)) return;
    if (statementsRunning || (consoleRuns > 0 && !event.filename)) return;
    safe(() => {
      const error = event.error;
      const stack = error && error.stack ? parseStack(error.stack)
        : [{ fn: '', url: event.filename || '', line: event.lineno || 0, column: event.colno || 0 }];
      if (event.filename && (!stack.length || stack[0].url !== event.filename)) {
        stack.unshift({ fn: '', url: event.filename, line: event.lineno || 0, column: event.colno || 0 });
      }
      const value = error !== undefined && error !== null ? ub.preview(error, 1) : { type: 'string', text: event.message };
      consoleEntries.push({ level: 'error', method: 'exception', args: [{ type: 'string', text: 'Uncaught' }, value], time: Date.now(), stack });
    }, null);
  }, true);
  window.addEventListener('unhandledrejection', (event) => {
    safe(() => {
      const reason = event.reason;
      const stack = reason && reason.stack ? parseStack(reason.stack) : [];
      consoleEntries.push({ level: 'error', method: 'exception', args: [{ type: 'string', text: 'Uncaught (in promise)' }, ub.preview(reason, 1)], time: Date.now(), stack });
    }, null);
  });

  // Command-line API for input typed in the panel (spec «Консоль»).
  const selection = [];   // $0…$4, newest first; fed by Элементы through console.select
  let lastResult;         // $_
  const effects = {};     // copy()/clear()/inspect() results, taken by native after a run
  const began = new Set();
  const textOf = (value) => {
    if (typeof value === 'string') return value;
    if (safe(() => value instanceof Node, false)) return value.outerHTML || value.textContent || '';
    const json = safe(() => JSON.stringify(value, cycleSafe(), 2), undefined);
    return json === undefined ? String(value) : json;
  };
  const cycleSafe = () => {
    const seen = new WeakSet();
    return (key, value) => {
      if (value !== null && typeof value === 'object') {
        if (seen.has(value)) return '[Circular]';
        seen.add(value);
      }
      return typeof value === 'bigint' ? value.toString() : value;
    };
  };
  const commandLine = {
    get $_() { return lastResult; },
    get $0() { return selection[0]; },
    get $1() { return selection[1]; },
    get $2() { return selection[2]; },
    get $3() { return selection[3]; },
    get $4() { return selection[4]; },
    $: (selector, root = document) => root.querySelector(selector),
    $$: (selector, root = document) => [...root.querySelectorAll(selector)],
    copy: (value) => { effects.copy = textOf(value); },
    clear: () => { effects.clear = true; },
    inspect: (value) => { effects.inspect = value; return value; },
  };
  const commandNames = Object.keys(commandLine);
  // `with` scope for expressions: a name is the API's only if the page has no such global.
  const commandScope = new Proxy(commandLine, {
    has: (target, key) => typeof key === 'string' && commandNames.includes(key) && !(key in window),
    get: (target, key) => (key === Symbol.unscopables ? undefined : Reflect.get(target, key)),
  });
  const installed = [];

  /// Property names for completion: own and prototype chain keys.
  const keysOf = (value) => {
    const names = new Set();
    for (let object = Object(value), depth = 0; object && depth < 20; object = Object.getPrototypeOf(object), depth++) {
      for (const name of safe(() => Object.getOwnPropertyNames(object), [])) names.add(name);
      if (names.size > 3000) break;
    }
    return [...names];
  };

  ub.module('console', () => ({
    /// Start of an expression run; returns the `with` scope. A run whose body never got
    /// here failed to parse, so native retries it as statements.
    begin({ token }) { began.add(token); return commandScope; },
    /// Around every run of typed input (see the error listener).
    running({ on }) { consoleRuns = Math.max(consoleRuns + (on ? 1 : -1), 0); },
    began({ token }) { const did = began.has(token); began.delete(token); return did; },
    /// End of a run: remember $_ and return the preview plus copy()/clear()/inspect() effects.
    finish({ value, error, thrown, live }) {
      const result = {};
      if (live) {
        // Live expressions: no $_ change; copy()/clear()/inspect() effects are dropped.
        for (const key of Object.keys(effects)) delete effects[key];
        return thrown ? { error: ub.preview(error, 0) } : { value: ub.preview(value, 1) };
      }
      if (thrown) {
        result.error = ub.preview(error, 1);
        if (error && error.stack) result.stack = parseStack(error.stack);
      } else {
        lastResult = value;
        result.value = ub.preview(value);
      }
      if ('copy' in effects) result.copy = effects.copy;
      if (effects.clear) result.clear = true;
      if ('inspect' in effects) {
        const target = effects.inspect;
        if (safe(() => target instanceof Node, false)) result.inspect = ub.handle(target);
      }
      for (const key of Object.keys(effects)) delete effects[key];
      return result;
    },
    /// Statements run as a global script, so the API is put on window for its duration
    /// (names the page has are left alone).
    install() {
      statementsRunning = true;
      for (const name of commandNames) {
        if (name in window) continue;
        Object.defineProperty(window, name, { configurable: true, get: () => commandLine[name] });
        installed.push(name);
      }
    },
    uninstall() {
      statementsRunning = false;
      for (const name of installed.splice(0)) delete window[name];
      const result = {};
      if ('copy' in effects) result.copy = effects.copy;
      if (effects.clear) result.clear = true;
      for (const key of Object.keys(effects)) delete effects[key];
      return result;
    },
    /// Elements' selection: becomes $0 (older ones shift to $1…$4).
    select({ handle }) {
      const node = ub.object(handle);
      if (!node) return;
      const index = selection.indexOf(node);
      if (index >= 0) selection.splice(index, 1);
      selection.unshift(node);
      selection.length = Math.min(selection.length, 5);
    },
    /// Completion candidates for `expr.` (a dotted path of names), or globals when empty.
    complete({ expr }) {
      if (!expr) return keysOf(window).concat(commandNames, ['await', 'async', 'function', 'const', 'let', 'var', 'return', 'typeof', 'instanceof', 'new', 'this']);
      const path = expr.split('.');
      let value = safe(() => (commandNames.includes(path[0]) && !(path[0] in window) ? commandLine[path[0]] : window[path[0]]), undefined);
      for (const name of path.slice(1)) {
        if (value === null || value === undefined) return [];
        value = safe(() => value[name], undefined);
      }
      return value === null || value === undefined ? [] : keysOf(value).filter((k) => !/^\d+$/.test(k));
    },
    /// «Сохранить как глобальную переменную»: temp1, temp2, … like Chrome.
    saveGlobal({ handle }) {
      let n = 1;
      while (('temp' + n) in window) n++;
      window['temp' + n] = ub.object(handle);
      return 'temp' + n;
    },
    /// Copy: plain text, or JSON.
    stringify({ handle, json }) {
      const value = ub.object(handle);
      if (!json) return textOf(value);
      return safe(() => JSON.stringify(value, cycleSafe(), 2), undefined) ?? String(value);
    },
  }));
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
  // Spec «Источники»: what this frame loaded, and its text.
  const MAX_SOURCE = 10000000;
  ub.module('sources', () => ({
    /// [{url, kind: 'document'|'script'|'style', inline?}]: this document, its scripts and
    /// stylesheets (inline ones by index), and script/CSS resources from resource timing.
    list() {
      const files = [{ url: location.href, kind: 'document' }];
      const seen = new Set([location.href]);
      const add = (url, kind) => {
        if (!url || seen.has(url) || url.startsWith('data:') || url.startsWith('blob:')) return;
        seen.add(url);
        files.push({ url, kind });
      };
      [...document.scripts].forEach((script, index) => {
        if (script.src) add(script.src, 'script');
        else if (script.textContent.trim()) files.push({ url: location.href, kind: 'script', inline: index });
      });
      [...document.querySelectorAll('style')].forEach((style, index) => {
        if (style.textContent.trim()) files.push({ url: location.href, kind: 'style', inline: index });
      });
      for (const sheet of document.styleSheets) if (sheet.href) add(sheet.href, 'style');
      for (const entry of performance.getEntriesByType('resource')) {
        const path = safe(() => new URL(entry.name).pathname, '');
        if (entry.initiatorType === 'script' || /\.m?js$/.test(path)) add(entry.name, 'script');
        else if (entry.initiatorType === 'css' || /\.css$/.test(path)) add(entry.name, 'style');
      }
      return files;
    },
    /// {text, sourceMap?, truncated?}: an inline script/style, or `url` fetched from the
    /// HTTP cache when possible. Throws when the fetch fails (native retries with URLSession).
    async content({ url, kind, inline }) {
      if (inline !== undefined) {
        const element = (kind === 'style' ? document.querySelectorAll('style') : document.scripts)[inline];
        return { text: element ? element.textContent : '' };
      }
      const response = await fetch(url, { cache: 'force-cache' });
      if (!response.ok) throw new Error('HTTP ' + response.status);
      const text = await response.text();
      const sourceMap = response.headers.get('SourceMap') || response.headers.get('X-SourceMap') || undefined;
      return { text: text.slice(0, MAX_SOURCE), sourceMap, truncated: text.length > MAX_SOURCE };
    },
  }));
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
