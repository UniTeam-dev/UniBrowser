# DevTools Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The shared base every DevTools panel builds on: page script core, per-tab session, dock UI with panel stubs, hosting, menu, test page, and a contract doc; proven by console messages (before and after opening, main frame and cross-origin iframe) showing in the Console stub.

**Architecture:** `devtools.js` runs at document start in every frame (page world), buffers entries in rings and streams them only after `attach()`. `DevToolsSession` (per tab, created on wake, dropped on sleep) is the script message handler, keeps frame id → `WKFrameInfo`, routes messages by `type` to panel models, and calls named JS functions in a given frame via `callAsyncJavaScript`. `DevToolsDock` wraps the web view in `TabPane` and shows `DevToolsView` bottom/right or in its own window.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, WebKit, XcodeGen, plain JS.

**Spec:** `docs/superpowers/specs/2026-10-17-devtools-design.md`

## Global Constraints

- macOS 15.4+, Swift 6 strict concurrency, UI types `@MainActor`; build `NO_OPEN=1 scripts/build.sh` with zero errors.
- UI strings in Russian; panel follows the app's light/dark theme.
- Ring buffers: 500 console, 500 network; native caps: 2000 console, 1000 network, 1 MB body, 2000 DOM rows, 10 MB source.
- Previews: depth 3, 100 keys per level, DOM nodes `<tag#id.class>`, functions `ƒ name()`.
- Frame linking: `parent.postMessage({__ubFrame: id}, '*')`, parent matches `event.source` to an iframe's `contentWindow`.
- In `MainWindow.swift` touch only `TabPane`/`WebViewContainer`; no Claude/AI mentions in commits.

## Review Focus

- Page logs before the panel opens → shown on open, in order, once (no duplicates on reopen): attach drains the ring.
- Cross-origin iframe → its own frame id, its logs routed with its `WKFrameInfo`; verified on the test page with two ports.
- Navigation while open → new frames say `hello` and are attached at once; old main-frame ids dropped.
- Tab sleeps with the panel in a separate window → window closes, session gone.
- Page overrides `console.log` / `window.__ubDevtools` → wrapper keeps original behaviour; `__ubDevtools` is non-writable.

---

### Task 1: devtools.js core + console capture module

**Files:** Create `UniBrowser/Resources/devtools.js`

**Produces (JS, inside one IIFE; `ub` is the local core object):**
- `ub.frame` (random id), `ub.send(type, payload)` (posts `{type, frame, ...payload}` only while attached),
- `ub.ring(type, max)` → `{ push(payload) }` (streams when attached, else buffers),
- `ub.preview(value, depth = 3)` → `{type, text, handle?, entries?: [{key, value}], more?}`, `ub.handle(obj)` → Int, `ub.object(handle)`,
- `ub.module(name, factory)`; factory `(ub) => ({fnName(args) {...}, attach?(), detach?()})`; native calls `"name.fnName"`.
- Global `window.__ubDevtools = {call(name, args), attach(), detach()}` (non-writable, non-configurable); `attach()` returns buffered messages array.
- Core functions: `core.expand({handle})` → next-level entries.
- Messages: `hello {url, isTop}`, `frameLink {child, element}`, `console {level, args: [preview], time}`.
- One `// #region <panel>` … `// #endregion <panel>` block per panel so agents never touch each other's lines.

- [ ] Step 1: write core + console module (log/info/warn/error/debug wrappers keep `this` and return value).
- [ ] Step 2: `node --check UniBrowser/Resources/devtools.js` passes; quick node self-check of `preview` via a stubbed `window` not needed — the smoke test covers it.

### Task 2: DevToolsSession + panel stubs + DevToolsView + hosting

**Files:** Create `UniBrowser/DevTools/DevToolsSession.swift`, `DevToolsView.swift`, `ConsolePanel.swift`, `ElementsPanel.swift`, `SourcesPanel.swift`, `NetworkPanel.swift`, `PerformancePanel.swift`, `ApplicationPanel.swift`, `RenderingPanel.swift`, `IssuesPanel.swift`, `SecurityPanel.swift`, `CoveragePanel.swift`, `ChangesPanel.swift`, `DeviceMode.swift`. Modify `WebEnvironment.swift` (script + handler), `BrowserTab.swift` (`devTools`, `deviceMode`, close on sleep), `MainWindow.swift` (`TabPane` only).

**Produces (Swift):**
- `final class DevToolsSession: NSObject, WKScriptMessageHandler` (`@MainActor @Observable`): `static let handlerName = "ubDevtools"`, `static let script: WKUserScript`, `weak var webView`, `var frames: [String: DevToolsFrame]`, `var isOpen`, `var panel: DevToolsPanel`, `func open(_ panel: DevToolsPanel? = nil)`, `func close()`, `func toggle()`, `func on(_ type: String, _ handler: @escaping (DevToolsMessage) -> Void)`, `func call(frame: String, _ name: String, args: [String: Any] = [:]) async throws -> Any?`, `func callAll(_ name:args:)`, caps `static let maxConsoleEntries = 2000` etc.; models `let console = ConsoleModel()` … one per panel, each `bind(_ session:)`.
- `struct DevToolsMessage { type, frame, body: [String: Any] }`, `struct DevToolsFrame { info: WKFrameInfo; parent: String?; element: Int? }`.
- `enum DevToolsPanel: String, CaseIterable` with Russian `title`; `enum DevToolsDockSide: String { bottom, right, window }`.
- `struct DevToolsDock<Content: View>: View` (used by `TabPane`), `struct DevToolsView: View`.

- [ ] Step 1: write the files; `ConsoleModel` keeps plain-text rows (`level`, `text`, `frame`), capped at 2000.
- [ ] Step 2: `NO_OPEN=1 scripts/build.sh` → `BUILD SUCCEEDED`.

### Task 3: Menu, test page, contract doc, smoke test

**Files:** Modify `BrowserCommands.swift` («Разработка» only), `AppModel.swift` (F12 in the key monitor, since one menu item has one shortcut). Create `scripts/devtools-test/{index.html,frame.html,serve.sh}`, `docs/devtools-architecture.md`.

- [ ] Step 1: menu per spec table: ⌥⌘I toggle (F12 via monitor), ⌥⌘J console, ⇧⌘C picker stub (opens Элементы, `elements.pick()`), ⇧⌘M device mode stub, ⇧⌘R `reloadFromOrigin()`, ⌥⌘U Web Inspector.
- [ ] Step 2: build; run `scripts/devtools-test/serve.sh`, open `http://localhost:8000`, wait, press ⌥⌘I: Console shows load logs from both frames; click «Лог» buttons in both frames: new rows appear.
- [ ] Step 3: commit.
