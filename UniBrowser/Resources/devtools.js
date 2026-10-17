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
  // #endregion changes
})();
