import AppKit
import Observation

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
    /// Index into `store.tabsByRecency` while Ctrl is held; nil when the switcher is closed.
    var switcherIndex: Int?

    @ObservationIgnored private var keyMonitor: Any?

    init() {
        let passwords = PasswordsService()
        self.passwords = passwords
        self.store = BrowserStore(environment: WebEnvironment(passwords: passwords))
        installTabSwitcherMonitor()
    }

    func openPalette(_ mode: PaletteMode) {
        paletteMode = mode
    }

    // MARK: - Ctrl+Tab by recency

    /// Ctrl+Tab opens the switcher on the previous tab, each further Tab moves on,
    /// Shift goes back, Esc cancels, and releasing Ctrl switches. A local event
    /// monitor sees the keys before the web view can swallow them.
    private func installTabSwitcherMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleSwitcherEvent(event) ?? event
        }
    }

    private func handleSwitcherEvent(_ event: NSEvent) -> NSEvent? {
        let tabs = store.tabsByRecency
        switch event.type {
        case .keyDown where event.keyCode == 48 && event.modifierFlags.contains(.control): // Tab
            guard tabs.count > 1 else { return nil }
            let step = event.modifierFlags.contains(.shift) ? -1 : 1
            let current = switcherIndex ?? 0
            switcherIndex = (current + step + tabs.count) % tabs.count
            return nil
        case .keyDown where event.keyCode == 53 && switcherIndex != nil: // Esc
            switcherIndex = nil
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
