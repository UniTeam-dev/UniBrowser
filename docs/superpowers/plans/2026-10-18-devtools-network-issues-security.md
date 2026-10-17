# DevTools: Сеть, Проблемы, Безопасность

**Spec:** `docs/superpowers/specs/2026-10-17-devtools-design.md` («Сеть», «Проблемы», «Безопасность»).

## Pieces

- `devtools.js` `#region network`: fetch / XHR / WebSocket wrappers (headers, bodies ≤ 1 MB while
  attached, initiator stack), resource and navigation timing (HAR phases), throttling (events held
  and re-dispatched after latency + size ÷ bandwidth), blocking and no-store from
  `network.configure`, `network.replay`, `network.body`. Every `network` message is an update
  `{id, url, …}` merged natively by frame + id.
- `devtools.js` `#region issues`: CSP violations, mixed content (resource entries, raw http:
  attributes on load/error and a DOM scan, http: form actions), failed element loads, refused
  `document.cookie` writes with a reason, fields without label / autocomplete, ReportingObserver.
- `NetworkData.swift` (Foundation only): entry, cURL / fetch, HAR 1.2 export and import, content
  rule list JSON, JSON pretty-print. Self-check: `scripts/network_check.swift`.
- `NetworkModel.swift`: merge, filters, search, documents from `WKNavigationResponse`, settings
  applied only while the panel is open (`WKContentRuleList` per tab for Офлайн and blocking,
  `reloadFromOrigin` for «Отключить кэш»), replay, body on demand (page cache, then URLSession
  with the tab's cookies and UA), HAR.
- `NetworkPanel.swift`, `NetworkDetails.swift`: table, waterfall, filters, ⌘F search, blocking
  popover, details tabs.
- `IssuesPanel.swift`: issues by kind with links to Сеть / Элементы / Источники; count badge in
  `DevToolsView`'s tab strip.
- `SecurityPanel.swift`: state, `hasOnlySecureContent`, `serverTrust` chain via SecTrust /
  SecCertificate, TLS version and cipher from one HEAD request's metrics, origins from Сеть.

## Shared files

- `TabWebController`: `decidePolicyFor navigationResponse` → `network.navigationResponse`, and a
  main-frame reload check → `network.redirectsReload`.
- `DevToolsView`: the Проблемы count badge.

## Test

`python3 -m http.server <port>` in `scripts/devtools-test`, `python3 ws_echo.py <port>`, open
`network.html?ws=<port>`.
