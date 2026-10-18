# iPhone UI for history and bookmarks (spec part C)

Spec: `docs/superpowers/specs/2026-10-19-browser-essentials-design.md` §C. API: `docs/library-architecture.md`.
All views read `model.store.bookmarks` / `model.store.history`, so both modes work (via-Mac uses the synced pair).

1. `mobile/UniBrowserMobile/Views/LibraryViews.swift` (new):
   - `BookmarksList(bookmarks:folderID:onOpen:)` — `children(of:)`, folders push another `BookmarksList`,
     swipe/`onDelete` → `delete`, own edit mode: `onMove` → `move(_:to:at:)`, tap in edit mode → rename alert,
     «Новая папка» while editing. Context menu: open in new tab, rename, delete.
   - `HistoryList(history:onOpen:)` — `.searchable`; empty query → `days(limit:)` + `visits(on:)` per day
     («Сегодня», «Вчера», date), query → `search(_:limit:)`; swipe → `delete(ids:)`; context menu
     «Удалить все посещения сайта» → `delete(host:)`; «Очистить…» → dialog: час / сегодня / сегодня и вчера / всё.
   - `BookmarkEditor(bookmarks:url:title:)` — name + folder picker; «Сохранить» adds or renames/moves;
     «Удалить закладку» for an existing one.
2. `TabsSheet`: segmented «Вкладки · Закладки · История» in the principal toolbar slot; the tab list moves
   into `tabsList` unchanged; bookmarks/history open in the current tab (new one if none), context menu new tab.
3. `BrowserScreen`: «…» gets a separate section with ☆ «Добавить в закладки» / «Изменить закладку» → editor sheet;
   `AddressEntry` gets «Закладки» and «История» sections (top 4 each, history without URLs already listed).
4. Verify: `mobile/build.sh`, simulator: add bookmark, folder, reorder, rename, delete; history sections,
   search, swipe delete, clear; suggestions. `NO_OPEN=1 scripts/build.sh` for the Mac (no Mac code changes).
