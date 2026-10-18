import SwiftUI

/// ☆ in the address strip, filled when the page is bookmarked; a click (or ⌘D) bookmarks it
/// and shows the editor.
struct BookmarkStar: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        let isBookmarked = model.bookmarks.bookmark(for: url) != nil
        let label = isBookmarked ? "Изменить закладку (⌘D)" : "Добавить в закладки (⌘D)"
        Button { model.editBookmarkOfCurrentPage() } label: {
            Image(systemName: isBookmarked ? "star.fill" : "star")
                .foregroundStyle(isBookmarked ? Palette.accent : Palette.secondaryText)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: Bindable(model).isBookmarkPopoverVisible, arrowEdge: .bottom) {
            if let bookmark = model.bookmarks.bookmark(for: url) {
                BookmarkEditor(bookmarks: model.bookmarks, bookmark: bookmark) { model.isBookmarkPopoverVisible = false }
            }
        }
    }
}

/// Name, folder and «Удалить закладку». The name is saved on ↵, «Готово» or when the popover closes.
private struct BookmarkEditor: View {
    let bookmarks: BookmarkStore
    let bookmark: Bookmark
    let close: () -> Void
    @State private var title = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Закладка").font(.headline)
            Form {
                TextField("Название", text: $title)
                    .focused($isTitleFocused)
                    .onSubmit { saveTitle(); close() }
                Picker("Папка", selection: Binding(
                    get: { bookmark.parentID },
                    set: { bookmarks.move(bookmark.id, to: $0, at: .max) }
                )) {
                    Text("Закладки").tag(UUID?.none)
                    ForEach(bookmarks.folderTree(), id: \.folder.id) { entry in
                        Text(String(repeating: "    ", count: entry.depth + 1) + entry.folder.title).tag(UUID?.some(entry.folder.id))
                    }
                }
            }
            HStack {
                Button("Удалить закладку", role: .destructive) {
                    close()
                    bookmarks.delete(bookmark.id)
                }
                Spacer()
                Button("Готово") { saveTitle(); close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            title = bookmark.title
            isTitleFocused = true
        }
        .onDisappear(perform: saveTitle)
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != bookmark.title, bookmarks.all.contains(where: { $0.id == bookmark.id && !$0.deleted }) {
            bookmarks.rename(bookmark.id, to: trimmed)
        }
    }
}

extension BookmarkStore {
    /// Every live folder depth-first, for folder pickers; `depth` 0 is a root folder.
    func folderTree(in parentID: UUID? = nil, depth: Int = 0) -> [(folder: Bookmark, depth: Int)] {
        children(of: parentID).filter(\.isFolder).flatMap { folder in
            [(folder, depth)] + folderTree(in: folder.id, depth: depth + 1)
        }
    }
}
