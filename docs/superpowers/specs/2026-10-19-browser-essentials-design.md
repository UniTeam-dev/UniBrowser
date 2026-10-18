# Browser essentials: history, bookmarks and the rest (Mac + iPhone)

Requirement (ilja, 2026-10-19): make UniBrowser a complete browser. Visit history
and bookmarks, synced between the Mac and the iPhone, plus find in page,
downloads, reopen closed tab, per-site zoom, site permissions, private browsing,
ad and tracker blocking, search engine choice with suggestions, import from
Chrome/Safari, reader mode, print/PDF, tab mute, and one settings screen.
Everything fits the existing model (spaces, folders, pinned tabs, ⌘K palette,
archive); no Chrome-style bookmarks bar.

Platforms: Mac app (website-only, private WebKit allowed) and iPhone app (App
Store, public API only). UI strings Russian.

The work is split into parts. **A** is the shared core and lands first; **B–F**
then run in parallel, each touching its own files.

## A. Core: stores and sync (`Shared/Library/`, compiled into both apps)

### History

- `HistoryStore` (`Shared/Library/HistoryStore.swift`): SQLite through the
  system `libsqlite3` (`import SQLite3`), one file per profile
  (`Application Support/UniBrowser/history.sqlite`; iPhone: one per browsing
  mode, `history-direct.sqlite` / `history-viaMac.sqlite`; private mode: none).
- Table `visits(id TEXT PRIMARY KEY, url TEXT, title TEXT, host TEXT,
  visitedAt REAL, deviceID TEXT)` plus an FTS5 table over title + url.
  A visit is recorded on main-frame `didFinish` (not for `about:`, `data:`,
  `blob:`, `file:` or error pages); the same URL within 30 minutes updates the
  existing visit's time and title instead of adding a row.
- API (all `@MainActor`, synchronous, it is fast enough at this size):
  `record(url:title:)`, `updateTitle(url:title:)`,
  `search(_ query: String, limit: Int) -> [Visit]` (FTS prefix match, newest
  first, one row per URL), `visits(on day: Date) -> [Visit]`,
  `days(limit:) -> [Date]`, `delete(ids:)`, `delete(host:)`,
  `delete(since: Date)`, `deleteAll()`, `visits(since: Date) -> [Visit]` (for
  sync), `merge(_ remote: [Visit])` (insert-or-ignore by id),
  `prune(olderThan days: Int)` (default 90, run at launch).
- `Visit: Codable, Sendable, Identifiable, Hashable { id: UUID, url: URL,
  title: String, visitedAt: Date, deviceID: String }`.

### Bookmarks

- `BookmarkStore` (`Shared/Library/BookmarkStore.swift`), JSON file
  `bookmarks.json` next to the session (iPhone: per mode).
- `Bookmark: Codable, Sendable, Identifiable, Hashable { id: UUID,
  parentID: UUID? (folder; nil = root), title: String, url: URL? (nil = folder),
  order: Double, modifiedAt: Date, deleted: Bool }` — folders and bookmarks in
  one flat list; `deleted` is a tombstone kept 30 days so deletions sync.
- API: `children(of: UUID?) -> [Bookmark]`, `bookmark(for url: URL) -> Bookmark?`,
  `add(url:title:in:)`, `addFolder(title:in:)`, `rename`, `move(_:to:at:)`,
  `delete(_:)` (folder deletes its subtree), `search(_:) -> [Bookmark]`,
  `all` (including tombstones, for sync), `merge(_ remote: [Bookmark])`
  (per id, later `modifiedAt` wins), `@Observable` so views update.
- Pure merge logic lives in `BookmarkMerge.swift` with an assert-based check
  `scripts/bookmark_merge_check.swift`; history store gets
  `scripts/history_check.swift` (temp DB: record, dedupe window, search,
  delete by host/period, merge, prune).

### Sync (via-Mac mode only)

- ALPN bumps to `unibrowser/via-mac/2` (an old app on the other side can't
  decode the new messages, so the two refuse each other cleanly; the iPhone's
  banner says «Обновите UniBrowser на Mac/iPhone»).
- New `SyncMessage` cases:
  - `bookmarks([Bookmark])` — either way, the whole list (it is small) after any
    change and once after `hello`; receiver merges and, if its result differs,
    sends its own back.
  - `history([Visit])` — either way, visits since the last one sent (cursor per
    peer in UserDefaults), batched at most every 5 s while connected; receiver
    `merge`s.
  - `hello` gains `bookmarks: [Bookmark]` and `historySince: Date?` is not needed:
    after hello each side sends `history(visits(since: lastSentCursor))`.
- The Mac keeps one store for itself; its via-Mac peers share it. The iPhone's
  normal mode never syncs.

### Wiring for the parts

- Mac: `AppModel` owns `history: HistoryStore` and `bookmarks: BookmarkStore`;
  `TabWebController.didFinish` / title changes call `history.record`.
- iPhone: each `MobileStore` (mode) owns its pair; `MobileTabController` records.
- `docs/library-architecture.md`: the API above and how parts B–F hook in.

## B. Mac UI for history and bookmarks

- ☆ in the address strip (filled when bookmarked), ⌘D: a popover with name and
  folder picker, «Удалить закладку».
- History window ⌘Y (menu «История»): search field, sections by day («Сегодня»,
  «Вчера», dates), rows with favicon/title/host/time, open on click, ⌘-click
  in a background tab, context menu: open in new tab, copy link, delete,
  «Удалить все посещения сайта», toolbar «Очистить историю…» (last hour,
  today, today and yesterday, all time).
- Bookmarks window ⌥⌘B (menu «Закладки»): folder tree on the left, contents on
  the right, drag to reorder and move, rename inline, new folder, delete,
  open all in a new group. The «Закладки» menu also lists the root's items and
  folders as submenus.
- ⌘K palette: result groups «Вкладки», «Закладки», «История» (top 5 each,
  history by FTS), plus the existing ones.

## C. iPhone UI for history and bookmarks

- Tabs sheet gets a segmented control «Вкладки · Закладки · История».
  Закладки: folder navigation, swipe to delete, edit mode to reorder/rename.
  История: search, sections by day, swipe to delete, «Очистить…» menu.
- ☆ «Добавить в закладки» / «Изменить закладку» in the «…» menu.
- Address entry suggestions: «Закладки» and «История» groups alongside open tabs.

## D. Basics (Mac + iPhone)

- Find in page: Mac ⌘F bar at the top of the page card (field, «n из m», ↑↓,
  Esc) using `WKWebView.find(_:configuration:)`; ⌘G / ⇧⌘G. iPhone: «Найти на
  странице» in «…» using `findInteraction` (`isFindInteractionEnabled`).
- Downloads: `WKDownloadDelegate` for `navigationResponse` with
  `!canShowMIMEType`, `Content-Disposition: attachment` and the `download`
  attribute. Mac: saves to ~/Downloads (unique name), the sidebar's «Загрузки»
  button gets a popover list with progress, cancel, show in Finder, open, clear;
  a badge while active. iPhone: saves into the app's Documents (visible in
  «Файлы» via `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`),
  a «Загрузки» item in «…» with the list and share sheet.
- Reopen closed tab: ⇧⌘T reopens the most recently archived tab in its space;
  menu «История → Недавно закрытые» lists the last 10. iPhone: long-press on
  «+» shows recently closed.
- Per-site zoom: ⌘+ / ⌘− / ⌘0 set `pageZoom`, remembered per host in
  UserDefaults and applied on navigation; the address strip shows «110 %» while
  not 100. iPhone: «aA» item in «…» with − / % / +.

## E. Site, permissions, privacy

- Site popover from the lock/⚠ icon in the Mac address strip (iPhone: «О сайте»
  in «…» as a sheet): connection state, permissions (камера, микрофон,
  геолокация, уведомления — Спрашивать/Разрешить/Запретить), cookies count and
  «Очистить данные сайта», zoom, «Блокировать рекламу на этом сайте» toggle.
- Permissions: `WKUIDelegate.requestMediaCapturePermission` honours stored
  decisions, otherwise shows an in-app prompt bar («Сайт хочет использовать
  камеру — Разрешить / Запретить, запомнить»); geolocation through the
  same delegate path WebKit offers; notifications: decision stored, Mac shows
  them via `UNUserNotificationCenter` only if the platform path is public.
  Store: `SitePermissions` JSON per host.
- Content blocking: EasyList + EasyPrivacy converted to WebKit content-blocker
  JSON, bundled (converter script `scripts/make_blocklists.py`, output in
  Resources, ≤ 150k rules split into lists WebKit accepts), compiled once into
  `WKContentRuleListStore`, added to every tab; per-site allow list adds an
  `ignore-previous-rules` rule; a global switch in settings; blocked count per
  tab shown in the site popover.
- Private browsing: Mac «Новое приватное окно» ⇧⌘N — a separate window with
  `WKWebsiteDataStore.nonPersistent()`, dark-violet address strip, no history,
  no session save; iPhone: third mode «Приватный» next to «Обычный» and
  «Через Mac», same rules, its tabs closed when leaving the mode.

## F. Convenience

- Settings: Mac `Settings` scene (⌘,) with tabs Основные (search engine,
  start page, appearance), Конфиденциальность (history retention, clear
  data, ad blocking, permissions list), Пароли, iPhone, Расширения
  (links to existing sheets). iPhone: «Настройки» in «…» with the same groups.
- Search engines: Google, Яндекс, DuckDuckGo, Bing; `BrowserStore.url(fromInput:)`
  and `MobileStore.url(fromInput:)` use the chosen one. Suggestions in ⌘K and
  the iPhone address entry from the engine's suggest endpoint (debounced
  150 ms, off in private mode, can be switched off).
- Import (Mac, «Файл → Импорт…» and first-run offer): from Chrome (bookmarks
  JSON, History SQLite copied to a temp file first, passwords via the existing
  CSV import with instructions), from Safari (bookmarks from an exported HTML
  file; history from `~/Library/Safari/History.db` when Full Disk Access is
  granted, with a button that opens the privacy pane), from an HTML bookmarks
  file (Netscape format).
- Reader mode: `Readability.js` (Apache-2.0, bundled) in an isolated content world,
  shown as a clean page with font size and theme controls; button in the address
  strip when the page is readable. iPhone: same, in «…».
- Print / PDF: Mac ⌘P (`printOperation`), «Сохранить как PDF…» (`createPDF`);
  iPhone: share sheet already prints; add «Сохранить как PDF».
- Tab mute: 🔇/🔊 on the tab row while it plays audio (Mac: `_setPageMuted:` /
  public `setAllMediaPlaybackSuspended` fallback), context menu «Выключить звук»;
  iPhone: in «…».

## Verification

Each part: build both apps (`NO_OPEN=1 scripts/build.sh`, `mobile/build.sh`),
its self-checks, and an end-to-end check in an isolated Mac copy (new bundle id
+ `HOME` + `CFFIXED_USER_HOME`) and in the iPhone simulator. Sync of bookmarks
and history between the simulator and an isolated Mac copy is checked at merge.
