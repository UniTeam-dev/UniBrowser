# Developer tools: how a panel plugs in

Spec: `docs/superpowers/specs/2026-10-17-devtools-design.md`. This page is the contract
between the foundation and the panels. Each panel edits only its own region of
`devtools.js` and its own `UniBrowser/DevTools/<Name>Panel.swift`.

## Pieces

- `UniBrowser/Resources/devtools.js` — one IIFE, injected at document start into every
  frame, page world. Nothing is posted to native until the panel opens, except `hello`.
- `DevTools/DevToolsSession.swift` — one per awake tab (`BrowserTab.devTools`; nil while
  asleep). It is the `ubDevtools` message handler, keeps `frames` (id → `DevToolsFrame`:
  latest `WKFrameInfo`, URL, parent frame id, `<iframe>` handle), routes messages by
  `type`, and owns one model per panel (`session.console`, `session.elements`, …).
- `DevTools/DevToolsView.swift` — `DevToolsDock` (bottom / right / window, used by
  `TabPane`), the header, and the switch from `DevToolsPanel` to the panel view.
- `DevTools/<Name>Panel.swift` — `<Name>Model` (`@Observable`, `bind(_:)`) and
  `<Name>Panel` view. `DeviceMode.swift` is per tab (`BrowserTab.deviceMode`).
- Test page: `scripts/devtools-test/serve.sh`, then open `http://127.0.0.1:8000`
  (iframe from port 8001 = cross-origin). Add your panel's cases to it.

## Adding a JS module

Write inside your `// #region <panel>` … `// #endregion <panel>` block in `devtools.js`
(already there for every panel). The core object is `ub`:

| `ub.…` | What |
| --- | --- |
| `frame` | this frame's id |
| `attached` | true while the panel is open |
| `ring(type, max)` → `{push(payload)}` | buffer while detached (oldest dropped past `max`), stream while attached. Use for anything captured before the panel opens (spec: 500 console, 500 network). |
| `send(type, payload)` | post now if attached, else drop. Use for live-only data (bodies, mutations). |
| `preview(value, depth = 3)` | JSON-safe tree `{type, text, handle?, entries?: [{key, value}], more?}`; 100 keys per level; nodes `<tag#id.class>`, functions `ƒ name()`. |
| `handle(object)` → Int, `object(handle)` | registry so native can refer to page objects (DOM nodes, values). |
| `module(name, factory)` | register functions native can call. |

```js
// #region elements
ub.module('elements', (ub) => ({
  children({ handle }) { /* return JSON-able data */ },
  attach() { /* panel opened: start observers */ },
  detach() { /* panel closed: stop them */ },
}));
// #endregion elements
```

Functions take one object argument and may be `async`. `attach`/`detach` are optional
and run in every frame when the panel opens/closes. Wrappers of page APIs must keep the
original behaviour and `this`, and only push to a ring while detached. Built-in:
`core.expand({handle})` → next level of a preview.

## Adding a message type

JS: `ub.ring('network', 500).push({...})` or `ub.send('mutation', {...})`. Every message
arrives as `{type, frame, ...payload}`.

Swift, in your model's `bind`:

```swift
func bind(_ session: DevToolsSession) {
    session.on("network") { [weak self] message in
        // message.type, message.frame, message["url"] as? String, message.body
    }
}
```

Handlers run on the main actor in arrival order; buffered messages come first when the
panel opens. Values are WebKit-converted (`String`, `NSNumber`/`Int`/`Double`/`Bool`,
`[Any]`, `[String: Any]`, `NSNull`). The page can post anything: trim to the caps in
`DevToolsSession` (`maxConsoleEntries`, `maxNetworkEntries`, `maxBodyBytes`,
`maxDOMRows`, `maxSourceBytes`) and only display what you get. `hello` and `frameLink`
are core messages; you may listen to them too (a `hello` from the main frame means a new
page: `session.frames` was just reset).

## Calling into a frame

```swift
let result = try await session.call(frame: id, "elements.children", args: ["handle": 7])
let all = await session.callAll("application.storage")          // [frameID: result]
let raw = try await session.evaluate("return document.title", frame: session.topFrame!)
```

`call` runs `__ubDevtools.call(name, args)` with `callAsyncJavaScript` in that frame's
`WKFrameInfo`, page world (bypasses page CSP). Errors thrown in JS become Swift errors;
an unknown frame throws `DevToolsSession.CallError.noFrame`. Arguments must be
plist-able (`String`, numbers, `Bool`, arrays, dictionaries).

## Native side, other hooks

- Open/close: `session.open(.console)`, `session.close()`, `session.toggle()`,
  `session.isOpen`, `session.panel`. Menu items live in `BrowserCommands` «Разработка».
- ⇧⌘C calls `session.elements.pick()` (stub in `ElementsPanel.swift`).
- `session.webView` for WebKit API (cookies, `pageZoom`, `takeSnapshot`, …);
  `WebInspector.show(webView)` for the hand-off.
- Settings that belong to one panel live in that panel (e.g. `@AppStorage` with a
  `devTools…` key). The gear popover in `DevToolsView` only has the dock side for now.
