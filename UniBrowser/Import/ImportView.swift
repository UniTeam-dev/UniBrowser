import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where imported items land: bookmarks in a new root folder (`folder`, with the source's
/// folders inside it), visits in this Mac's history (they sync to the iPhone like its own).
/// Returns how many were added.
@MainActor
enum ImportSink {
    static func add(_ bookmarks: [ImportedBookmark], folder: String, model: AppModel) -> Int {
        guard !bookmarks.isEmpty else { return 0 }
        let store = model.bookmarks
        var folders: [[String]: UUID] = [[]: store.addFolder(title: folder).id]
        func folderID(_ path: [String]) -> UUID {
            if let id = folders[path] { return id }
            let id = store.addFolder(title: path.last ?? "", in: folderID(Array(path.dropLast()))).id
            folders[path] = id
            return id
        }
        for bookmark in bookmarks {
            _ = store.add(url: bookmark.url, title: bookmark.title, in: folderID(bookmark.folderPath))
        }
        return bookmarks.count
    }

    static func add(_ visits: [ImportedVisit], model: AppModel) -> Int {
        let deviceID = model.history.deviceID
        model.history.merge(visits.map {
            Visit(id: UUID(), url: $0.url, title: $0.title, visitedAt: $0.visitedAt, deviceID: deviceID)
        })
        return visits.count
    }
}

/// «Файл → Импорт…» and the first-run offer: bookmarks, history and passwords from Chrome and Safari,
/// or bookmarks from any browser's HTML export.
struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Source: String, CaseIterable, Identifiable {
        case chrome, safari, html
        var id: Self { self }
        var title: String {
            switch self {
            case .chrome: "Chrome"
            case .safari: "Safari"
            case .html: "HTML-файл"
            }
        }
    }

    @State private var source = Source.chrome
    @State private var profiles = BrowserImport.chromeProfiles()
    @State private var profile: BrowserImport.ChromeProfile?
    @State private var canReadSafariHistory = BrowserImport.canRead(BrowserImport.safariHistory)
    @State private var isWorking = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Импорт из другого браузера").font(.title2.weight(.semibold))
            Picker("Откуда", selection: $source) {
                ForEach(Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch source {
                case .chrome: chrome
                case .safari: safari
                case .html: html
                }
            }
            .disabled(isWorking)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                if let result { Text(result).foregroundStyle(.secondary) }
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { profile = profile ?? profiles.first }
        .onChange(of: source) { result = nil }
        // Back from System Settings with Full Disk Access granted: the button appears without reopening.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            canReadSafariHistory = BrowserImport.canRead(BrowserImport.safariHistory)
        }
    }

    // MARK: - Sources

    @ViewBuilder private var chrome: some View {
        if profiles.isEmpty {
            Text("Chrome не найден на этом Mac.").foregroundStyle(.secondary)
        } else {
            if profiles.count > 1 {
                Picker("Профиль", selection: $profile) {
                    ForEach(profiles) { Text($0.name).tag(Optional($0)) }
                }
                .fixedSize()
            }
            HStack {
                Button("Импортировать закладки") { if let profile { importChromeBookmarks(profile) } }
                Button("Импортировать историю") { if let profile { importChromeHistory(profile) } }
            }
            Divider()
            Text("Пароли").font(.headline)
            Text("Chrome не отдаёт пароли другим программам. Откройте в Chrome chrome://password-manager/settings, нажмите «Экспортировать пароли», сохраните CSV-файл и выберите его здесь. После импорта удалите файл: пароли в нём не зашифрованы.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Выбрать CSV с паролями…", action: importPasswords)
        }
    }

    @ViewBuilder private var safari: some View {
        Text("Закладки").font(.headline)
        Text("В Safari выберите «Файл → Экспортировать → Закладки…», сохраните файл и укажите его здесь.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Button("Выбрать файл закладок…") { importHTML(folder: "Импорт из Safari") }
        Divider()
        Text("История").font(.headline)
        if canReadSafariHistory {
            Button("Импортировать историю Safari", action: importSafariHistory)
        } else {
            Text("macOS пускает к истории Safari только с «Полным доступом к диску». Включите UniBrowser в списке и вернитесь сюда.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Открыть «Полный доступ к диску»") { NSWorkspace.shared.open(BrowserImport.fullDiskAccessSettings) }
        }
    }

    @ViewBuilder private var html: some View {
        Text("Файл закладок в формате HTML, который сохраняют Safari, Chrome, Firefox, Edge и другие браузеры.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Button("Выбрать HTML-файл…") { importHTML(folder: "Импорт закладок") }
    }

    // MARK: - Actions

    private var historySince: Date {
        let days = UserDefaults.standard.object(forKey: SettingsKeys.historyRetentionDays) as? Int ?? 90
        return days == 0 ? .distantPast : Date.now.addingTimeInterval(-Double(days) * 86400)
    }

    private func importChromeBookmarks(_ profile: BrowserImport.ChromeProfile) {
        guard let data = try? Data(contentsOf: profile.bookmarks) else { return result = "В профиле нет закладок." }
        let added = ImportSink.add(BrowserImport.chromeBookmarks(json: data), folder: "Импорт из Chrome", model: model)
        result = "Закладок: \(added)"
    }

    private func importChromeHistory(_ profile: BrowserImport.ChromeProfile) {
        let database = profile.history
        let since = historySince
        run { try BrowserImport.readCopy(of: database) { try BrowserImport.chromeHistory(databaseAt: $0, since: since) } }
    }

    private func importSafariHistory() {
        let since = historySince
        run { try BrowserImport.readCopy(of: BrowserImport.safariHistory) { try BrowserImport.safariHistory(databaseAt: $0, since: since) } }
    }

    /// Reads a history database off the main thread, then hands the visits to the library.
    private func run(_ read: @escaping @Sendable () throws -> [ImportedVisit]) {
        isWorking = true
        result = nil
        Task {
            let visits = await Task.detached { Result(catching: read) }.value
            isWorking = false
            switch visits {
            case .success(let visits): result = "Посещений: \(ImportSink.add(visits, model: model))"
            case .failure(let error): result = error.localizedDescription
            }
        }
    }

    private func importHTML(folder: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.message = "Файл закладок (HTML)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else { return result = "Не удалось прочитать файл." }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let bookmarks = BrowserImport.netscapeBookmarks(html: text)
        result = bookmarks.isEmpty ? "В файле не нашлось закладок." : "Закладок: \(ImportSink.add(bookmarks, folder: folder, model: model))"
    }

    /// Chrome's export has name,url,username,password,note: the Passwords CSV import reads it as is.
    private func importPasswords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text]
        panel.message = "CSV, экспортированный из Chrome"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = model.passwords.builtIn
        Task {
            do {
                let count = try await store.importCSV(try String(contentsOf: url, encoding: .utf8))
                result = count == 0 ? "В файле не нашлось логинов." : "Паролей: \(count)"
            } catch {
                result = error.localizedDescription
            }
        }
    }
}
