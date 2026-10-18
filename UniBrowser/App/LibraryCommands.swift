import SwiftUI

/// Menus «История» and «Закладки»: the History (⌘Y) and Bookmarks (⌥⌘B) windows, ⌘D,
/// and the root bookmarks with folders as submenus.
struct LibraryCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Закладки") {
            let url = model.store.selectedTab?.url
            Button(url.flatMap(model.bookmarks.bookmark(for:)) == nil ? "Добавить в закладки…" : "Изменить закладку…") {
                model.editBookmarkOfCurrentPage()
            }
            // Not disabled without a page: a menu that hasn't been opened can keep a stale state,
            // and ⌘D must still work; the action itself does nothing without a page.
            .keyboardShortcut("d")
            Button("Показать все закладки") { openWindow(id: "bookmarks") }
                .keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
            BookmarkMenuItems(model: model, parentID: nil)
        }
    }
}

/// A folder's items as menu items; subfolders become submenus.
private struct BookmarkMenuItems: View {
    let model: AppModel
    let parentID: UUID?

    var body: some View {
        ForEach(model.bookmarks.children(of: parentID)) { item in
            if let url = item.url {
                Button(item.title.isEmpty ? url.absoluteString : item.title) { model.store.openFromLibrary(url) }
            } else {
                Menu(item.title) {
                    BookmarkMenuItems(model: model, parentID: item.id)
                    Divider()
                    Button("Открыть все в новой группе") { model.openFolderInNewGroup(item.id, title: item.title) }
                }
            }
        }
    }
}

extension AppModel {
    /// ⌘D and ☆: bookmarks the current page if it isn't yet, then shows the editor popover.
    func editBookmarkOfCurrentPage() {
        guard let tab = store.selectedTab, let url = tab.url else { return }
        if bookmarks.bookmark(for: url) == nil { bookmarks.add(url: url, title: tab.displayTitle) }
        isBookmarkPopoverVisible = true
    }

    /// A folder's bookmarks (not its subfolders; nil = the root) as tabs of a new group named `title`.
    func openFolderInNewGroup(_ folderID: UUID?, title: String) {
        let urls = bookmarks.children(of: folderID).compactMap(\.url)
        guard !urls.isEmpty else { return }
        let groupID = store.newGroup(named: title)
        let tabs = urls.map { store.newTab(url: $0, inGroup: groupID, select: false) }
        store.select(tabs[0].id)
    }
}

extension BrowserStore {
    /// History, bookmarks and their menus: a plain open replaces the current page,
    /// `newTab` opens a tab next to it, `background` leaves the current one selected.
    func openFromLibrary(_ url: URL, newTab: Bool = false, background: Bool = false) {
        if !newTab, !background, let tab = selectedTab {
            tab.load(url)
        } else {
            self.newTab(url: url, select: !background)
        }
    }
}
