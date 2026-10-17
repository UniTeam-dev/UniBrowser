# Developer tools panel (macOS)

Requirement: a Chrome-style developer panel for the current tab, opened with F12,
with everything Chrome DevTools has, drawn by us so it is comfortable to use.

Revised 2026-10-18: the Mac app is distributed from the website only (no App
Store, no sandbox), so private WebKit API is allowed. The panel is still our own
GUI built on a page script plus WebKit API; WebKit's own Web Inspector
(`Web/WebInspector.swift`, private `_inspector`) covers what a page script cannot
do well, and the panel hands off to it in one click.

## Approach

Our panel is built from:

- one JavaScript file, `devtools.js`, added as a `WKUserScript` at document start
  to **all frames** in the page world (`WKContentWorld.page`);
- a `WKScriptMessageHandler` for messages from it;
- `callAsyncJavaScript(_:arguments:in:in:)` and
  `evaluateJavaScript(_:in:in:)`, aimed at a specific `WKFrameInfo`, for
  requests from the panel;
- `WKHTTPCookieStore`, `WKContentRuleListStore`, `customUserAgent`,
  `pageZoom`/`magnification`, `URLSession`, `serverTrust`, `appearance`,
  `WKWebpagePreferences`, and the navigation delegate's `WKNavigationResponse`.

WebKit's Web Inspector (private API, already in `WebInspector.swift`) is opened
from the panel header button «Web Inspector», the menu (⌥⌘U) and the page's
context menu «Проверить элемент». It is the place for:

| Chrome feature | Where |
| --- | --- |
| Debugger (breakpoints, stepping, scopes, watch, source maps) | Web Inspector → Sources. Our Источники has «Отладить в Web Inspector» on every file and line. |
| JS CPU profile, flame chart | Web Inspector → Timelines. Our Производительность links to it. |
| Heap snapshots, memory usage | Web Inspector → Timelines (Memory, JavaScript Allocations). |
| Paint flashing, layer borders, compositing layers | Web Inspector → Layers / Elements settings. |

Not offered anywhere (WebKit has no such feature): CPU throttling, real touch
and device-pixel-ratio emulation, Lighthouse. Not planned: Recorder and Local
Overrides (rarely used; Overrides would rewrite files from disk).

No code from other browsers is used and nothing executable is downloaded.

## Opening and layout

Menu «Разработка»:

| Item | Key |
| --- | --- |
| Инструменты разработчика (toggle) | F12, ⌥⌘I |
| Консоль JavaScript | ⌥⌘J |
| Выбрать элемент на странице | ⇧⌘C |
| Режим устройства | ⇧⌘M |
| Жёсткая перезагрузка | ⇧⌘R |
| Web Inspector | ⌥⌘U |
| Командное меню панели (when the panel has focus) | ⇧⌘P |

F12 is fn+F12 on Macs where it is a media key, unless "Use F1, F2 as standard
function keys" is on; ⌥⌘I always works.

The panel acts on the selected tab; in Split View each pane has its own. Open or
closed is per tab, like Chrome. A tab going to sleep closes its panel.

Dock: bottom (default), right, or a separate window, switched from the panel's
header menu. The divider is draggable. Dock side and size are remembered in
`UserDefaults` for all tabs. Header: Элементы, Консоль, Источники, Сеть,
Производительность, Приложение, Рендеринг, Проблемы, Безопасность, Покрытие,
Изменения (tabs that don't fit go into a «»» overflow menu, reorderable by drag
like Chrome), the device-mode toggle, «Web Inspector», settings, the dock menu
and close. The panel follows the app's light/dark theme. Settings (gear):
console timestamps, group similar messages, preserve log defaults, disable
cache default, dock side, font size.

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
- Autocomplete while typing: property and method names of the expression before
  the dot (asked from the page: own and prototype keys), globals, command-line
  API; Tab/→ accepts. ⇧↩ inserts a new line, ↩ runs once brackets balance.
- Live expressions (eye button): pinned expressions re-evaluated every 250 ms
  while the panel is visible.
- Context menu on a value: «Сохранить как глобальную переменную» (`temp1`,
  `temp2`, …), copy value, copy as JSON; on a message: copy, «Скрыть сообщения
  из этого источника».
- Settings: timestamps, group identical consecutive messages (count badge).

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
  - **Layout**: every grid and flex container on the page with a toggle each;
    on draws an overlay with grid lines, track sizes, areas, and flex
    item/gap outlines.
  - **Доступность**: role, accessible name and description computed in the
    page from ARIA attributes, labels, `alt`, text content; the ancestor chain
    of roles.
- Search in the tree (⌘F): text, CSS selector or XPath, with match count and
  next/previous.
- Drag a node to move it in the tree.
- Force state: `:hover`, `:active`, `:focus`, `:focus-visible`,
  `:focus-within`, `:visited` for the selected node. Done by cloning every
  matching rule with the pseudo-class replaced by a `[data-ub-force-hover]`
  attribute selector into a panel stylesheet, and setting that attribute.
- In Стили: colour swatch with a picker (`NSColorPanel`) including its
  eyedropper; a `.cls` editor for classes; «+» new rule for the selected node.
- Node context menu also: «Прокрутить к элементу», «Снимок узла» (`takeSnapshot`
  with the node's rect, saved via a save panel), «Сохранить как глобальную
  переменную», break on (subtree/attribute/removal) opens Web Inspector with that
  DOM breakpoint where possible, otherwise is not shown.

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
- Source maps: `//# sourceMappingURL` (or the `SourceMap` header), external or
  inline data URLs. Original sources (from `sourcesContent`, or fetched) are
  listed under their `webpack://`/`file://` paths and console/network locations
  map to them. `SourceMap.swift` decodes VLQ.
- «Отладить в Web Inspector» on a file and on a gutter line opens Web Inspector
  on that resource.

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
- Search in all requests (⌘F in the panel): URLs, headers and captured bodies.
- Filters also: status (2xx … 5xx, failed), domain, «Скрыть data: URL»,
  «Только сторонние».
- Request blocking: URL patterns with `*`, toggled each; applied as a
  `WKContentRuleList` for that tab and by the fetch/XHR wrappers. «Заблокировать
  URL» / «Заблокировать домен» in a request's context menu.
- «Повторить запрос» for fetch/XHR entries (re-sent from the frame with the
  same method, headers and body).
- Import HAR (shown read-only in the table).

## Производительность

- Record / stop. While recording the script samples `requestAnimationFrame`
  (FPS, frames over 50 ms as long frames), user timing marks and measures, and
  every `PerformanceObserver` entry type WebKit supports
  (`PerformanceObserver.supportedEntryTypes`: paint, largest-contentful-paint,
  event, resource, etc.).
- Result: timeline with the FPS graph, long frames, marks/measures and the
  resource waterfall; zoom by drag; a summary of page load (navigation timing,
  FCP, LCP, DOMContentLoaded, load) when available.
- «Профиль JavaScript и память в Web Inspector» button opens its Timelines.

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
- Хранилище: usage and quota from `navigator.storage.estimate()` and
  `persisted()` per origin.
- Фреймы: tree of frames with URL, origin, secure context, cross-origin
  isolation.

## Режим устройства

- Toolbar above the page: preset (iPhone SE, iPhone 15, iPhone 15 Pro Max,
  iPad mini, iPad Pro 11, Pixel 8, Galaxy S23, Адаптивный), width × height,
  rotate, zoom (fit, 50–150%).
- The web view gets that frame inside the page card, centered, scaled with
  `magnification` to fit when needed. Preset user agents go to
  `customUserAgent`; the page reloads when the UA changes.
- Per tab. It stays on until toggled off, even with the panel closed.

## Рендеринг

Per tab, kept until turned off or the tab closes:

- `prefers-color-scheme`: light/dark via `webView.appearance`
  (`NSAppearance` aqua/darkAqua).
- `prefers-reduced-motion`, `prefers-contrast`, media type `print`: matching
  `@media` rules in readable stylesheets are rewritten into always-on/off copies
  in a panel stylesheet; `matchMedia` is wrapped to answer accordingly.
- Vision deficiency: blurred vision, protanopia, deuteranopia, tritanopia,
  achromatopsia, as an SVG filter on `document.documentElement`.
- Disable JavaScript: `WKWebpagePreferences.allowsContentJavaScript = false`,
  page reloads.
- Geolocation override (lat/long presets and custom, or «Позиция недоступна»),
  timezone and locale override: wrappers for `navigator.geolocation`, `Date`,
  `Intl.DateTimeFormat`, `navigator.language(s)` installed at document start.

## Проблемы

- CSP violations (`securitypolicyviolation` events), mixed content (`http:`
  subresources on `https:` pages, from resource entries), failed resource loads,
  cookies rejected for SameSite (`document.cookie` writes that don't stick),
  form fields without labels/autocomplete, deprecated APIs reported by WebKit
  `ReportingObserver`. Each issue has a description, the affected resource and a
  link into Элементы/Сеть/Источники. Count badge on the tab.

## Безопасность

- Main origin: secure or not, `hasOnlySecureContent`, certificate chain from
  `serverTrust` (subject, issuer, validity, SANs, SHA-256), TLS details shown
  with `SecTrust` API. List of origins seen in Сеть with their scheme and mixed
  content status.

## Покрытие

- Record: CSS rules are marked used if their selector matches anything during
  the recording (checked on start, every mutation batch, and stop); per
  stylesheet used/unused bytes, and Источники shows unused lines with a red bar.
  JS coverage is not offered (no WebKit hook without instrumenting pages).

## Изменения

- Every edit made from the panel (style properties, rules, attributes, text,
  HTML, deleted/moved nodes) is listed per resource as a diff; «Отменить» on an
  entry reverts it, «Копировать» copies the changed CSS.

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
    `NetworkPanel.swift`, `SourceMap.swift`, `PerformancePanel.swift`,
    `ApplicationPanel.swift`, `DeviceMode.swift`, `RenderingPanel.swift`,
    `IssuesPanel.swift`, `SecurityPanel.swift`, `CoveragePanel.swift`,
    `ChangesPanel.swift` — each holds its model and its SwiftUI view.
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
The test page also has a small bundle with a source map (original files shown in
Источники), a CSP that blocks one inline script (Проблемы), grid and flex
layouts, a `:hover` rule, and an `http:` image (mixed content). «Web Inspector»
opens on the right tab and resource. `SourceMap.swift` gets an assert-based
self-check for VLQ decoding against a known mapping.
