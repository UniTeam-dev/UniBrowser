import AppKit
import SwiftUI

/// «Файлы» beside an SSH tab's terminal (⌘⇧F): the remote folder over SFTP, and the tab's transfers.
struct FilesPanel: View {
    let session: SSHSession
    let browser: SFTPBrowser

    @State private var selection = Set<SFTPEntry.ID>()
    @State private var failure: String?
    @State private var naming: Naming?
    @State private var name = ""
    @State private var deleting: (entries: [SFTPEntry], count: Int)?
    @State private var permissions: SFTPEntry?
    @State private var editing: Editing?
    @State private var notText: SFTPEntry?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = browser.error {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            table
            if !browser.transfers.items.isEmpty || browser.transfers.clash != nil {
                Divider()
                TransfersStrip(queue: browser.transfers)
            }
        }
        .background(.background)
        // A terminal `cd` moves the panel only while it follows; a (re)connect reloads what it shows.
        .task(id: session.cwd) {
            guard session.state == .connected, browser.followsTerminal else { return }
            await browser.followTerminal()
        }
        .task(id: session.state == .connected) {
            guard session.state == .connected else { return }
            if browser.followsTerminal { await browser.followTerminal() } else { await browser.reload() }
        }
        .alert(naming?.title ?? "", isPresented: isPresent($naming), presenting: naming) { naming in
            TextField("Имя", text: $name)
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
            Button("Скачать") { browser.transfers.download(entry, to: Downloads.shared.directory) }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Файлы").font(.headline)
                Spacer()
                Button { naming = Naming(title: "Новая папка", button: "Создать") { try await browser.makeDirectory($0) }; name = "" } label: {
                    Label("Новая папка", systemImage: "folder.badge.plus")
                }
                .help("Новая папка")
                Button { chooseUploads() } label: { Label("Загрузить…", systemImage: "square.and.arrow.up") }
                    .help("Загрузить…")
                Toggle(isOn: Binding(get: { browser.showHidden }, set: { browser.showHidden = $0 })) {
                    Label("Скрытые файлы", systemImage: browser.showHidden ? "eye.fill" : "eye")
                }
                .toggleStyle(.button)
                .help("Скрытые файлы")
                Button { Task { await browser.reload() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .help("Обновить")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(session.state != .connected)
            HStack(spacing: 4) {
                pathBar
                Button("↧ папка терминала") { Task { await browser.followTerminal() } }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .fixedSize()
                    .disabled(browser.followsTerminal || session.cwd == nil || session.state != .connected)
                    .help("Перейти в папку терминала и следовать за ней")
            }
        }
        .padding(8)
    }

    /// Each segment opens that folder.
    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 1 { Text("/").foregroundStyle(.tertiary) }
                    Button(segment.name) { Task { await browser.open(segment.path) } }
                        .buttonStyle(.borderless)
                        .foregroundStyle(index == segments.count - 1 ? .primary : .secondary)
                }
            }
            .font(.callout)
        }
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

    private var table: some View {
        Table(browser.entries, selection: $selection) {
            TableColumn("Имя") { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                        .foregroundStyle(entry.isDirectory ? Palette.accent : .secondary)
                        .overlay(alignment: .bottomTrailing) {
                            if entry.isSymlink { Image(systemName: "arrow.turn.up.right").font(.system(size: 7, weight: .bold)) }
                        }
                }
            }
            TableColumn("Размер") { entry in
                Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Изменён") { entry in
                Text(entry.modified?.formatted(date: .numeric, time: .shortened) ?? "").foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 95)
            TableColumn("Права") { entry in
                Text(Self.rwx(entry.permissions)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 75)
        }
        .contextMenu(forSelectionType: SFTPEntry.ID.self) { ids in
            menu(for: browser.entries.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            guard ids.count == 1, let entry = browser.entries.first(where: { ids.contains($0.id) }) else { return }
            open(entry)
        }
        .dropDestination(for: URL.self) { urls, _ in
            upload(urls)
            return !urls.isEmpty
        }
        .disabled(session.state != .connected)
    }

    @ViewBuilder
    private func menu(for entries: [SFTPEntry]) -> some View {
        if entries.isEmpty {
            Button("Новая папка…") { naming = Naming(title: "Новая папка", button: "Создать") { try await browser.makeDirectory($0) }; name = "" }
            Button("Загрузить…") { chooseUploads() }
        } else {
            let files = entries.filter { !$0.isDirectory }
            Button("Скачать") { for file in files { browser.transfers.download(file, to: Downloads.shared.directory) } }
                .disabled(files.isEmpty)
            if entries.count == 1, let entry = entries.first {
                Button("Переименовать…") {
                    name = entry.name
                    naming = Naming(title: "Переименовать «\(entry.name)»", button: "Переименовать") { try await browser.rename(entry, to: $0) }
                }
                Button("Права…") { permissions = entry }
            }
            Divider()
            Button("Удалить…") {
                perform { deleting = (entries, try await browser.countForDelete(entries)) }
            }
        }
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

    private func chooseUploads() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Загрузить в \(browser.path)"
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    /// Files only; folders aren't uploaded in this version.
    private func upload(_ urls: [URL]) {
        let dir = browser.path
        let queue = browser.transfers
        for url in urls where !url.hasDirectoryPath {
            queue.upload(url, to: dir) { await queue.ask($0) }
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

/// The transfers at the bottom of «Файлы»: progress, speed, cancel and «Повторить».
private struct TransfersStrip: View {
    let queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Передачи").font(.caption.weight(.semibold))
                Spacer()
                Button("Очистить") { queue.clear() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(!queue.items.contains { ![.queued, .running].contains($0.state) })
            }
            // Inline rather than an alert: it stays answerable whatever else is on screen.
            if let clash = queue.clash {
                VStack(alignment: .leading, spacing: 4) {
                    Text(clash.isFolder ? "Папка «\(clash.name)» уже есть здесь" : "«\(clash.name)» уже есть в этой папке")
                        .font(.caption.weight(.medium)).lineLimit(2)
                    HStack {
                        if !clash.isFolder { Button("Заменить") { queue.answer(.replace) } }
                        Button("Оставить оба") { queue.answer(.keepBoth) }
                        Button("Пропустить") { queue.answer(.skip) }
                    }
                    .controlSize(.small)
                }
                .padding(6)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(queue.items) { item in row(item) }
                }
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
    }

    private func row(_ item: TransferQueue.Item) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                if item.state == .running {
                    ProgressView(value: Double(item.bytesDone), total: Double(max(item.bytesTotal, 1)))
                        .controlSize(.small)
                }
                Text(detail(item)).font(.caption2).foregroundStyle(isFailed(item) ? .red : .secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            switch item.state {
            case .queued, .running:
                Button { queue.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Отменить")
            case .failed, .cancelled:
                Button("Повторить") { queue.retry(item.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
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
        case .done: return "Готово · \(size(item.bytesTotal))"
        case .failed(let message): return "Ошибка: \(message)"
        case .cancelled: return "Отменено"
        }
    }
}
