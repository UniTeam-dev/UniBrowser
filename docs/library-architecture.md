# Library: history and bookmarks

The shared core of the browser essentials (spec: `docs/superpowers/specs/2026-10-19-browser-essentials-design.md`, part A).
Two stores in `Shared/Library/`, compiled into both apps, plus their sync over the iPhone link.
Parts B–F build UI and features on this API; they don't change the stores' storage or sync.

## Files

| Code | What |
|---|---|
| `Shared/Library/HistoryStore.swift` | `Visit`, `HistoryStore` (SQLite + FTS5), `LibraryFiles` (where files live) |
| `Shared/Library/BookmarkMerge.swift` | `Bookmark` and the pure merge rules (`BookmarkMerge`) |
| `Shared/Library/BookmarkStore.swift` | `BookmarkStore` (`@Observable`, JSON file) |
| `scripts/history_check.swift`, `scripts/bookmark_merge_check.swift` | assert-based checks; run commands in their headers |

Data on disk, all in `Application Support/UniBrowser/` (`LibraryFiles.url(_:)`):

| | Mac | iPhone, «Обычный» | iPhone, «Через Mac» |
|---|---|---|---|
| History | `history.sqlite` | `history-direct.sqlite` | `history-viaMac.sqlite` |
| Bookmarks | `bookmarks.json` | `bookmarks-direct.json` | `bookmarks-viaMac.json` |
| Synced | with its via-Mac phones | never | with the Mac |

## Who owns what

- **Mac:** `AppModel.history` and `AppModel.bookmarks` (one pair for the whole app). `AppModel` sets
  `store.environment.history = history`, prunes history at launch (90 days) and hands both to `ViaMacHost`.
- **iPhone:** each `MobileStore` (one per mode) owns `history: HistoryStore?` and `bookmarks: BookmarkStore`,
  created and pruned in its `init`. Reach them as `model.store.history` / `model.store.bookmarks` for the
  visible mode. `MacRelay` syncs only `model.viaMac`'s pair.

Recording (already wired, don't add more call sites):
- Mac: `TabWebController.webView(_:didFinish:)` → `environment.history?.record(url:title:)`;
  `BrowserTab`'s title observer → `environment.history?.updateTitle(url:title:)`.
- iPhone: `MobileTabController.webView(_:didFinish:)` → `environment.store?.history?.record`;
  `MobileTab`'s title observer → `updateTitle`.
- Only `http`/`https` are recorded (`HistoryStore.isRecordable`), so `about:`, `data:`, `blob:`, `file:` never are;
  failed loads never reach `didFinish`.

## HistoryStore

`@MainActor @Observable final class HistoryStore` — synchronous; every call is well under a millisecond at
browser-history sizes. Observe `revision` (bumped on every change) to know when to query again.

```swift
struct Visit: Codable, Sendable, Identifiable, Hashable {
    var id: UUID; var url: URL; var title: String; var visitedAt: Date; var deviceID: String
    var host: String          // url.host() ?? ""
}

init(fileURL: URL?, deviceID: String)             // nil file = in memory
func record(url: URL, title: String, at: Date = .now)
    // same URL on this device within 30 min moves that visit to `at` (and takes a non-empty title)
func updateTitle(url: URL, title: String)        // latest visit of url on this device
func search(_ query: String, limit: Int) -> [Visit]
    // FTS5 prefix match on every word over title + URL, newest first, one row per URL;
    // "" → most recent pages (one per URL); punctuation-only → []
func visits(on day: Date) -> [Visit]             // that local day, newest first, every visit
func days(limit: Int) -> [Date]                  // local start-of-days that have visits, newest first
func visits(since: Date) -> [Visit]              // after `since`, OLDEST first (sync uses it)
func delete(ids: [UUID])
func delete(host: String)                        // the host and its subdomains
func delete(since: Date)                         // «последний час», «сегодня»… : delete(since: start)
func deleteAll()
func prune(olderThan days: Int = 90)             // part F's retention setting passes its value
func merge(_ remote: [Visit])                    // sync: insert by id; a known id takes a later time/title
private(set) var revision: Int
```

Day sections («Сегодня», «Вчера», dates): `days(limit:)` then `visits(on:)` per day; for a search, `search(_:limit:)`.

## BookmarkStore

`@MainActor @Observable final class BookmarkStore` — views reading `children(of:)` etc. update by themselves.
Every edit is saved at once and fires `onLocalChange` (the link uses it; parts B–F leave it alone).

```swift
struct Bookmark: Codable, Sendable, Identifiable, Hashable {
    var id: UUID; var parentID: UUID?   // folder; nil = root
    var title: String; var url: URL?    // nil = folder
    var order: Double; var modifiedAt: Date; var deleted: Bool   // tombstone, kept 30 days
    var isFolder: Bool
}

init(fileURL: URL?)                                   // nil file = in memory
private(set) var all: [Bookmark]                      // everything, tombstones included — not for display
func children(of parentID: UUID?) -> [Bookmark]       // live items, in order (root also shows orphans)
func bookmark(for url: URL) -> Bookmark?              // the ☆ state; nil = not bookmarked
func search(_ query: String) -> [Bookmark]            // bookmarks (not folders), title or URL contains
@discardableResult func add(url: URL, title: String, in parentID: UUID? = nil) -> Bookmark   // appended last
@discardableResult func addFolder(title: String, in parentID: UUID? = nil) -> Bookmark
func rename(_ id: UUID, to title: String)
func move(_ id: UUID, to parentID: UUID?, at index: Int)   // index among the folder's items without it;
                                                           // a folder into its own subtree is ignored
func delete(_ id: UUID)                                    // a folder takes its subtree along
@discardableResult func merge(_ remote: [Bookmark]) -> Bool   // sync only
```

Never filter `all` yourself for display: use `children(of:)`, `bookmark(for:)` and `search(_:)`, which skip tombstones.
Changing a bookmark's URL isn't in the API; delete and add if ever needed.

## Sync (via-Mac mode only)

ALPN is `unibrowser/via-mac/2`. The Mac also accepts `…/1` only to answer «Обновите UniBrowser на iPhone…»
(old phones show it on their pairing screen); a new phone that meets an old Mac probes `…/1` after a quick
refusal and shows «Обновите UniBrowser на Mac…» in the via-Mac banner (`ViaMacError.outdatedMac`).

`SyncMessage` additions:
- `hello(…, bookmarks:)` — the phone's whole bookmark list. The Mac merges it, broadcasts to its other phones
  if anything changed, and always answers with `bookmarks(all)` after `session` and `passwords`.
- `bookmarks([Bookmark])` — either way, the whole list after any local edit. The receiver `merge`s; if its result
  differs from what it got, it sends its own list back (ties on `modifiedAt` are broken by content, so this stops
  after one round). The Mac also forwards changes to its other phones.
- `history([Visit])` — every 5 s while connected, visits since the last batch sent to that peer (≤ 500 a frame).
  Cursor: `UserDefaults` `viaMac.historySent.<peer id>` (Mac: per phone endpoint id; phone: per Mac id).
  The phone sends only its own visits; the Mac sends all (so one phone's visits reach the others).

Not synced, on purpose: history deletions (deleting on one device leaves the other's copy) and anything of the
iPhone's normal mode. «Стереть данные режима» on the iPhone also clears its via-Mac history locally.

Known limits: a visit merged on the Mac with a `visitedAt` older than another phone's cursor (a phone that was
offline for a long time) doesn't reach that other phone; bookmark tombstones older than 30 days are dropped, so
a device offline longer than that can bring a deleted bookmark back.

## How parts B–F hook in

- **B (Mac UI):** read `model.history` / `model.bookmarks` from `AppModel`. ☆ / ⌘D: `bookmark(for:)`, `add`,
  `rename`, `move`, `delete`. History window: `days` + `visits(on:)`, `search`, `delete(ids:)`, `delete(host:)`,
  «Очистить историю…» → `delete(since:)` / `deleteAll()`; observe `revision`. Bookmarks window: `children(of:)`,
  `addFolder`, `move`, `rename`, `delete`. ⌘K: `search(_:limit: 5)` and `bookmarks.search(_:).prefix(5)`.
- **C (iPhone UI):** `model.store.bookmarks` / `model.store.history` (the visible mode; `history` is optional).
  Same calls as B.
- **D (basics):** «Недавно закрытые» comes from the session archive, not from history. No store changes needed.
- **E (privacy):** a private mode must **not** use any of these stores: not `AppModel.history`, not
  `AppModel.bookmarks`' recording path, not `history-*.sqlite`. Mac private window: give its `WebEnvironment`
  `history = nil` (the default) so nothing is recorded. iPhone `.private` mode: its `MobileStore` gets
  `history = nil` (extend the `init`; `HistoryStore?` exists for this) and in-memory or the normal mode's
  bookmarks (adding a bookmark from a private tab is fine; recording visits is not). «Очистить данные» in
  settings uses `deleteAll()` / `delete(since:)`.
- **F (convenience):** retention setting → `history.prune(olderThan: days)` at launch instead of the default 90
  (`AppModel.init` on the Mac, `MobileStore.init` on the iPhone). Import from Chrome/Safari → `history.merge` with
  visits stamped with this device's `deviceID` (Mac: `BrowserStore.deviceID`) and `bookmarks.add`/`addFolder`.
  Imported visits are older than a paired phone's history cursor, so they reach only phones paired later
  (the same known limit as above); imported bookmarks sync like any edit.
