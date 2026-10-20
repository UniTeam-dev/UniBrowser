import SwiftUI
import UniformTypeIdentifiers

/// «Файлы» of an SSH tab: the remote folder over SFTP, the file actions and the tab's transfers.
/// Downloads go to the app's Documents, which «Файлы» shows under UniBrowser.
struct FilesScreen: View {
    let session: SSHSession
    let browser: SFTPBrowser

    @State private var failure: String?
    @State private var naming: Naming?
    @State private var name = ""
    @State private var deleting: (entries: [SFTPEntry], count: Int)?
    @State private var permissions: SFTPEntry?
    @State private var editing: Editing?
    @State private var notText: SFTPEntry?
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = browser.error {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            list
            if !browser.transfers.items.isEmpty || browser.transfers.clash != nil {
                Divider()
                TransfersStrip(queue: browser.transfers)
            }
        }
        // A terminal `cd` moves the list only while it follows; a (re)connect reloads what it shows.
        .task(id: session.cwd) {
            guard session.state == .connected, browser.followsTerminal else { return }
            await browser.followTerminal()
        }
        .task(id: session.state == .connected) {
            guard session.state == .connected else { return }
            if browser.followsTerminal { await browser.followTerminal() } else { await browser.reload() }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { upload(urls) }
        }
        .alert(naming?.title ?? "", isPresented: isPresent($naming), presenting: naming) { naming in
            TextField("Имя", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(naming.button) { perform { try await naming.apply(name) } }
            Button("Отмена", role: .cancel) {}
        }
        .alert(deleting.map { $0.count == 1 ? "Удалить «\($0.entries[0].name)»?" : "Удалить объектов: \($0.count)?" } ?? "",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { deleting in
            Button("Удалить", role: .destructive) { perform { try await browser.delete(deleting.entries) } }
            Button("Отмена", role: .cancel) {}
        } message: { _ in
            Text("Папки удаляются со всем содержимым. Это нельзя отменить.")
        }
        .alert("Не получилось", isPresented: isPresent($failure), presenting: failure) { _ in
            Button("OK") {}
        } message: { Text($0) }
        .alert("Файл не открыть в редакторе", isPresented: isPresent($notText), presenting: notText) { entry in
            Button("Скачать") { download([entry]) }
            Button("Отмена", role: .cancel) {}
        } message: { _ in
            Text("Редактор открывает текстовые файлы UTF-8 до 5 МБ.")
        }
        .sheet(item: $permissions) { entry in
            PermissionsSheet(entry: entry) { mode in perform { try await browser.chmod(entry, mode) } }
        }
        .sheet(item: $editing) { editing in
            TextEditorSheet(name: editing.entry.name, text: editing.text) { try await browser.writeText($0, to: editing.entry) }
        }
    }

    // MARK: - Toolbar and path

    private var toolbar: some View {
        HStack(spacing: 8) {
            pathBar
            Button("↧ папка терминала") { Task { await browser.followTerminal() } }
                .font(.caption)
                .fixedSize()
                .disabled(browser.followsTerminal || session.cwd == nil || session.state != .connected)
            Menu {
                Button("Новая папка…", systemImage: "folder.badge.plus") { newFolder() }
                Button("Загрузить…", systemImage: "square.and.arrow.up") { isImporting = true }
                Toggle("Скрытые файлы", systemImage: "eye", isOn: Binding(get: { browser.showHidden }, set: { browser.showHidden = $0 }))
                Button("Обновить", systemImage: "arrow.clockwise") { Task { await browser.reload() } }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("Действия с папкой")
            .disabled(session.state != .connected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Each segment opens that folder.
    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 1 { Text("/").foregroundStyle(.tertiary) }
                    Button(segment.name) { Task { await browser.open(segment.path) } }
                        .foregroundStyle(index == segments.count - 1 ? .primary : .secondary)
                }
            }
            .font(.callout)
        }
        .defaultScrollAnchor(.trailing)
    }

    private var segments: [(name: String, path: String)] {
        var result = [(name: "/", path: "/")]
        var path = ""
        for part in browser.path.split(separator: "/") {
            path += "/" + part
            result.append((String(part), path))
        }
        return result
    }

    // MARK: - List

    private var list: some View {
        List(browser.entries) { entry in
            Button { open(entry) } label: { row(entry) }
                .foregroundStyle(.primary)
                .contextMenu { menu(for: entry) }
                .swipeActions {
                    Button("Удалить", role: .destructive) { askDelete([entry]) }
                    if !entry.isDirectory {
                        Button("Скачать") { download([entry]) }.tint(.accentColor)
                    }
                }
        }
        .listStyle(.plain)
        .refreshable { await browser.reload() }
        .disabled(session.state != .connected)
    }

    private func row(_ entry: SFTPEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 24)
                .overlay(alignment: .bottomTrailing) {
                    if entry.isSymlink { Image(systemName: "arrow.turn.up.right").font(.system(size: 8, weight: .bold)) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Text(detail(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    /// «12 КБ · 21.10.2026, 14:05 · rw-r--r--».
    private func detail(_ entry: SFTPEntry) -> String {
        var parts: [String] = []
        if !entry.isDirectory { parts.append(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)) }
        if let modified = entry.modified { parts.append(modified.formatted(date: .numeric, time: .shortened)) }
        parts.append(Self.rwx(entry.permissions))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func menu(for entry: SFTPEntry) -> some View {
        if !entry.isDirectory {
            Button("Скачать", systemImage: "arrow.down.circle") { download([entry]) }
        }
        Button("Переименовать…", systemImage: "pencil") {
            name = entry.name
            naming = Naming(title: "Переименовать «\(entry.name)»", button: "Переименовать") { try await browser.rename(entry, to: $0) }
        }
        Button("Права…", systemImage: "lock") { permissions = entry }
        Divider()
        Button("Удалить…", systemImage: "trash", role: .destructive) { askDelete([entry]) }
    }

    // MARK: - Actions

    private func open(_ entry: SFTPEntry) {
        if entry.isDirectory {
            Task { await browser.open(entry.path) }
            return
        }
        perform {
            if let text = try await browser.readText(entry) { editing = Editing(entry: entry, text: text) } else { notText = entry }
        }
    }

    private func newFolder() {
        name = ""
        naming = Naming(title: "Новая папка", button: "Создать") { try await browser.makeDirectory($0) }
    }

    private func askDelete(_ entries: [SFTPEntry]) {
        perform { deleting = (entries, try await browser.countForDelete(entries)) }
    }

    private func download(_ entries: [SFTPEntry]) {
        for entry in entries where !entry.isDirectory {
            browser.transfers.download(entry, to: Downloads.shared.directory)
        }
    }

    /// The picked files are copied in while their access lasts; the queue reads the copies later.
    /// Files only; folders aren't uploaded in this version.
    private func upload(_ urls: [URL]) {
        let dir = browser.path
        let queue = browser.transfers
        for url in urls where !url.hasDirectoryPath {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // ponytail: copies stay in tmp until iOS clears it; delete after the upload if space matters.
            let copy = FileManager.default.temporaryDirectory
                .appending(path: "upload-\(UUID().uuidString)", directoryHint: .isDirectory)
                .appending(path: url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                failure = "Не удалось прочитать «\(url.lastPathComponent)»: \(error.localizedDescription)"
                continue
            }
            queue.upload(copy, to: dir) { await queue.ask($0) }
        }
    }

    /// Runs an action; its error shows in an alert.
    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { failure = SFTPBrowser.message(for: error) }
        }
    }

    private func isPresent<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    /// «rwxr-x---».
    static func rwx(_ mode: UInt32) -> String {
        (0..<9).map { bit in mode & (0o400 >> UInt32(bit)) != 0 ? Array("rwx")[bit % 3] : "-" }.map(String.init).joined()
    }

    private struct Naming: Identifiable {
        let id = UUID()
        let title: String
        let button: String
        let apply: (String) async throws -> Void
    }

    private struct Editing: Identifiable {
        let entry: SFTPEntry
        let text: String
        var id: String { entry.id }
    }
}

/// The transfers under the list: progress, speed, cancel, «Повторить», and a name clash to answer.
private struct TransfersStrip: View {
    let queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Передачи").font(.footnote.weight(.semibold))
                Spacer()
                Button("Очистить") { queue.clear() }
                    .font(.footnote)
                    .disabled(!queue.items.contains { ![.queued, .running].contains($0.state) })
            }
            // Inline rather than an alert: it stays answerable whatever else is on screen.
            if let clash = queue.clash {
                VStack(alignment: .leading, spacing: 6) {
                    Text(clash.isFolder ? "Папка «\(clash.name)» уже есть здесь" : "«\(clash.name)» уже есть в этой папке")
                        .font(.footnote.weight(.medium)).lineLimit(2)
                    HStack {
                        // A folder can't be replaced by a file.
                        if !clash.isFolder { Button("Заменить") { queue.answer(.replace) } }
                        Button("Оставить оба") { queue.answer(.keepBoth) }
                        Button("Пропустить") { queue.answer(.skip) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(queue.items) { item in row(item) }
                }
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private func row(_ item: TransferQueue.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.footnote).lineLimit(1).truncationMode(.middle)
                if item.state == .running {
                    ProgressView(value: Double(item.bytesDone), total: Double(max(item.bytesTotal, 1)))
                }
                Text(detail(item)).font(.caption2).foregroundStyle(isFailed(item) ? .red : .secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            switch item.state {
            case .queued, .running:
                Button { queue.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Отменить")
            case .failed, .cancelled:
                Button("Повторить") { queue.retry(item.id) }.font(.footnote)
            case .done:
                EmptyView()
            }
        }
    }

    private func isFailed(_ item: TransferQueue.Item) -> Bool {
        if case .failed = item.state { true } else { false }
    }

    private func detail(_ item: TransferQueue.Item) -> String {
        let size = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        switch item.state {
        case .queued: return "В очереди"
        case .running:
            let speed = item.bytesPerSecond > 0 ? " · \(size(UInt64(item.bytesPerSecond)))/с" : ""
            return "\(size(item.bytesDone)) из \(size(item.bytesTotal))\(speed)"
        case .done: return item.direction == .download ? "Готово · \(size(item.bytesTotal)) · в «Файлах»" : "Готово · \(size(item.bytesTotal))"
        case .failed(let message): return "Ошибка: \(message)"
        case .cancelled: return "Отменено"
        }
    }
}

/// A remote text file in a plain monospace editor. A failed save keeps the text and says why.
private struct TextEditorSheet: View {
    let name: String
    let save: (String) async throws -> Void
    @State private var text: String
    @State private var saved: String
    @State private var isSaving = false
    @State private var error: String?
    @State private var isConfirmingClose = false
    @Environment(\.dismiss) private var dismiss

    init(name: String, text: String, save: @escaping (String) async throws -> Void) {
        self.name = name
        self.save = save
        _text = State(initialValue: text)
        _saved = State(initialValue: text)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    Text("Не удалось сохранить: \(error)").font(.footnote).foregroundStyle(.red).padding(8)
                }
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { if text == saved { dismiss() } else { isConfirmingClose = true } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Сохранить") { Task { await write() } }.disabled(text == saved)
                    }
                }
            }
        }
        .interactiveDismissDisabled(text != saved)
        .confirmationDialog("Закрыть без сохранения?", isPresented: $isConfirmingClose, titleVisibility: .visible) {
            Button("Не сохранять", role: .destructive) { dismiss() }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func write() async {
        let snapshot = text
        isSaving = true
        defer { isSaving = false }
        do {
            try await save(snapshot)
            saved = snapshot
            error = nil
        } catch {
            self.error = SFTPBrowser.message(for: error)
        }
    }
}

/// «Права…»: read / write / execute for owner, group and others, kept in step with an octal field.
private struct PermissionsSheet: View {
    let entry: SFTPEntry
    let apply: (UInt32) -> Void
    @State private var mode: UInt32
    /// setuid, setgid and sticky: not shown, kept as they are.
    private let special: UInt32
    @State private var octal: String
    @Environment(\.dismiss) private var dismiss

    init(entry: SFTPEntry, apply: @escaping (UInt32) -> Void) {
        self.entry = entry
        self.apply = apply
        let mode = entry.permissions & 0o777
        special = entry.permissions & 0o7000
        _mode = State(initialValue: mode)
        _octal = State(initialValue: String(mode, radix: 8))
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Array(["Владелец", "Группа", "Остальные"].enumerated()), id: \.offset) { row, title in
                    Section(title) {
                        ForEach(Array(["Чтение", "Запись", "Выполнение"].enumerated()), id: \.offset) { column, right in
                            Toggle(right, isOn: bit(UInt32(0o400) >> UInt32(row * 3 + column)))
                        }
                    }
                }
                Section {
                    LabeledContent("Восьмеричный вид") {
                        TextField("644", text: $octal)
                            .font(.system(.body, design: .monospaced))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: octal) { _, text in
                                if let value = UInt32(text, radix: 8), value <= 0o777 { mode = value }
                            }
                    }
                }
            }
            .navigationTitle("Права «\(entry.name)»")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Применить") {
                        apply(special | mode)
                        dismiss()
                    }
                    .disabled(UInt32(octal, radix: 8).map { $0 > 0o777 } ?? true)
                }
            }
        }
    }

    private func bit(_ mask: UInt32) -> Binding<Bool> {
        Binding(
            get: { mode & mask != 0 },
            set: {
                mode = $0 ? mode | mask : mode & ~mask
                octal = String(mode, radix: 8)
            }
        )
    }
}
