import SwiftUI

/// Opens a bookmark or a history page: `true` asks for a new tab.
typealias OpenPage = (URL, Bool) -> Void

/// One bookmark folder (nil = root): folders push the next level, bookmarks open.
/// «Править» reorders by drag, renames by tap and adds folders.
struct BookmarksList: View {
    let bookmarks: BookmarkStore
    let folderID: UUID?
    let onOpen: OpenPage
    @State private var editMode = EditMode.inactive
    @State private var renaming: Bookmark?
    @State private var name = ""
    @State private var isNamingFolder = false

    var body: some View {
        let items = bookmarks.children(of: folderID)
        List {
            ForEach(items) { row($0) }
                .onDelete { $0.map { items[$0].id }.forEach(bookmarks.delete) }
                .onMove { from, to in
                    guard let index = from.first else { return }
                    // `move` counts the destination without the item itself.
                    bookmarks.move(items[index].id, to: folderID, at: to > index ? to - 1 : to)
                }
        }
        .environment(\.editMode, $editMode)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(folderID == nil ? "Нет закладок" : "Папка пуста", systemImage: "book",
                                       description: Text("Добавьте страницу: «…» → «Добавить в закладки»."))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if editMode.isEditing {
                    Button("Новая папка", systemImage: "folder.badge.plus") { name = ""; isNamingFolder = true }
                }
                Spacer()
                Button(editMode.isEditing ? "Готово" : "Править") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
        }
        .alert("Новая папка", isPresented: $isNamingFolder) {
            TextField("Название", text: $name)
            Button("Создать") {
                let title = name.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { bookmarks.addFolder(title: title, in: folderID) }
            }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Название", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $name)
            Button("Сохранить") {
                let title = name.trimmingCharacters(in: .whitespaces)
                if let id = renaming?.id, !title.isEmpty { bookmarks.rename(id, to: title) }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func row(_ item: Bookmark) -> some View {
        let label = Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? (item.url?.host() ?? "Без названия") : item.title).lineLimit(1)
                if let host = item.url?.host() {
                    Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: item.isFolder ? "folder" : "book")
        }
        Group {
            if editMode.isEditing {
                Button { rename(item) } label: { label }
            } else if item.isFolder {
                NavigationLink {
                    BookmarksList(bookmarks: bookmarks, folderID: item.id, onOpen: onOpen)
                        .navigationTitle(item.title)
                } label: { label }
            } else if let url = item.url {
                Button { onOpen(url, false) } label: { label }
            }
        }
        .foregroundStyle(.primary)
        .contextMenu {
            if let url = item.url {
                Button("Открыть в новой вкладке", systemImage: "plus.square.on.square") { onOpen(url, true) }
                Button("Скопировать ссылку", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
            }
            Button("Переименовать", systemImage: "pencil") { rename(item) }
            Button("Удалить", systemImage: "trash", role: .destructive) { bookmarks.delete(item.id) }
        }
    }

    private func rename(_ item: Bookmark) {
        name = item.title
        renaming = item
    }
}

/// Visits by day, newest first, or the search results; swipe to delete, «Очистить…» for a time range.
struct HistoryList: View {
    let history: HistoryStore
    let onOpen: OpenPage
    @State private var query = ""
    @State private var isClearing = false

    var body: some View {
        let _ = history.revision // re-query after every change
        let query = query.trimmingCharacters(in: .whitespaces)
        let days = query.isEmpty ? history.days(limit: 90) : []
        let found = query.isEmpty ? [] : history.search(query, limit: 200)
        List {
            if query.isEmpty {
                ForEach(days, id: \.self) { day in
                    Section(Self.title(of: day)) {
                        ForEach(history.visits(on: day)) { row($0, allVisits: false) }
                    }
                }
            } else {
                ForEach(found) { row($0, allVisits: true) }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск в истории")
        .overlay {
            if query.isEmpty && days.isEmpty {
                ContentUnavailableView("История пуста", systemImage: "clock")
            } else if !query.isEmpty && found.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Button("Очистить…") { isClearing = true }
                    .disabled(days.isEmpty && query.isEmpty)
            }
        }
        .confirmationDialog("Очистить историю", isPresented: $isClearing, titleVisibility: .visible) {
            let today = Calendar.current.startOfDay(for: .now)
            Button("Последний час", role: .destructive) { history.delete(since: .now.addingTimeInterval(-3600)) }
            Button("Сегодня", role: .destructive) { history.delete(since: today) }
            Button("Сегодня и вчера", role: .destructive) {
                history.delete(since: Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today)
            }
            Button("Всё время", role: .destructive) { history.deleteAll() }
        }
    }

    /// A search shows one row per address, so its delete takes every visit of that address.
    private func row(_ visit: Visit, allVisits: Bool) -> some View {
        Button { onOpen(visit.url, false) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(visit.title.isEmpty ? visit.url.absoluteString : visit.title).lineLimit(1)
                Text("\(visit.host) · \(visit.visitedAt.formatted(date: allVisits ? .abbreviated : .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .swipeActions {
            Button("Удалить", systemImage: "trash", role: .destructive) {
                // ponytail: scans the whole history for one URL's visits; add delete(url:) to HistoryStore if it gets slow.
                history.delete(ids: allVisits ? history.visits(since: .distantPast).filter { $0.url == visit.url }.map(\.id) : [visit.id])
            }
        }
        .contextMenu {
            Button("Открыть в новой вкладке", systemImage: "plus.square.on.square") { onOpen(visit.url, true) }
            Button("Скопировать ссылку", systemImage: "doc.on.doc") { UIPasteboard.general.url = visit.url }
            if !visit.host.isEmpty {
                Button("Удалить все посещения сайта", systemImage: "trash", role: .destructive) { history.delete(host: visit.host) }
            }
        }
    }

    private static func title(of day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(day) { return "Вчера" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "ru_RU")))
    }
}

/// ☆ in «…»: name and folder of the page's bookmark; adds it on «Сохранить» if it's new.
struct BookmarkEditor: View {
    let bookmarks: BookmarkStore
    let url: URL
    @State private var title: String
    @State private var folderID: UUID?
    private let existing: Bookmark?
    @Environment(\.dismiss) private var dismiss

    init(bookmarks: BookmarkStore, url: URL, title: String) {
        self.bookmarks = bookmarks
        self.url = url
        existing = bookmarks.bookmark(for: url)
        _title = State(initialValue: existing?.title ?? title)
        _folderID = State(initialValue: existing?.parentID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $title)
                    Text(url.absoluteString).foregroundStyle(.secondary).lineLimit(1)
                }
                Picker("Папка", selection: $folderID) {
                    Text("Закладки").tag(UUID?.none)
                    ForEach(folders(in: nil, depth: 1), id: \.0.id) { folder, depth in
                        Text(String(repeating: "    ", count: depth) + folder.title).tag(Optional(folder.id))
                    }
                }
                if let existing {
                    Button("Удалить закладку", role: .destructive) {
                        bookmarks.delete(existing.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle(existing == nil ? "Добавить в закладки" : "Изменить закладку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save) }
            }
        }
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? (url.host() ?? url.absoluteString) : title
        if let existing {
            if existing.title != name { bookmarks.rename(existing.id, to: name) }
            if existing.parentID != folderID {
                bookmarks.move(existing.id, to: folderID, at: bookmarks.children(of: folderID).count)
            }
        } else {
            bookmarks.add(url: url, title: name, in: folderID)
        }
        dismiss()
    }

    /// Every folder under `parentID`, depth-first, with its depth for indentation.
    private func folders(in parentID: UUID?, depth: Int) -> [(Bookmark, Int)] {
        bookmarks.children(of: parentID).filter(\.isFolder).flatMap { [($0, depth)] + folders(in: $0.id, depth: depth + 1) }
    }
}
