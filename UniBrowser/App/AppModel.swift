import AppKit
import Observation
import WebKit

/// Owns the long-lived objects and the window's transient UI state
/// (command palette, Ctrl+Tab switcher, sidebar width).
@MainActor
@Observable
final class AppModel {
    /// `address` starts with the current page's full URL, to read, copy or edit it. `ssh` picks a saved SSH host.
    enum PaletteMode { case search, newTab, address, ssh }

    let passwords: PasswordsService
    let store: BrowserStore
    /// The link to paired iPhones: their proxy and the live mirror of this session.
    let viaMac = ViaMacHost()
    /// Visits and bookmarks of this Mac, shared with its via-Mac iPhones (docs/library-architecture.md).
    let history = HistoryStore(fileURL: LibraryFiles.url("history.sqlite"), deviceID: BrowserStore.deviceID)
    let bookmarks = BookmarkStore(fileURL: LibraryFiles.url("bookmarks.json"))
    /// Saved SSH servers (secrets in the keychain) and the server keys the user trusted;
    /// private windows share the main model's two stores (one object per file) and its history map.
    let sshHosts: SSHHostStore
    let knownHosts: KnownHostsStore
    @ObservationIgnored private let main: AppModel?
    /// Command history per SSH host, shared by that host's tabs so they don't overwrite each other's saves.
    @ObservationIgnored private var sshHistories: [UUID: CommandHistory] = [:]

    var paletteMode: PaletteMode?

    func sshHistory(for hostID: UUID) -> CommandHistory {
        if let main { return main.sshHistory(for: hostID) }
        if let history = sshHistories[hostID] { return history }
        let history = CommandHistory(fileURL: LibraryFiles.url("ssh-history/\(hostID.uuidString.lowercased()).json"))
        sshHistories[hostID] = history
        return history
    }
    /// The sidebar as a 56 pt column of icons instead of the 290 pt list; kept across launches.
    var isSidebarCompact = UserDefaults.standard.bool(forKey: "sidebarCompact") {
        didSet { UserDefaults.standard.set(isSidebarCompact, forKey: "sidebarCompact") }
    }
    var isArchiveVisible = false
    var isExtensionsVisible = false
    var isPasswordsVisible = false
    /// Set with `isPasswordsVisible`: open the «SSH» section on this host's form (a failed SSH tab's «Изменить сервер»).
    var passwordsSSHHost: UUID?
    /// «Файл → Импорт…»; also offered once on the first launch.
    var isImportVisible = false
    /// The ☆ / ⌘D bookmark editor in the address strip.
    var isBookmarkPopoverVisible = false
    /// The page shown over the window by ⌥+click or ⌥↵; nil when Peek is closed.
    var peek: PeekPage?
    var isTabMapVisible = false
    /// The ringed tab in the tab map; arrows move it, Space peeks at it, Return opens it.
    var mapSelection: UUID?
    /// The evening cleanup sheet; nil when it is closed.
    var cleanup: CleanupSession?

    struct CleanupSession {
        var queue: [UUID]
        var index = 0
        var remaining: [UUID] { Array(queue.dropFirst(index)) }
        var current: UUID? { queue.indices.contains(index) ? queue[index] : nil }
    }
    /// Index into `store.tabsByRecency` while Ctrl is held; nil when the switcher is closed.
    var switcherIndex: Int?

    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var lastConsumedKeyTimestamp: TimeInterval = 0

    /// A «Новое приватное окно» (⇧⌘N) model: its own store and in-memory site data, no
    /// session file, no history, not mirrored to the iPhone. `store.environment.isPrivate` too.
    let isPrivate: Bool
    /// The window this model drives; set by MainWindow. Keys in a private window go to its own model.
    @ObservationIgnored weak var window: NSWindow? {
        didSet { if isPrivate, let window { Self.privateWindows.add(window) } }
    }
    @ObservationIgnored private static let privateWindows = NSHashTable<NSWindow>.weakObjects()

    convenience init() {
        self.init(passwords: PasswordsService(), siteSettings: .persistent(), isPrivate: false, main: nil)
    }

    private init(passwords: PasswordsService, siteSettings: SiteSettingsStore, isPrivate: Bool, main: AppModel?) {
        self.passwords = passwords
        self.main = main
        sshHosts = main?.sshHosts ?? SSHHostStore(fileURL: LibraryFiles.url("ssh-hosts.json"), secrets: SSHSecretStore())
        knownHosts = main?.knownHosts ?? KnownHostsStore(fileURL: LibraryFiles.url("known-hosts.json"))
        self.isPrivate = isPrivate
        self.store = BrowserStore(environment: WebEnvironment(passwords: passwords, siteSettings: siteSettings, isPrivate: isPrivate))
        installTabSwitcherMonitor()
        // The stores are shared, so each model adds its own reaction to the previous ones.
        let previousRemoved = sshHosts.onRemoved
        sshHosts.onRemoved = { [weak self] ids in
            previousRemoved?(ids)
            guard let store = self?.store else { return }
            for tab in store.tabs.values where tab.url?.sshHostID.map(ids.contains) == true { tab.sleep() }
        }
        let previousSaved = sshHosts.onSaved
        sshHosts.onSaved = { [weak self] id in
            previousSaved?(id)
            guard let store = self?.store else { return }
            for tab in store.tabs.values where tab.url?.sshHostID == id && tab.sshSession?.state != .connected { tab.sleep() }
        }
        store.environment.onPeek = { [weak self] url in self?.openPeek(url) }
        guard !isPrivate else { return } // a private window keeps no history and isn't mirrored
        history.pruneForRetentionSetting()
        store.environment.history = history
        viaMac.attach(store: store, passwords: passwords.builtIn, history: history, bookmarks: bookmarks,
                      sshHosts: sshHosts, knownHosts: knownHosts)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                self?.offerCleanupIfDue()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    // MARK: - Private windows

    /// Shares the logins; permission decisions start from the saved ones and stay in memory.
    func makePrivateModel() -> AppModel {
        AppModel(passwords: passwords, siteSettings: store.environment.siteSettings.privateCopy(), isPrivate: true, main: main ?? self)
    }

    /// The private window closed: its pages go, and with the last reference its data store.
    func tearDown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        closePeek()
        for space in store.spaces { space.allTabIDs.forEach { store.tab($0)?.sleep() } }
    }

    /// Each window's keys go to its own model; windows that aren't private (iPhone, Settings) to the main one.
    private func owns(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window else { return !isPrivate }
        return isPrivate ? eventWindow === window : !Self.privateWindows.contains(eventWindow)
    }

    // MARK: - Evening cleanup

    private static let lastOfferedKey = "cleanupLastOffered"
    private static let snoozedUntilKey = "cleanupSnoozedUntil"

    /// Once a day after 18:00, or when a "remind tomorrow" time has come, if there is anything stale.
    func offerCleanupIfDue(now: Date = .now) {
        guard cleanup == nil else { return }
        let defaults = UserDefaults.standard
        let calendar = Calendar.current
        if let snoozedUntil = defaults.object(forKey: Self.snoozedUntilKey) as? Date {
            guard now >= snoozedUntil else { return }
        } else {
            guard calendar.component(.hour, from: now) >= 18 else { return }
            if let last = defaults.object(forKey: Self.lastOfferedKey) as? Date, calendar.isDate(last, inSameDayAs: now) { return }
        }
        let stale = store.staleLooseTabIDs(now: now)
        guard !stale.isEmpty else { return }
        defaults.set(now, forKey: Self.lastOfferedKey)
        defaults.removeObject(forKey: Self.snoozedUntilKey)
        cleanup = CleanupSession(queue: stale)
    }

    /// The "Вечерняя уборка" command: shows the sheet now, even if it is empty.
    func startCleanup() {
        paletteMode = nil
        cleanup = CleanupSession(queue: store.staleLooseTabIDs())
    }

    func archiveCurrentCleanupTab() {
        if let id = cleanup?.current { store.archiveTab(id) }
        advanceCleanup()
    }

    func advanceCleanup() {
        guard var session = cleanup else { return }
        session.index += 1
        // Skip tabs closed while the sheet was open.
        while let id = session.current, store.tab(id) == nil { session.index += 1 }
        cleanup = session.current == nil ? nil : session
    }

    func archiveAllCleanupTabs() {
        cleanup?.remaining.forEach(store.archiveTab)
        cleanup = nil
    }

    func remindCleanupTomorrow() {
        let calendar = Calendar.current
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now),
           let tenAM = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow) {
            UserDefaults.standard.set(tenAM, forKey: Self.snoozedUntilKey)
        }
        cleanup = nil
    }

    // MARK: - Tab map

    func openTabMap() {
        store.selectedTab?.captureThumbnail()
        if let split = store.activeSpace.split {
            [split.left, split.right].forEach { store.tab($0)?.captureThumbnail() }
        }
        mapSelection = store.activeSpace.selectedTabID ?? store.mapOrder.first
        paletteMode = nil
        isTabMapVisible = true
    }

    func selectFromMap(_ tabID: UUID) {
        store.select(tabID)
        isTabMapVisible = false
    }

    private func moveMapSelection(by step: Int) {
        let order = store.mapOrder
        guard !order.isEmpty else { return }
        let current = mapSelection.flatMap { order.firstIndex(of: $0) } ?? 0
        mapSelection = order[(current + step + order.count) % order.count]
    }

    /// Keys while the tab map is open. Handled here because the page behind it keeps keyboard focus.
    private func handleTabMapKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: isTabMapVisible = false // Esc
        case 49: // Space
            if let id = mapSelection, let url = store.tab(id)?.url { openPeek(url, sourceTabID: id) }
        case 36, 76: if let id = mapSelection { selectFromMap(id) } // Return
        case 123, 126: moveMapSelection(by: -1) // ← ↑
        case 124, 125: moveMapSelection(by: 1) // → ↓
        default: return event
        }
        return nil
    }

    // MARK: - Peek

    /// `sourceTabID` is set when peeking at an existing tab, so "Сделать вкладкой" selects it instead of duplicating.
    func openPeek(_ url: URL, sourceTabID: UUID? = nil) {
        guard url.sshHostID == nil else { return } // a terminal has no page to peek at
        peek = PeekPage(url: url, sourceTabID: sourceTabID, configuration: store.environment.makeBaseConfiguration(dataStore: store.environment.dataStore(forSpace: store.activeSpaceID)))
    }

    func closePeek() {
        peek?.webView.stopLoading()
        peek = nil
    }

    func peekToTab() {
        guard let peek else { return }
        if let id = peek.sourceTabID, store.tab(id) != nil {
            store.select(id)
        } else if let url = peek.url {
            store.newTab(url: url)
        }
        closePeek()
    }

    func peekToSplit() {
        guard let peek else { return }
        if let id = peek.sourceTabID, store.tab(id) != nil {
            store.openSplit(with: id)
        } else if let url = peek.url {
            store.openSplit(with: store.newTab(url: url, select: false).id)
        }
        closePeek()
    }

    /// First launch (no saved session yet): offers to bring bookmarks and history over, once.
    /// Called by the window a moment after it appears: a sheet asked for at launch gets dismissed.
    func offerImportIfFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "importOffered"), store.lastModified == .distantPast,
              store.spaces.allSatisfy({ $0.allTabIDs.isEmpty }) else { return }
        defaults.set(true, forKey: "importOffered")
        isImportVisible = true
    }

    /// A new tab opens the start page from «Настройки» when one is set.
    func openPalette(_ mode: PaletteMode) {
        if mode == .newTab, let url = HomePage.url {
            store.newTab(url: url)
            return
        }
        paletteMode = mode
    }

    /// F12 and ⌥⌘I: the selected tab's developer tools.
    func toggleDevTools() {
        store.selectedTab?.devTools?.toggle()
    }

    // MARK: - Ctrl+Tab by recency

    /// Ctrl+Tab opens the switcher on the previous tab, each further Tab moves on,
    /// Shift goes back, Esc cancels, and releasing Ctrl switches. A local event
    /// monitor sees the keys before the web view can swallow them.
    private func installTabSwitcherMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self, self.owns(event) else { return event }
            // The same keyDown can reach a local monitor twice (seen with synthesized input);
            // a key already consumed must not act again.
            if event.type == .keyDown, event.timestamp == self.lastConsumedKeyTimestamp { return nil }
            let result = self.handle(event)
            if event.type == .keyDown, result == nil { self.lastConsumedKeyTimestamp = event.timestamp }
            return result
        }
    }

    /// A click inside a split pane's web page makes that pane active. The web view
    /// takes the click itself, so SwiftUI never sees it.
    private func activateSplitPane(for event: NSEvent) {
        guard let split = store.activeSpace.split,
              var view = event.window?.contentView?.superview?.hitTest(event.locationInWindow)
        else { return }
        while !(view is WKWebView) {
            guard let parent = view.superview else { return }
            view = parent
        }
        for id in [split.left, split.right] where store.tab(id)?.webView === view && store.activeSpace.selectedTabID != id {
            store.select(id)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let tabs = store.tabsByRecency
        switch event.type {
        case .leftMouseDown:
            activateSplitPane(for: event)
            return event
        case .keyDown where event.keyCode == 111 && event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]): // F12
            toggleDevTools()
            return nil
        case .keyDown where event.keyCode == 48 && event.modifierFlags.contains(.control): // Tab
            guard tabs.count > 1 else { return nil }
            let step = event.modifierFlags.contains(.shift) ? -1 : 1
            let current = switcherIndex ?? 0
            switcherIndex = (current + step + tabs.count) % tabs.count
            return nil
        case .keyDown where event.keyCode == 53 && switcherIndex != nil: // Esc
            switcherIndex = nil
            return nil
        case .keyDown where event.keyCode == 53 && peek != nil:
            closePeek()
            return nil
        case .keyDown where cleanup != nil && peek == nil:
            switch event.keyCode {
            case 53: cleanup = nil
            case 123 where cleanup?.current != nil: archiveCurrentCleanupTab()
            case 124 where cleanup?.current != nil: advanceCleanup()
            default: return event
            }
            return nil
        case .keyDown where isTabMapVisible && peek == nil:
            return handleTabMapKey(event)
        case .flagsChanged where switcherIndex != nil && !event.modifierFlags.contains(.control):
            if let index = switcherIndex, tabs.indices.contains(index) {
                store.select(tabs[index].id)
            }
            switcherIndex = nil
            return event
        default:
            return event
        }
    }
}
