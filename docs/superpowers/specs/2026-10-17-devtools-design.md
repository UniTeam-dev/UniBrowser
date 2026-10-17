# Developer tools panel (macOS)

Requirement: a Chrome-style developer panel for the current tab, opened with F12,
with everything Chrome DevTools has that public WebKit API allows, and nothing
that would get the app rejected from the App Store.

## Constraint: public API only

WebKit's own Web Inspector can only be opened from inside an app through private
API (`WKWebView._inspector`, the `developerExtrasEnabled` preference key). App
Review rejects private API (guideline 2.5.1), so the panel is built from:

- one JavaScript file, `devtools.js`, added as a `WKUserScript` at document start
  to **all frames** in the page world (`WKContentWorld.page`);
- a `WKScriptMessageHandler` for messages from it;
- `callAsyncJavaScript(_:arguments:in:in:)` and
  `evaluateJavaScript(_:in:in:)`, aimed at a specific `WKFrameInfo`, for
  requests from the panel;
- `WKHTTPCookieStore`, `WKContentRuleListStore`, `customUserAgent`,
  `pageZoom`/`magnification`, `URLSession`, and the navigation delegate's
  `WKNavigationResponse`.

No code from other browsers is used. One third-party library is bundled:
Acorn (MIT), the JavaScript parser the debugger needs. It ships inside the app
and runs on page code only; nothing executable is downloaded (guideline 2.5.2).

What public API cannot give, and how the panel covers it:

| Chrome feature | Here |
| --- | --- |
| Debugger (breakpoints, stepping, scopes) | Built by instrumenting the page's JavaScript in a per-tab debug mode; see «Отладчик». |
| JS CPU profile | Instrumented function profile in debug mode; see «Производительность». |
| Heap snapshots, memory usage | Not possible: no public API enumerates the JS heap. Not offered. |
| Throttling of images/CSS/scripts | Only fetch/XHR/WebSocket are throttled; Офлайн blocks everything. |
| Touch emulation, device pixel ratio | Not emulated; size and user agent are. |

`webView.isInspectable` stays on (public API, allowed) but nothing in the app
refers to Safari.

## Opening and layout

Menu «Разработка»:

| Item | Key |
| --- | --- |
| Инструменты разработчика (toggle) | F12, ⌥⌘I |
| Консоль JavaScript | ⌥⌘J |
| Выбрать элемент на странице | ⇧⌘C |
| Режим устройства | ⇧⌘M |
| Жёсткая перезагрузка | ⇧⌘R |
| Режим отладки JavaScript (toggle, reloads the page) | ⇧⌘D |

F12 is fn+F12 on Macs where it is a media key, unless "Use F1, F2 as standard
function keys" is on; ⌥⌘I always works.

The panel acts on the selected tab; in Split View each pane has its own. Open or
closed is per tab, like Chrome. A tab going to sleep closes its panel.

Dock: bottom (default), right, or a separate window, switched from the panel's
header menu. The divider is draggable. Dock side and size are remembered in
`UserDefaults` for all tabs. Header: Элементы, Консоль, Источники, Сеть,
Производительность, Приложение, the device-mode toggle, the dock menu and close.

## Frames

Every frame, including cross-origin iframes, runs its own copy of
`devtools.js`. On start it picks a random frame id and posts `hello`; the
native side keeps frame id → latest `WKFrameInfo` from each message, so it can
call back into exactly that frame. To place a child frame in the parent's DOM
tree, each frame does `parent.postMessage({__ubFrame: id}, '*')`; the parent's
script matches `event.source` to one of its `<iframe>` elements' `contentWindow`
and reports iframe element → child frame id. This works cross-origin.

Console, network, sources and storage entries carry their frame; the console's
context menu (top / each frame by URL) picks where input runs.

## Консоль

- All `console` methods: log/info/warn/error/debug, `table` (rendered as a
  table), `group`/`groupCollapsed`/`groupEnd` (indentation, collapsible),
  `time`/`timeEnd`, `count`, `assert`, `trace` (stack), `dir`, `clear`.
- Uncaught errors and unhandled rejections with message, stack and source
  location; the location opens the file in Источники at that line.
- Arguments are previewed by the script into a JSON-safe tree (primitives,
  arrays, plain objects, Map/Set, DOM nodes as `<tag#id.class>`, functions as
  `ƒ name()`, errors with stack), depth 3, 100 keys per level. Objects keep a
  handle id; expanding a node asks the page for the next level.
- Input with history (↑/↓, kept per app in `UserDefaults`, last 100). Code runs
  as an expression first
  (`callAsyncJavaScript("return __ubDevtools.preview(await (CODE))")`, which
  allows top-level `await`); on a syntax error it runs as statements via
  `evaluateJavaScript`. Both bypass page CSP, unlike `eval`.
- Command-line API: `$0`…`$4` (recent selections in Элементы), `$_`, `$()`,
  `$$()`, `copy()`, `clear()`, `inspect()`. `$` and `$$` are defined only if
  the page has not defined them.
- Filter by level and text, Clear, «Сохранять при переходе» (preserve log).

## Элементы

- DOM tree, loaded lazily one level per request: the script keeps id → node
  (Map) and node → id (WeakMap). Shadow roots and iframe documents appear as
  children. A `MutationObserver` reports changes (debounced 300 ms) and the
  panel reloads the affected expanded nodes; changed nodes flash.
- Hover highlights the node on the page (fixed overlay `div`,
  `pointer-events: none`, margin/padding/content colours and size).
- ⇧⌘C picker: highlight under the mouse, click selects (the click does not
  reach the page), Esc cancels; the tree expands to the node.
- Editing: double-click an attribute name/value or text to edit, add
  attribute, «Редактировать как HTML» (outerHTML), delete node (⌫), hide
  (`visibility: hidden` toggle, H), copy selector / outerHTML.
- Side panes for the selected node:
  - **Стили**: inline style and matched rules from readable stylesheets, in
    cascade order with selector and source file:line; each property can be
    toggled, edited, and added. Rules from cross-origin sheets that block
    `cssRules` are listed as unavailable. Edits write to the CSSOM, so they last
    until reload, like Chrome.
  - **Вычисленные**: `getComputedStyle`, filterable, plus the box model
    diagram (margin, border, padding, size).
  - **Обработчики событий**: listeners recorded by wrapping
    `EventTarget.prototype.addEventListener`/`removeEventListener` from document
    start, with the handler's source preview; `on*` properties too.
  - **Свойства**: the node as an expandable object.

## Источники

- Tree by frame → origin → path: external and inline scripts, stylesheets
  (`document.scripts`, `document.styleSheets`, resource timing entries),
  and every frame's document.
- Viewer: line numbers, simple syntax colouring for JS/CSS/HTML, «{ }»
  pretty-print, go to line (⌃G), find in file (⌘F), search in all sources
  (⌥⌘F).
- Content is fetched by the page with `cache: 'force-cache'` (same origin,
  CORS-allowed); if that fails, by native `URLSession` with the tab's cookies and
  user agent, marked «загружено повторно».
- Snippets: named pieces of JS kept in `UserDefaults`, edited here, run in the
  selected frame (⌘↩).

## Сеть

- Sources of entries:
  - `fetch` and `XMLHttpRequest` wrappers: method, URL, status, type, size,
    timing, request headers and body, response headers and body (text up to
    1 MB; binary as size).
  - `WebSocket` wrapper: connection entry with its sent/received frames.
  - Documents (main frame and iframes): status and headers from the navigation
    delegate's `WKNavigationResponse`.
  - Everything else (scripts, styles, images, fonts, media) from
    `PerformanceObserver` resource entries: URL, type, transfer size, timing
    phases. Their headers/status are not exposed by WebKit; the response body is
    loaded on demand the same way as Источники.
- Table: Имя, Метод, Статус, Тип, Инициатор, Размер, Время, Водопад; sort by
  column; filter by text and by type (All, Fetch/XHR, Doc, CSS, JS, Img, Font,
  Media, WS); Clear; «Сохранять при переходе».
- Details: Заголовки, Полезная нагрузка, Ответ (text with pretty-print for
  JSON, image preview), Тайминги, Сообщения (WS); «Копировать как cURL» and
  «Копировать как fetch»; export all as HAR.
- Throttling: Нет, Быстрый 3G, Медленный 3G, Офлайн. 3G presets delay
  fetch/XHR/WebSocket responses by latency plus size ÷ bandwidth. Офлайн adds a
  `WKContentRuleList` that blocks every load for that tab and makes the
  wrappers fail like a network error.
- «Отключить кэш»: fetch/XHR get `cache: 'no-store'`, and reloads use
  `reloadFromOrigin()`.

## Отладчик

Built on source instrumentation, used only when debug mode is on for the tab
(⇧⌘D or the button in Источники). Turning it on or off reloads the page.

**Loading.** In debug mode a main-frame navigation is cancelled in
`decidePolicyFor navigationAction` and redone natively: `URLSession` fetches the
document (GET, or POST with the original body) with the tab's cookies copied
from `httpCookieStore` and its user agent; `Set-Cookie` responses are written
back. The HTML is rewritten and shown with
`loadSimulatedRequest(_:response:responseData:)`, so the page keeps its real
URL, origin, cookies and storage. Rewriting:

- `<script src>` URLs become `ubdbg-https://host/path` (or `ubdbg-http://`),
  so relative module imports resolve inside the scheme. A `WKURLSchemeHandler`
  for both schemes fetches the original, instruments JavaScript, passes other
  types through, and answers with `Access-Control-Allow-Origin: *`.
- Inline scripts and inline `on*` handlers are instrumented in place.
- The page's CSP (header and `<meta>`) is dropped in debug mode, since the
  instrumentation needs `ubdbg-*` loads and direct `eval` for scopes.
- Scripts added later (`script.src`, `setAttribute('src')`, inline
  `textContent`, `import()`) are redirected or instrumented in the page: the
  instrumenter is plain JS (`debugger-runtime.js` with Acorn) that runs both in
  a native `JSContext` and in the page.
- Stack traces, `import.meta.url` and `document.currentScript` show
  `ubdbg-*` URLs; the panel maps them back everywhere it shows a location.

**Instrumentation** (per script, cached by URL + content hash):

- Before every statement: `__ubd.s(id)`; `id` indexes a table of
  line/column ranges. The check is a single typed-array lookup unless a
  breakpoint or step is active.
- Every function body is wrapped to push/pop a shadow call-stack frame
  (function name, script, current statement) and, in a catch-rethrow, report
  exceptions. Each frame registers a scope getter `() => ({a, b, …})` built
  from the statically known bindings of each enclosing scope, and an evaluator
  `(e) => eval(e)` for expressions in that frame.
- `debugger;` statements become pause points.
- `await`/`yield` re-enter their frame on resume, so stepping works across them;
  the stack shows async boundaries like Chrome's "async" separators.

**Pausing.** `__ubd.pause(reason)` sends the pause state (stack, scopes for the
top frame, reason) and then loops on a synchronous `XMLHttpRequest` to
`ubdbg-ctl://wait`. The scheme handler holds each request for up to 10 s and
answers with a command: resume, step over/into/out, evaluate in frame N
(result is sent back and the loop continues), get scope of frame N, or keep
waiting. The page's JavaScript is blocked while paused, as in Chrome; a
«Приостановлено в отладчике ▶︎ ⤼» overlay is shown on the page.

**Features:**

- Line breakpoints (click the gutter), conditional breakpoints, logpoints,
  enable/disable, disable all, a breakpoints list; saved per script URL in
  `UserDefaults` and restored on reload.
- Pause on exceptions: all, or uncaught only (no enclosing instrumented
  `try` on the shadow stack at the throw).
- Event listener breakpoints (by event type, via the listener wrapper), XHR/fetch
  breakpoints (URL contains), DOM breakpoints (subtree modified, attribute
  modified, node removed, via wrapped DOM mutation methods).
- Controls: resume (F8), step over (F10), step into (F11), step out (⇧F11),
  continue to here, deactivate breakpoints.
- Panes: call stack (click to select a frame), scope (local, closure, module,
  global; expandable objects, values editable), watch expressions, and the
  console evaluates in the selected frame while paused.
- Source maps: `//# sourceMappingURL` (or the `SourceMap` header), external or
  inline data URLs. The panel decodes the VLQ mappings itself, shows original
  sources (from `sourcesContent`, or fetched) in Источники under their
  `webpack://`/`file://` paths, sets breakpoints in original files (mapped to
  the nearest generated statement), steps and shows stack locations in original
  positions, and shows original variable names where `names` gives them.
- Pretty-printed debugging for minified files without a source map: the
  instrumenter prints the AST formatted, and debugging runs on that text.

**Limits** (stated in the panel's help popover): pages run several times slower
in debug mode; Web Workers, service workers and code passed to
`eval`/`new Function` are not debugged; iframes debug only scripts they add
dynamically, not their initial HTML; unusual code can behave differently under
instrumentation, which is why it is off by default.

## Производительность

- Record / stop. While recording the script samples `requestAnimationFrame`
  (FPS, frames over 50 ms as long frames), user timing marks and measures, and
  every `PerformanceObserver` entry type WebKit supports
  (`PerformanceObserver.supportedEntryTypes`: paint, largest-contentful-paint,
  event, resource, etc.).
- Result: timeline with the FPS graph, long frames, marks/measures and the
  resource waterfall; zoom by drag; a summary of page load (navigation timing,
  FCP, LCP, DOMContentLoaded, load) when available.
- In debug mode the recording also has a JS profile from the instrumentation's
  function enter/exit timestamps: call tree, bottom-up, and a flame chart, with
  times mapped to original sources. Instrumentation overhead is subtracted per
  call as a measured constant, so numbers are approximate.

## Приложение

- Cookies (domain match for the selected frame's host) from
  `httpCookieStore`: all fields; add, edit, delete, clear all.
- localStorage and sessionStorage per frame origin: add, edit, delete, clear.
- IndexedDB: databases (`indexedDB.databases()`), object stores, first 100
  records per page with paging; delete record, clear store, delete database.
- Cache Storage: caches and their request URLs; delete entry or cache.
- Service workers: registrations with scope and state; Unregister, Update.
- Manifest: the page's web app manifest, parsed.
- «Очистить данные сайта»: removes this site's records from
  `WKWebsiteDataStore`.

## Режим устройства

- Toolbar above the page: preset (iPhone SE, iPhone 15, iPhone 15 Pro Max,
  iPad mini, iPad Pro 11, Pixel 8, Galaxy S23, Адаптивный), width × height,
  rotate, zoom (fit, 50–150%).
- The web view gets that frame inside the page card, centered, scaled with
  `magnification` to fit when needed. Preset user agents go to
  `customUserAgent`; the page reloads when the UA changes.
- Per tab. It stays on until toggled off, even with the panel closed.

## Capture before the panel opens

The script installs its hooks at document start in every frame but keeps
entries in JS ring buffers (500 console, 500 network) and sends nothing.
Opening the panel calls `__ubDevtools.attach()` in each frame, which returns the
buffers and starts streaming; closing calls `detach()`. Logs from page load are
therefore visible, and tabs without an open panel pay no IPC. Request and
response bodies are captured only while attached.

## Code layout

- `UniBrowser/Resources/debugger-runtime.js` — the instrumenter and pause
  runtime, with Acorn (`UniBrowser/Resources/acorn.js`, vendored, MIT licence
  kept).
- `UniBrowser/Resources/devtools.js` — the page script (hooks, previews, DOM
  ids, overlay, picker, CSSOM, storage, perf recording, frame linking), loaded
  from the bundle.
- `UniBrowser/DevTools/`:
  - `DevToolsSession.swift` — per-tab `@Observable` session: frames, message
    routing, `call(frame:_:)` helpers, attach/detach; owns the panel models.
  - `DevToolsView.swift` — dock (bottom/right/window), header, tab switching.
  - `ConsolePanel.swift`, `ElementsPanel.swift`, `SourcesPanel.swift`,
    `NetworkPanel.swift`, `DebuggerPanel.swift`, `DebugLoader.swift` (proxy
    load and scheme handler), `SourceMap.swift`, `PerformancePanel.swift`, `ApplicationPanel.swift`,
    `DeviceMode.swift` — each holds its model and its SwiftUI view.
- Touched: `WebEnvironment` (script, handler), `TabWebController`
  (`decidePolicyFor navigationResponse`, reset on commit), `BrowserTab`
  (`devTools`, device mode, close on sleep), `MainWindow`
  (`TabPane`/`WebViewContainer` host the dock and the device frame),
  `BrowserCommands` (menu).

## Trust

The script runs in the page world, so the page can see the wrappers, call
`__ubDevtools`, and post fake messages. Accepted: messages are only displayed.
Native caps: 2000 console entries, 1000 network entries, 1 MB per body, 2000 DOM
rows per request, 10 MB per source file. Console input and snippets run only
what the user typed. Cookie editing touches only the cookie the user edits.
The JS wrappers keep the original functions' behaviour and `this`; when the
panel is not attached they only append to the ring buffer.

## Verification

No test target exists. A local test page, `scripts/devtools-test/index.html`
served by `python3 -m http.server`, with an iframe from a second port
(cross-origin), logging at each level, `console.table`/`group`, a throw and a
rejection, fetch/XHR/WebSocket (echo server optional), an image, a same-origin
stylesheet, cookies, local/sessionStorage, IndexedDB, a service worker and
`performance.mark`. Each panel is checked against it, plus: F12 toggles, ⇧⌘C
picks inside the iframe, tab switching keeps each tab's panel, navigation
clears unless preserve is on, a sleeping tab drops its panel, Split View panes
are independent, Офлайн blocks loads, device mode resizes and changes UA.
For the debugger the test page adds a small TypeScript bundle built with a
source map: breakpoint in the `.ts` file, step over/into/out, scope values,
watch, conditional breakpoint, logpoint, exception pause, pause inside an
`async` function after `await`. `SourceMap.swift` gets an assert-based
self-check for VLQ decoding against a known mapping.

The first implementation step is a spike that proves the two risky mechanics
before anything else is built: a synchronous XHR from an `https` page to a
`ubdbg-ctl://` scheme handler that is held open (pause), and a module script
graph loaded through `ubdbg-https://` under `loadSimulatedRequest`. If either
fails, the debugger design is revisited with ilja before continuing.
