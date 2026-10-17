import AppKit
import Observation
import WebKit

/// Web extensions (the Safari/Chrome WebExtensions format) through WebKit's
/// WKWebExtensionController: installs from an unpacked folder or the Chrome Web Store,
/// asks for permissions once at install, and remembers what is installed.
@MainActor
@Observable
final class ExtensionManager: NSObject {
    /// What is installed, saved in extensions.json. `id` doubles as the context's
    /// uniqueIdentifier, so the extension keeps its storage across launches.
    struct Record: Codable, Identifiable, Hashable {
        var id: String
        /// An unpacked folder, or the ZIP saved from the Chrome Web Store.
        var path: String
        var isEnabled = true
        var storeID: String?
        /// Shown while the extension is off and not loaded.
        var name: String?
        var grantedPermissions: [String] = []
        var grantedMatchPatterns: [String] = []
    }

    private(set) var records: [Record] = []
    /// Loaded contexts by record ID.
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    private(set) var isInstalling = false
    var lastError: String?
    /// Bumped when an extension changes its button (icon, badge), so the bar redraws.
    private(set) var actionRevision = 0

    @ObservationIgnored let controller: WKWebExtensionController
    @ObservationIgnored weak var store: BrowserStore?
    @ObservationIgnored private var tabs: [UUID: ExtensionTab] = [:]
    @ObservationIgnored private lazy var window = ExtensionWindow(manager: self)
    /// The bar buttons, so a popup opens under the button that was clicked.
    @ObservationIgnored var popupAnchors: [String: NSView] = [:]

    init(dataStore: WKWebsiteDataStore) {
        let configuration = WKWebExtensionController.Configuration.default()
        configuration.defaultWebsiteDataStore = dataStore
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        records = Self.loadRecords()
    }

    func name(of record: Record) -> String {
        contexts[record.id]?.webExtension.displayName ?? record.name ?? URL(filePath: record.path).deletingPathExtension().lastPathComponent
    }

    // MARK: - Loading

    func loadAll() async {
        for record in records where record.isEnabled {
            do {
                try await load(record)
            } catch {
                lastError = "«\(name(of: record))» не загрузилось: \(error.localizedDescription)"
            }
        }
    }

    private func load(_ record: Record) async throws {
        let webExtension = try await WKWebExtension(resourceBaseURL: URL(filePath: record.path))
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = record.id
        context.isInspectable = true
        for permission in record.grantedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
        }
        for pattern in record.grantedMatchPatterns {
            if let matchPattern = try? WKWebExtension.MatchPattern(string: pattern) {
                context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
            }
        }
        try controller.load(context)
        contexts[record.id] = context
    }

    // MARK: - Installing

    /// An unpacked extension folder (with manifest.json), loaded in place like Chrome's "Load unpacked".
    func installFolder(_ url: URL) async {
        await install(path: url.path(percentEncoded: false), storeID: nil)
    }

    /// A Chrome Web Store link or extension ID: downloads the CRX, strips its header and keeps the ZIP.
    func installFromStore(_ input: String) async {
        guard let id = CRX.storeID(from: input) else {
            lastError = "Не похоже на ссылку Chrome Web Store или ID расширения."
            return
        }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: CRX.downloadURL(for: id))
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                lastError = "Chrome Web Store не отдал расширение \(id)."
                return
            }
            let zip = try CRX.zipPayload(of: data)
            let file = Self.directory.appending(path: "\(id).zip")
            try zip.write(to: file, options: .atomic)
            await install(path: file.path(percentEncoded: false), storeID: id)
        } catch {
            lastError = "Не удалось скачать расширение: \(error.localizedDescription)"
        }
    }

    private func install(path: String, storeID: String?) async {
        lastError = nil
        let webExtension: WKWebExtension
        do {
            webExtension = try await WKWebExtension(resourceBaseURL: URL(filePath: path))
        } catch {
            lastError = "Это не расширение: \(error.localizedDescription)"
            return
        }
        let name = webExtension.displayName ?? "Расширение"
        guard askToInstall(webExtension, name: name) else { return }

        if let existing = records.firstIndex(where: { $0.path == path || ($0.storeID != nil && $0.storeID == storeID) }) {
            remove(records[existing].id)
        }
        var record = Record(id: UUID().uuidString, path: path, storeID: storeID, name: name)
        record.grantedPermissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
        record.grantedMatchPatterns = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
        do {
            try await load(record)
            records.append(record)
            saveRecords()
        } catch {
            lastError = "«\(name)» не загрузилось: \(error.localizedDescription)"
        }
    }

    /// The per-extension permission prompt shown once at install.
    private func askToInstall(_ webExtension: WKWebExtension, name: String) -> Bool {
        let permissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
        let sites = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
        var lines: [String] = []
        if !permissions.isEmpty { lines.append("Возможности: " + permissions.joined(separator: ", ")) }
        if !sites.isEmpty { lines.append("Сайты: " + sites.joined(separator: ", ")) }
        let alert = NSAlert()
        alert.messageText = "Установить «\(name)»?"
        alert.informativeText = lines.isEmpty ? "Расширению не нужны особые разрешения." : lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Установить")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func setEnabled(_ id: String, _ isEnabled: Bool) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isEnabled = isEnabled
        saveRecords()
        if isEnabled {
            do { try await load(records[index]) } catch { lastError = error.localizedDescription }
        } else if let context = contexts.removeValue(forKey: id) {
            try? controller.unload(context)
        }
    }

    func remove(_ id: String) {
        if let context = contexts.removeValue(forKey: id) { try? controller.unload(context) }
        if let record = records.first(where: { $0.id == id }), record.storeID != nil {
            try? FileManager.default.removeItem(atPath: record.path)
        }
        records.removeAll { $0.id == id }
        saveRecords()
    }

    // MARK: - Toolbar buttons

    /// Loaded extensions with a toolbar button, in install order.
    var actionContexts: [(id: String, context: WKWebExtensionContext)] {
        _ = actionRevision
        return records.compactMap { record in contexts[record.id].map { (record.id, $0) } }
    }

    func action(for context: WKWebExtensionContext) -> WKWebExtension.Action? {
        context.action(for: store?.selectedTab.map(adapter))
    }

    func performAction(_ id: String) {
        guard let context = contexts[id] else { return }
        context.performAction(for: store?.selectedTab.map(adapter))
    }

    // MARK: - Tab events from BrowserStore

    func adapter(for tab: BrowserTab) -> ExtensionTab {
        if let existing = tabs[tab.id] { return existing }
        let adapter = ExtensionTab(tabID: tab.id, manager: self)
        tabs[tab.id] = adapter
        return adapter
    }

    func tabOpened(_ tab: BrowserTab) {
        controller.didOpenTab(adapter(for: tab))
    }

    func tabClosed(_ tabID: UUID) {
        guard let adapter = tabs.removeValue(forKey: tabID) else { return }
        controller.didCloseTab(adapter)
    }

    func tabActivated(_ tab: BrowserTab, previous: BrowserTab?) {
        controller.didActivateTab(adapter(for: tab), previousActiveTab: previous.map(adapter))
    }

    func tabChanged(_ tab: BrowserTab) {
        controller.didChangeTabProperties([.URL, .title, .loading], for: adapter(for: tab))
    }

    fileprivate var windowAdapter: ExtensionWindow { window }

    // MARK: - Persistence

    static var directory: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "UniBrowser/Extensions", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var recordsURL: URL { directory.appending(path: "extensions.json") }

    private static func loadRecords() -> [Record] {
        guard let data = try? Data(contentsOf: recordsURL) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private func saveRecords() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.recordsURL, options: .atomic)
        }
    }

    /// Permissions granted later (optional permissions) are saved with the record.
    fileprivate func remember(_ context: WKWebExtensionContext) {
        guard let index = records.firstIndex(where: { $0.id == context.uniqueIdentifier }) else { return }
        records[index].grantedPermissions = context.grantedPermissions.keys.map(\.rawValue).sorted()
        records[index].grantedMatchPatterns = context.grantedPermissionMatchPatterns.keys.map(\.string).sorted()
        saveRecords()
    }

    fileprivate func ask(_ question: String, details: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = details.joined(separator: "\n")
        alert.addButton(withTitle: "Разрешить")
        alert.addButton(withTitle: "Отклонить")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - WKWebExtensionControllerDelegate

extension ExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionTab)? {
        guard let store else { return nil }
        return adapter(for: store.newTab(url: configuration.url, select: configuration.shouldBeActive))
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionWindow)? {
        // One window: the new "window" opens as tabs here.
        for url in configuration.tabURLs { store?.newTab(url: url) }
        return window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        if let url = extensionContext.optionsPageURL { store?.newTab(url: url) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.Permission>, Date?) {
        let name = extensionContext.webExtension.displayName ?? "Расширение"
        let allowed = ask("«\(name)» просит дополнительные разрешения", details: permissions.map(\.rawValue).sorted())
        defer { remember(extensionContext) }
        return (allowed ? permissions : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext
    ) async -> (Set<URL>, Date?) {
        let name = extensionContext.webExtension.displayName ?? "Расширение"
        let allowed = ask("«\(name)» просит доступ к сайтам", details: urls.compactMap { $0.host() }.sorted())
        defer { remember(extensionContext) }
        return (allowed ? urls : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let name = extensionContext.webExtension.displayName ?? "Расширение"
        let allowed = ask("«\(name)» просит доступ к сайтам", details: matchPatterns.map(\.string).sorted())
        defer { remember(extensionContext) }
        return (allowed ? matchPatterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actionRevision += 1
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext
    ) async throws {
        guard let popover = action.popupPopover else { return }
        let anchor = popupAnchors[context.uniqueIdentifier] ?? NSApp.keyWindow?.contentView
        guard let anchor else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}

// MARK: - Tab and window adapters

/// A BrowserTab as WebKit's extension APIs see it (chrome.tabs).
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    let tabID: UUID
    private weak var manager: ExtensionManager?

    init(tabID: UUID, manager: ExtensionManager) {
        self.tabID = tabID
        self.manager = manager
    }

    private var store: BrowserStore? { manager?.store }
    private var tab: BrowserTab? { store?.tab(tabID) }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { manager?.windowAdapter }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        store?.activeSpace.allTabIDs.firstIndex(of: tabID) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.webView }
    func title(for context: WKWebExtensionContext) -> String? { tab?.displayTitle }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { store?.activeSpace.selectedTabID == tabID }
    func isPinned(for context: WKWebExtensionContext) -> Bool { store?.activeSpace.pinnedTabIDs.contains(tabID) ?? false }

    func activate(for context: WKWebExtensionContext) async throws { store?.select(tabID) }
    func close(for context: WKWebExtensionContext) async throws { store?.closeTab(tabID) }
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws { tab?.load(url) }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        if fromOrigin { tab?.webView?.reloadFromOrigin() } else { tab?.webView?.reload() }
    }
    func goBack(for context: WKWebExtensionContext) async throws { tab?.webView?.goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { tab?.webView?.goForward() }
}

/// The one browser window, holding the active space's tabs (chrome.windows).
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    private weak var manager: ExtensionManager?

    init(manager: ExtensionManager) {
        self.manager = manager
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let manager, let store = manager.store else { return [] }
        return store.activeSpace.allTabIDs.compactMap { store.tab($0) }.map { manager.adapter(for: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let manager, let tab = manager.store?.selectedTab else { return nil }
        return manager.adapter(for: tab)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { NSApp.mainWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { NSApp.mainWindow?.screen?.frame ?? .null }
    func focus(for context: WKWebExtensionContext) async throws { NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
}
