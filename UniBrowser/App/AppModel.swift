import AppKit
import Observation
import WebKit

/// Owns the long-lived objects and the window's transient UI state
/// (command palette, Ctrl+Tab switcher, sidebar width).
@MainActor
@Observable
final class AppModel {
    /// `address` starts with the current page's full URL, to read, copy or edit it.
    enum PaletteMode { case search, newTab, address }

    let passwords: PasswordsService
    let store: BrowserStore
    /// The link to paired iPhones: their proxy and the live mirror of this session.
    let viaMac = ViaMacHost()

    var paletteMode: PaletteMode?
    /// The sidebar as a 56 pt column of icons instead of the 290 pt list; kept across launches.
    var isSidebarCompact = UserDefaults.standard.bool(forKey: "sidebarCompact") {
        didSet { UserDefaults.standard.set(isSidebarCompact, forKey: "sidebarCompact") }
    }
    var isArchiveVisible = false
    var isExtensionsVisible = false
    var isPasswordsVisible = false
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
        self.init(passwords: PasswordsService(), siteSettings: .persistent(), isPrivate: false)
    }

    private init(passwords: PasswordsService, siteSettings: SiteSettingsStore, isPrivate: Bool) {
        self.passwords = passwords
        self.isPrivate = isPrivate
        self.store = BrowserStore(environment: WebEnvironment(passwords: passwords, siteSettings: siteSettings, isPrivate: isPrivate))
        installTabSwitcherMonitor()
        store.environment.onPeek = { [weak self] url in self?.openPeek(url) }
        guard !isPrivate else { return }
        viaMac.attach(store: store, passwords: passwords.fallback)
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
        AppModel(passwords: passwords, siteSettings: store.environment.siteSettings.privateCopy(), isPrivate: true)
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
        peek = PeekPage(url: url, sourceTabID: sourceTabID, configuration: store.environment.makeBaseConfiguration())
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

    func openPalette(_ mode: PaletteMode) {
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
