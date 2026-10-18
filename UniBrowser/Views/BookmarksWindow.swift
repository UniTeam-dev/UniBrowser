import SwiftUI

/// ⌥⌘B: folder tree on the left, the folder's items on the right. Items drag to reorder,
/// or onto a folder on the left to move there; names edit inline.
struct BookmarksWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// The folder shown on the right; `root` stands for the top level.
    @State private var folderID = Self.root
    @State private var selection = Set<UUID>()
    /// The item whose name is being edited, on either side.
    @State private var editingID: UUID?
    @State private var editingTitle = ""

    private static let root = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private struct Node: Identifiable {
        let id: UUID
        let title: String
        let children: [Node]?
    }

    private var bookmarks: BookmarkStore { model.bookmarks }
    private var parentID: UUID? { folderID == Self.root ? nil : folderID }

    private func nodes(in parentID: UUID?) -> [Node] {
        bookmarks.children(of: parentID).filter(\.isFolder).map { folder in
            let children = nodes(in: folder.id)
            return Node(id: folder.id, title: folder.title, children: children.isEmpty ? nil : children)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { folderID }, set: { folderID = $0 ?? Self.root })) {
                Label("Закладки", systemImage: "book")
                    .tag(Self.root)
                    .dropDestination(for: String.self) { ids, _ in moveInto(nil, ids) }
                OutlineGroup(nodes(in: nil), children: \.children) { node in
                    folderLabel(node)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            content
        }
        .toolbar {
            Button("Новая папка", systemImage: "folder.badge.plus") { newFolder() }
                .help("Новая папка")
            Button("Открыть все в новой группе", systemImage: "rectangle.stack.badge.plus") { openAll() }
                .help("Открыть все в новой группе")
                .disabled(!bookmarks.children(of: parentID).contains { $0.url != nil })
            Button("Удалить", systemImage: "trash") { selection.forEach(bookmarks.delete); selection = [] }
                .help("Удалить")
                .disabled(selection.isEmpty)
        }
        .navigationTitle(parentID.flatMap { id in bookmarks.all.first { $0.id == id }?.title } ?? "Закладки")
        .frame(minWidth: 640, minHeight: 420)
        .onChange(of: folderID) { selection = []; editingID = nil }
        .onChange(of: bookmarks.all) {
            // The shown folder was deleted (here or on the iPhone).
            if let parentID, !bookmarks.all.contains(where: { $0.id == parentID && !$0.deleted }) { folderID = Self.root }
        }
    }

    private func folderLabel(_ node: Node) -> some View {
        Label { titleText(node.id, node.title) } icon: { Image(systemName: "folder") }
            .tag(node.id)
            .dropDestination(for: String.self) { ids, _ in moveInto(node.id, ids) }
            .contextMenu {
                Button("Переименовать") { startEditing(node.id, node.title) }
                Button("Открыть все в новой группе") { model.openFolderInNewGroup(node.id, title: node.title) }
                Divider()
                Button("Удалить папку") { bookmarks.delete(node.id) }
            }
    }

    private var content: some View {
        let items = bookmarks.children(of: parentID)
        return List(selection: $selection) {
            ForEach(items) { item in
                HStack(spacing: 10) {
                    if let url = item.url {
                        Favicon(url: url, size: 18)
                    } else {
                        Image(systemName: "folder").frame(width: 18)
                    }
                    titleText(item.id, item.title)
                    Spacer()
                    if let host = item.url?.host() {
                        Text(host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .help(item.url?.absoluteString ?? "")
                .draggable(item.id.uuidString)
            }
            .dropDestination(for: String.self) { ids, index in
                // `index` counts the dragged items too; the store wants it without them.
                for id in ids.compactMap(UUID.init(uuidString:)) {
                    bookmarks.move(id, to: parentID, at: items.prefix(index).filter { $0.id != id }.count)
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(ids.compactMap { id in items.first { $0.id == id } })
        } primaryAction: { ids in
            guard ids.count == 1, let item = items.first(where: { ids.contains($0.id) }) else { return }
            if let url = item.url {
                model.store.openFromLibrary(url, newTab: true)
                openWindow(id: "main")
            } else {
                folderID = item.id
            }
        }
        .onDeleteCommand { selection.forEach(bookmarks.delete); selection = [] }
        .overlay {
            if items.isEmpty { ContentUnavailableView("Пусто", systemImage: "star", description: Text("Добавьте страницу кнопкой ☆ или ⌘D.")) }
        }
    }

    @ViewBuilder
    private func contextMenu(_ items: [Bookmark]) -> some View {
        let urls = items.compactMap(\.url)
        if !urls.isEmpty {
            Button(urls.count == 1 ? "Открыть в новой вкладке" : "Открыть в новых вкладках") {
                urls.forEach { model.store.openFromLibrary($0, newTab: true) }
                openWindow(id: "main")
            }
        }
        if items.count == 1, let item = items.first {
            if let url = item.url {
                Button("Скопировать ссылку") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            } else {
                Button("Открыть все в новой группе") { model.openFolderInNewGroup(item.id, title: item.title) }
            }
            Button("Переименовать") { startEditing(item.id, item.title) }
        }
        if !items.isEmpty {
            Divider()
            Button("Удалить") { items.forEach { bookmarks.delete($0.id) }; selection = [] }
        }
    }

    /// The name, or a field while it is being renamed (↵ saves, Esc cancels).
    @ViewBuilder
    private func titleText(_ id: UUID, _ title: String) -> some View {
        if editingID == id {
            TextField("Название", text: $editingTitle)
                .onSubmit {
                    let trimmed = editingTitle.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { bookmarks.rename(id, to: trimmed) }
                    editingID = nil
                }
                .onExitCommand { editingID = nil }
        } else {
            Text(title.isEmpty ? "Без названия" : title).lineLimit(1)
        }
    }

    private func startEditing(_ id: UUID, _ title: String) {
        editingTitle = title
        editingID = id
    }

    private func moveInto(_ folder: UUID?, _ ids: [String]) -> Bool {
        let ids = ids.compactMap(UUID.init(uuidString:))
        ids.forEach { bookmarks.move($0, to: folder, at: .max) }
        return !ids.isEmpty
    }

    private func newFolder() {
        let folder = bookmarks.addFolder(title: "Новая папка", in: parentID)
        selection = [folder.id]
        startEditing(folder.id, folder.title)
    }

    private func openAll() {
        model.openFolderInNewGroup(parentID, title: parentID.flatMap { id in bookmarks.all.first { $0.id == id }?.title } ?? "Закладки")
        openWindow(id: "main")
    }
}
