import AppKit
import Observation
import WebKit

/// Owns the long-lived objects and the window's transient UI state
/// (command palette, Ctrl+Tab switcher, sidebar visibility).
@MainActor
@Observable
final class AppModel {
    enum PaletteMode { case search, newTab }

    let passwords: PasswordsService
    let store: BrowserStore

    var paletteMode: PaletteMode?
    var isSidebarVisible = true
    var isArchiveVisible = false
    /// The page shown over the window by ⌥+click or ⌥↵; nil when Peek is closed.
    var peek: PeekPage?
    /// Index into `store.tabsByRecency` while Ctrl is held; nil when the switcher is closed.
    var switcherIndex: Int?

    @ObservationIgnored private var keyMonitor: Any?

    init() {
        let passwords = PasswordsService()
        self.passwords = passwords
        self.store = BrowserStore(environment: WebEnvironment(passwords: passwords))
        installTabSwitcherMonitor()
        store.environment.onPeek = { [weak self] url in self?.openPeek(url) }
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

    // MARK: - Ctrl+Tab by recency

    /// Ctrl+Tab opens the switcher on the previous tab, each further Tab moves on,
    /// Shift goes back, Esc cancels, and releasing Ctrl switches. A local event
    /// monitor sees the keys before the web view can swallow them.
    private func installTabSwitcherMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
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
