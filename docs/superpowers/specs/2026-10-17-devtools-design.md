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

What this rules out, and where it goes instead:

| Chrome feature | Here |
| --- | --- |
| Line breakpoints, stepping, scope variables, pause on exceptions | Not possible: WebKit exposes its debugger only through Web Inspector. `webView.isInspectable = true` (public, already on) lets Safari → Разработка → UniBrowser attach its full debugger to any tab. The panel has a menu item explaining this. |
| JS CPU profile, heap snapshots, memory | Same: Safari Web Inspector. |
| Throttling of images/CSS/scripts | Only fetch/XHR/WebSocket are throttled; Offline blocks everything. |
| Touch emulation, device pixel ratio | Not emulated; size and user agent are. |

## Opening and layout

Menu «Разработка»:

| Item | Key |
| --- | --- |
| Инструменты разработчика (toggle) | F12, ⌥⌘I |
| Консоль JavaScript | ⌥⌘J |
| Выбрать элемент на странице | ⇧⌘C |
| Режим устройства | ⇧⌘M |
| Жёсткая перезагрузка | ⇧⌘R |
| Отладка JavaScript в Safari… | — (explains the Safari route) |

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

## Производительность

- Record / stop. While recording the script samples `requestAnimationFrame`
  (FPS, frames over 50 ms as long frames), user timing marks and measures, and
  every `PerformanceObserver` entry type WebKit supports
  (`PerformanceObserver.supportedEntryTypes`: paint, largest-contentful-paint,
  event, resource, etc.).
- Result: timeline with the FPS graph, long frames, marks/measures and the
  resource waterfall; zoom by drag; a summary of page load (navigation timing,
  FCP, LCP, DOMContentLoaded, load) when available.
- No JS call-tree profile (see the constraint table).

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

- `UniBrowser/Resources/devtools.js` — the page script (hooks, previews, DOM
  ids, overlay, picker, CSSOM, storage, perf recording, frame linking), loaded
  from the bundle.
- `UniBrowser/DevTools/`:
  - `DevToolsSession.swift` — per-tab `@Observable` session: frames, message
    routing, `call(frame:_:)` helpers, attach/detach; owns the panel models.
  - `DevToolsView.swift` — dock (bottom/right/window), header, tab switching.
  - `ConsolePanel.swift`, `ElementsPanel.swift`, `SourcesPanel.swift`,
    `NetworkPanel.swift`, `PerformancePanel.swift`, `ApplicationPanel.swift`,
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
