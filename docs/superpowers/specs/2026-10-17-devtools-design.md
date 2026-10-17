# Developer tools panel (macOS)

Requirement: a Chrome-style developer panel for the current tab, opened with F12,
that stays App Store-safe.

## Constraint: no private API

WebKit's own Web Inspector can only be opened from inside an app through private
API (`WKWebView._inspector`, the `developerExtrasEnabled` preference key). App
Store review rejects private API, so the panel is built from public API only:

- one user script in the page world (`WKContentWorld.page`), added at document
  start to the main frame only;
- a `WKScriptMessageHandler` for messages from that script;
- `evaluateJavaScript` / `callAsyncJavaScript` for requests from the panel;
- `WKHTTPCookieStore` for cookies.

`webView.isInspectable = true` stays as it is, so Safari's Develop menu remains
the escape hatch for what the panel cannot do (breakpoints, profiling).

## What the user gets

**Opening.** Menu «Разработка»:

| Item | Key |
| --- | --- |
| Инструменты разработчика (toggle) | F12, ⌥⌘I |
| Консоль JavaScript | ⌥⌘J |
| Выбрать элемент на странице | ⇧⌘C |

On Macs where F12 is a media key, it is fn+F12 unless "Use F1, F2 as standard
function keys" is on; ⌥⌘I always works.

The panel acts on the selected tab. In Split View each pane has its own panel.
Open/closed is per tab, like Chrome. A tab going to sleep closes its panel.

**Layout.** Docked inside the page card, at the bottom by default; a button
moves it to the right side. The divider is draggable; dock side and size are
remembered in `UserDefaults` for all tabs. The header has tabs Элементы /
Консоль / Сеть / Хранилище and a close button.

**Консоль.**
- `console.log/info/warn/error/debug`, uncaught errors (`error` event) and
  unhandled promise rejections, with level colour, time and source location for
  errors.
- Arguments are previewed by the script into a JSON-safe tree (primitives,
  arrays, plain objects, DOM nodes as `<tag#id.class>`, functions as
  `ƒ name()`), depth 3, 100 keys per object; objects expand in the panel.
- Input line with history (↑/↓). Code runs as an expression first
  (`callAsyncJavaScript("return __ubDevtools.preview(await (CODE))")`, which
  also allows top-level `await`); if that is a syntax error it runs as
  statements via `evaluateJavaScript`, showing the raw completion value.
  Both bypass the page's CSP, unlike `eval`.
- `$0` is the element selected in Элементы.
- Filter by level and text; Clear. Cleared on navigation (no "preserve log").

**Элементы.**
- DOM tree, loaded lazily: the script assigns node ids (Map id → node, WeakMap
  node → id) and returns one level of children per request
  (tag, attributes, child count, short text for text nodes).
- Hovering a row highlights the node on the page (a fixed-position overlay
  `div` with `pointer-events: none`, showing size in px).
- Selecting a node shows its computed styles (filterable list) and box size.
- ⇧⌘C picker: the page highlights the element under the mouse; a click selects
  it (the click does not reach the page) and the tree expands to it; Esc cancels.
- A `MutationObserver` posts "dom changed" debounced 500 ms; the panel reloads
  the expanded nodes.
- Read-only in this version: no editing attributes, text or styles.

**Сеть.**
- `fetch` and `XMLHttpRequest` are wrapped: method, URL, status, type, size,
  duration, request and response headers, and the response body as text when it
  is text-like, capped at 256 KB.
- Everything else (document, scripts, styles, images, fonts) comes from
  `PerformanceObserver` resource entries: URL, type, transfer size, duration.
  WebKit gives no status or headers for these. Entries with initiator `fetch`
  or `xmlhttprequest` are skipped there, since the wrappers already have them.
- Table: Имя, Метод, Статус, Тип, Размер, Время; filter by text and type; Clear.
  Selecting a row shows headers and response.
- Cleared on navigation.

**Хранилище.**
- Cookies for the page's host (domain match), from `httpCookieStore`: name,
  value, domain, path, expiry, Secure, HttpOnly; delete one.
- `localStorage` and `sessionStorage`: key, value; delete one key; clear all.
- Refresh button. Read and delete only, no editing.

## Capture before the panel opens

The script hooks console, errors, fetch/XHR and resource timing from document
start in every tab, but keeps entries in JS ring buffers (500 console, 500
network) and sends nothing. Opening the panel calls `__ubDevtools.attach()`,
which returns the buffers and starts streaming new entries to the handler;
closing calls `detach()`. So logs from page load are visible, like Chrome, and
tabs without an open panel pay no IPC. Response bodies are captured only while
attached.

## Code layout

New folder `UniBrowser/DevTools/`:

- `DevToolsScript.swift` — the JS source and handler name.
- `DevToolsSession.swift` — `@Observable` per-tab model: console entries,
  network entries, DOM nodes, storage rows, selected panel; handles script
  messages and calls into the page.
- `DevToolsView.swift` — the docked panel, header and the four panels.

Touched: `WebEnvironment` (add the script and handler), `BrowserTab`
(`devTools: DevToolsSession?`, closed on sleep and reset on navigation via
`TabWebController.didCommit`), `MainWindow.TabPane` (dock the panel next to the
web view), `BrowserCommands` (menu), `AppModel` if needed for the dock
preference.

## Trust

The script runs in the page world, so the page can see the wrapped
`console`/`fetch`, call `__ubDevtools`, and post fake messages. That is accepted:
messages are only displayed, never acted on. The native side caps every buffer
(1000 console, 500 network, 256 KB per body, 2000 DOM rows per request) so a
hostile page cannot grow memory without bound. Console input runs only what the
user typed.

## Not in this version

Breakpoints and a debugger, Sources, Performance/profiling, iframes (main frame
only), editing DOM/CSS/storage, device emulation, network throttling, response
bodies of non-fetch/XHR resources. Safari's Develop menu covers the first ones.

## Verification

No test target exists. A local test page (`python3 -m http.server`) that logs
at each level, throws, rejects a promise, does fetch and XHR, loads an image and
writes cookies and storage. Check each panel against it, plus: F12 toggles,
⇧⌘C picks, switching tabs keeps each tab's panel, navigation clears console and
network, a sleeping tab drops its panel, Split View panes are independent.
