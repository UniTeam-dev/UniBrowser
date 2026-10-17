import SwiftUI
import WebKit

// Storage sections of «Приложение»: Web Storage, cookies, IndexedDB, Cache Storage.

// MARK: - localStorage / sessionStorage

struct WebStorageView: View {
    let model: ApplicationModel
    /// "local" or "session".
    let kind: String
    let origin: String

    struct Item: Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }

    @State private var items: [Item] = []
    @State private var total = 0
    @State private var selection: String?
    @State private var filter = ""
    @State private var isEditing = false
    @State private var editKey = ""
    @State private var editValue = ""
    @State private var error: String?

    private var frame: String? { model.frame(origin: origin) }
    private var shown: [Item] {
        filter.isEmpty ? items : items.filter { $0.key.localizedCaseInsensitiveContains(filter) || $0.value.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ApplicationBar {
                TextField("Фильтр", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Button { startNew() } label: { Image(systemName: "plus") }
                    .help("Добавить").accessibilityLabel("Добавить")
                Button { if let selection { remove(selection) } } label: { Image(systemName: "minus") }
                    .help("Удалить").accessibilityLabel("Удалить")
                    .disabled(selection == nil)
                Button("Очистить всё") { run("application.storageClear", ["kind": kind]) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Обновить").accessibilityLabel("Обновить")
                Spacer()
                if let error { Text(error).foregroundStyle(.red).lineLimit(1) }
                Text(total > items.count ? "\(items.count) из \(total)" : "\(total)").foregroundStyle(.secondary)
            }
            Table(shown, selection: $selection) {
                TableColumn("Ключ") { Text($0.key).lineLimit(1) }
                    .width(min: 80, ideal: 200)
                TableColumn("Значение") { Text($0.value).lineLimit(1) }
            }
            .contextMenu(forSelectionType: String.self) { keys in
                if let key = keys.first { Button("Удалить") { remove(key) } }
            }
            if isEditing {
                Divider()
                editor
            }
        }
        .task(id: "\(kind)|\(origin)|\(model.generation)") { await load() }
        .onChange(of: selection) { _, key in
            guard let item = items.first(where: { $0.key == key }) else { return }
            editKey = item.key
            editValue = item.value
            isEditing = true
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Ключ", text: $editKey).textFieldStyle(.roundedBorder)
            TextEditor(text: $editValue)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
            HStack {
                Button("Сохранить") { save() }.keyboardShortcut(.defaultAction).disabled(editKey.isEmpty)
                Button("Отмена") { isEditing = false; selection = nil }
            }
        }
        .padding(8)
    }

    private func startNew() {
        selection = nil
        editKey = ""
        editValue = ""
        isEditing = true
    }

    private func save() {
        var args: [String: Any] = ["kind": kind, "key": editKey, "value": editValue]
        if let selection { args["oldKey"] = selection }
        let key = editKey
        run("application.storageSet", args) { selection = key }
    }

    private func remove(_ key: String) {
        run("application.storageRemove", ["kind": kind, "key": key]) {
            selection = nil
            isEditing = false
        }
    }

    private func run(_ name: String, _ args: [String: Any], then: @escaping () -> Void = {}) {
        Task {
            if case .failure(let failure) = await model.call(frame, name, args) { error = failure.message }
            await load()
            then()
        }
    }

    private func load() async {
        switch await model.call(frame, "application.storage", ["kind": kind]) {
        case .success(let value):
            let result = value as? [String: Any]
            items = (result?["items"] as? [[String: Any]] ?? []).map {
                Item(key: $0["key"] as? String ?? "", value: $0["value"] as? String ?? "")
            }
            total = result?["total"] as? Int ?? items.count
            error = nil
        case .failure(let failure):
            error = failure.message
        }
    }
}

// MARK: - Cookies

/// Cookies of the tab's data store whose domain matches `host` (spec: domain match for the
/// selected frame's host). Editing touches only the cookie being edited.
struct CookiesView: View {
    let model: ApplicationModel
    let host: String

    struct Row: Identifiable {
        let cookie: HTTPCookie
        var id: String { "\(cookie.name)|\(cookie.domain)|\(cookie.path)" }
        var expires: String { cookie.expiresDate?.formatted(date: .numeric, time: .standard) ?? "Сеанс" }
        var size: Int { cookie.name.utf8.count + cookie.value.utf8.count }
        var sameSite: String { cookie.sameSitePolicy?.rawValue ?? "" }
    }

    struct Draft {
        var name = ""
        var value = ""
        var domain = ""
        var path = "/"
        var isSession = true
        var expires = Date.now.addingTimeInterval(86_400 * 30)
        var httpOnly = false
        var secure = false
        /// "", "lax", "strict".
        var sameSite = ""
    }

    @State private var rows: [Row] = []
    @State private var selection: Row.ID?
    @State private var filter = ""
    @State private var draft: Draft?
    @State private var error: String?

    private var store: WKHTTPCookieStore? { model.session?.webView?.configuration.websiteDataStore.httpCookieStore }
    private var shown: [Row] {
        filter.isEmpty ? rows : rows.filter { $0.cookie.name.localizedCaseInsensitiveContains(filter) || $0.cookie.value.localizedCaseInsensitiveContains(filter) }
    }
    private var selected: Row? { rows.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            ApplicationBar {
                TextField("Фильтр", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Button { selection = nil; draft = Draft(domain: host) } label: { Image(systemName: "plus") }
                    .help("Добавить cookie").accessibilityLabel("Добавить cookie")
                Button { if let selected { Task { await delete([selected]) } } } label: { Image(systemName: "minus") }
                    .help("Удалить").accessibilityLabel("Удалить")
                    .disabled(selected == nil)
                Button("Очистить всё") { Task { await delete(shown) } }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Обновить").accessibilityLabel("Обновить")
                Spacer()
                if let error { Text(error).foregroundStyle(.red).lineLimit(1) }
                Text("\(rows.count)").foregroundStyle(.secondary)
            }
            Table(shown, selection: $selection) {
                TableColumn("Имя") { Text($0.cookie.name).lineLimit(1) }.width(min: 60, ideal: 120)
                TableColumn("Значение") { Text($0.cookie.value).lineLimit(1) }.width(min: 60, ideal: 180)
                TableColumn("Domain") { Text($0.cookie.domain).lineLimit(1) }.width(ideal: 110)
                TableColumn("Path") { Text($0.cookie.path).lineLimit(1) }.width(ideal: 50)
                TableColumn("Истекает") { Text($0.expires).lineLimit(1) }.width(ideal: 130)
                TableColumn("Размер") { Text("\($0.size)") }.width(ideal: 45)
                TableColumn("HttpOnly") { Text($0.cookie.isHTTPOnly ? "✓" : "") }.width(ideal: 55)
                TableColumn("Secure") { Text($0.cookie.isSecure ? "✓" : "") }.width(ideal: 50)
                TableColumn("SameSite") { Text($0.sameSite) }.width(ideal: 60)
            }
            .contextMenu(forSelectionType: Row.ID.self) { ids in
                Button("Удалить") { Task { await delete(rows.filter { ids.contains($0.id) }) } }
            }
            if draft != nil {
                Divider()
                editor
            }
        }
        .task(id: "\(host)|\(model.generation)") { await load() }
        .onChange(of: selection) { _, _ in
            guard let cookie = selected?.cookie else { return }
            draft = Draft(
                name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                isSession: cookie.expiresDate == nil, expires: cookie.expiresDate ?? .now.addingTimeInterval(86_400 * 30),
                httpOnly: cookie.isHTTPOnly, secure: cookie.isSecure, sameSite: cookie.sameSitePolicy?.rawValue ?? ""
            )
        }
    }

    @ViewBuilder private var editor: some View {
        if let binding = Binding($draft) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Имя", text: binding.name)
                    TextField("Значение", text: binding.value)
                }
                HStack {
                    TextField("Domain", text: binding.domain)
                    TextField("Path", text: binding.path)
                }
                .textFieldStyle(.roundedBorder)
                HStack(spacing: 14) {
                    Toggle("Сеанс", isOn: binding.isSession)
                    DatePicker("Истекает", selection: binding.expires).labelsHidden().disabled(binding.wrappedValue.isSession)
                    Toggle("HttpOnly", isOn: binding.httpOnly)
                    Toggle("Secure", isOn: binding.secure)
                    Picker("SameSite", selection: binding.sameSite) {
                        Text("—").tag("")
                        Text("Lax").tag("lax")
                        Text("Strict").tag("strict")
                    }
                    .fixedSize()
                }
                HStack {
                    Button("Сохранить") { Task { await save() } }.keyboardShortcut(.defaultAction)
                    Button("Отмена") { draft = nil; selection = nil }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(8)
        }
    }

    private func matches(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return host == domain || host.hasSuffix("." + domain)
    }

    private func load() async {
        guard let store else { return }
        rows = await store.allCookies().filter(matches).map(Row.init).sorted { $0.cookie.name < $1.cookie.name }
    }

    private func delete(_ rows: [Row]) async {
        guard let store else { return }
        for row in rows { await store.deleteCookie(row.cookie) }
        selection = nil
        draft = nil
        await load()
    }

    private func save() async {
        guard let store, let draft else { return }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: draft.name,
            .value: draft.value,
            .domain: draft.domain,
            .path: draft.path.isEmpty ? "/" : draft.path,
        ]
        if !draft.isSession { properties[.expires] = draft.expires }
        if draft.secure { properties[.secure] = "TRUE" }
        if draft.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if !draft.sameSite.isEmpty { properties[.sameSitePolicy] = draft.sameSite }
        guard !draft.name.isEmpty, let cookie = HTTPCookie(properties: properties) else {
            error = "Проверьте имя, domain и path"
            return
        }
        // Renaming or moving a cookie makes a new one: drop the old.
        if let old = selected?.cookie, "\(old.name)|\(old.domain)|\(old.path)" != "\(cookie.name)|\(cookie.domain)|\(cookie.path)" {
            await store.deleteCookie(old)
        }
        await store.setCookie(cookie)
        error = nil
        self.draft = nil
        await load()
        selection = Row(cookie: cookie).id
    }
}

// MARK: - IndexedDB

struct IndexedDBView: View {
    let model: ApplicationModel
    let origin: String

    struct Store: Hashable {
        let name: String
        let keyPath: String
        let autoIncrement: Bool
        let indexes: [String]
        let count: Int
    }

    struct Database: Identifiable {
        let name: String
        let version: Int
        let stores: [Store]
        let error: String?
        var id: String { name }
    }

    struct Ref: Hashable {
        let db: String
        let store: String
    }

    struct Record: Identifiable {
        /// Handle of the primary key in the page, for delete.
        let id: Int
        let key: String
        let value: String
    }

    static let pageSize = 100

    @State private var databases: [Database] = []
    @State private var selected: Ref?
    @State private var records: [Record] = []
    @State private var total = 0
    @State private var offset = 0
    @State private var recordSelection: Record.ID?
    @State private var status: String?

    private var frame: String? { model.frame(origin: origin) }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selected) {
                ForEach(databases) { db in
                    Section {
                        ForEach(db.stores, id: \.name) { store in
                            Text("\(store.name)  ·  \(store.count)").tag(Ref(db: db.name, store: store.name))
                        }
                        if let error = db.error { Text(error).foregroundStyle(.red) }
                    } header: {
                        HStack {
                            Text("\(db.name)  v\(db.version)").lineLimit(1)
                            Spacer()
                            Button { deleteDatabase(db.name) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Удалить базу").accessibilityLabel("Удалить базу \(db.name)")
                        }
                    }
                }
            }
            .overlay { if databases.isEmpty { ApplicationMessage(text: "Нет баз IndexedDB") } }
            .frame(width: 180)
            Divider()
            VStack(spacing: 0) {
                ApplicationBar {
                    Button { Task { await loadDatabases() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Обновить").accessibilityLabel("Обновить")
                    if let selected {
                        Button("Удалить запись") { deleteRecord(selected) }.disabled(recordSelection == nil)
                        Button("Очистить хранилище") { act("application.clearStore", ["db": selected.db, "store": selected.store]) }
                        Spacer()
                        Button { page(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(offset == 0).accessibilityLabel("Предыдущая страница")
                        Text(total == 0 ? "0" : "\(offset + 1)–\(offset + records.count) из \(total)").foregroundStyle(.secondary)
                        Button { page(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(offset + Self.pageSize >= total).accessibilityLabel("Следующая страница")
                    } else {
                        Spacer()
                    }
                    if let status { Text(status).foregroundStyle(.secondary).lineLimit(1) }
                }
                if let selected, let store = databases.first(where: { $0.name == selected.db })?.stores.first(where: { $0.name == selected.store }) {
                    Text("keyPath: \(store.keyPath.isEmpty ? "—" : store.keyPath)   autoIncrement: \(store.autoIncrement ? "да" : "нет")   индексы: \(store.indexes.isEmpty ? "—" : store.indexes.joined(separator: ", "))")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                Table(records, selection: $recordSelection) {
                    TableColumn("#") { record in Text("\(offset + (records.firstIndex { $0.id == record.id } ?? 0))") }.width(36)
                    TableColumn("Ключ") { Text($0.key).lineLimit(1).textSelection(.enabled) }.width(min: 60, ideal: 140)
                    TableColumn("Значение") { Text($0.value).lineLimit(3).textSelection(.enabled) }
                }
            }
        }
        .task(id: "\(origin)|\(model.generation)") { await loadDatabases() }
        .task(id: "\(selected?.db ?? "")|\(selected?.store ?? "")|\(offset)") { await loadRecords() }
        .onChange(of: selected) { offset = 0 }
    }

    private func page(_ step: Int) {
        offset = max(0, offset + step * Self.pageSize)
    }

    private func loadDatabases() async {
        guard case .success(let value) = await model.call(frame, "application.databases") else { return }
        databases = (value as? [[String: Any]] ?? []).map { db in
            Database(
                name: db["name"] as? String ?? "",
                version: db["version"] as? Int ?? 0,
                stores: (db["stores"] as? [[String: Any]] ?? []).map {
                    Store(
                        name: $0["name"] as? String ?? "",
                        keyPath: $0["keyPath"] as? String ?? "",
                        autoIncrement: $0["autoIncrement"] as? Bool ?? false,
                        indexes: $0["indexes"] as? [String] ?? [],
                        count: $0["count"] as? Int ?? 0
                    )
                },
                error: db["error"] as? String
            )
        }
        await loadRecords()
    }

    private func loadRecords() async {
        guard let selected else {
            records = []
            total = 0
            return
        }
        let args: [String: Any] = ["db": selected.db, "store": selected.store, "offset": offset, "limit": Self.pageSize]
        switch await model.call(frame, "application.records", args) {
        case .success(let value):
            let result = value as? [String: Any]
            records = (result?["rows"] as? [[String: Any]] ?? []).compactMap {
                guard let handle = $0["handle"] as? Int else { return nil }
                return Record(id: handle, key: $0["key"] as? String ?? "", value: $0["value"] as? String ?? "")
            }
            total = result?["total"] as? Int ?? 0
            status = nil
        case .failure(let failure):
            records = []
            status = failure.message
        }
    }

    private func deleteRecord(_ ref: Ref) {
        guard let handle = recordSelection else { return }
        act("application.deleteRecord", ["db": ref.db, "store": ref.store, "handle": handle])
    }

    private func deleteDatabase(_ name: String) {
        Task {
            switch await model.call(frame, "application.deleteDatabase", ["db": name]) {
            case .success(let result as String) where result == "blocked":
                status = "Удаление ждёт, пока страница закроет соединение с базой"
            case .failure(let failure): status = failure.message
            default: status = "База «\(name)» удалена"
            }
            if selected?.db == name { selected = nil }
            await loadDatabases()
        }
    }

    private func act(_ name: String, _ args: [String: Any]) {
        Task {
            if case .failure(let failure) = await model.call(frame, name, args) { status = failure.message }
            recordSelection = nil
            await loadDatabases()
        }
    }
}

// MARK: - Cache Storage

struct CacheStorageView: View {
    let model: ApplicationModel
    let origin: String

    struct Entry: Identifiable {
        let url: String
        let status: Int
        let type: String
        let size: String
        let date: String
        var id: String { url }
    }

    struct Cache: Identifiable {
        let name: String
        let total: Int
        let entries: [Entry]
        var id: String { name }
    }

    @State private var caches: [Cache] = []
    @State private var selected: String?
    @State private var entrySelection: Entry.ID?
    @State private var status: String?

    private var frame: String? { model.frame(origin: origin) }

    var body: some View {
        HStack(spacing: 0) {
            List(caches, selection: $selected) { cache in
                Text("\(cache.name)  ·  \(cache.total)").lineLimit(1).tag(cache.name)
            }
            .overlay { if caches.isEmpty { ApplicationMessage(text: "Нет кэшей") } }
            .frame(width: 180)
            Divider()
            VStack(spacing: 0) {
                ApplicationBar {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Обновить").accessibilityLabel("Обновить")
                    if let selected {
                        Button("Удалить запись") {
                            if let url = entrySelection { act("application.cacheDeleteEntry", ["cache": selected, "url": url]) }
                        }
                        .disabled(entrySelection == nil)
                        Button("Удалить кэш") { act("application.cacheDelete", ["cache": selected]) }
                    }
                    Spacer()
                    if let status { Text(status).foregroundStyle(.secondary).lineLimit(1) }
                }
                let cache = caches.first { $0.name == selected }
                Table(cache?.entries ?? [], selection: $entrySelection) {
                    TableColumn("URL") { Text($0.url).lineLimit(1).textSelection(.enabled) }.width(min: 120, ideal: 320)
                    TableColumn("Тип") { Text($0.type).lineLimit(1) }.width(ideal: 120)
                    TableColumn("Статус") { Text($0.status == 0 ? "" : "\($0.status)") }.width(ideal: 50)
                    TableColumn("Размер") { Text($0.size) }.width(ideal: 60)
                    TableColumn("Дата") { Text($0.date).lineLimit(1) }.width(ideal: 160)
                }
                if let cache, cache.total > cache.entries.count {
                    Text("Показаны первые \(cache.entries.count) из \(cache.total)").foregroundStyle(.secondary).padding(4)
                }
            }
        }
        .task(id: "\(origin)|\(model.generation)") { await load() }
    }

    private func load() async {
        switch await model.call(frame, "application.caches") {
        case .success(let value):
            caches = (value as? [[String: Any]] ?? []).map { cache in
                Cache(
                    name: cache["name"] as? String ?? "",
                    total: cache["total"] as? Int ?? 0,
                    entries: (cache["entries"] as? [[String: Any]] ?? []).map {
                        Entry(
                            url: $0["url"] as? String ?? "",
                            status: $0["status"] as? Int ?? 0,
                            type: $0["type"] as? String ?? "",
                            size: ($0["size"] as? String).flatMap(Int.init)?.bytes ?? "",
                            date: $0["date"] as? String ?? ""
                        )
                    }
                )
            }
            if selected == nil || !caches.contains(where: { $0.name == selected }) { selected = caches.first?.name }
        case .failure(let failure):
            status = failure.message
        }
    }

    private func act(_ name: String, _ args: [String: Any]) {
        Task {
            if case .failure(let failure) = await model.call(frame, name, args) { status = failure.message }
            entrySelection = nil
            await load()
        }
    }
}
