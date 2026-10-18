import Foundation
import Observation

/// Root state: both browsing modes, the logins, the link to the Mac, and which mode is on screen.
@MainActor
@Observable
final class AppModel {
    var mode: BrowsingMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    let passwords: PhonePasswords
    let direct: MobileStore
    /// The Mac's spaces, groups and tabs, mirrored live while connected.
    let viaMac: MobileStore
    let relay: MacRelay

    private static let modeKey = "browsingMode"

    init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(BrowsingMode.init(rawValue:)) ?? .direct
        let passwords = PhonePasswords()
        self.passwords = passwords
        direct = MobileStore(mode: .direct, environment: MobileWebEnvironment(mode: .direct, passwords: passwords))

        let relay = MacRelay()
        self.relay = relay

        let viaMacEnvironment = MobileWebEnvironment(mode: .viaMac, passwords: passwords)
        viaMacEnvironment.apply(proxies: MacRelay.proxyConfigurations())
        viaMac = MobileStore(mode: .viaMac, environment: viaMacEnvironment)
        relay.attach(store: viaMac, passwords: passwords)
    }

    var store: MobileStore {
        switch mode {
        case .direct: direct
        case .viaMac: viaMac
        }
    }

    func switchMode(to newMode: BrowsingMode) {
        guard newMode != mode else { return }
        // Only the visible mode keeps a live page.
        store.selectedTab?.sleep()
        mode = newMode
    }

    func saveAll() {
        direct.saveNow()
        viaMac.saveNow()
    }

    /// Wipes the via-Mac mode on this phone: its copy of the tabs, cookies,
    /// cache, storage and the logins from the Mac. The Mac keeps everything and
    /// sends the tabs and logins again on the next connection.
    func eraseViaMacData() async {
        viaMac.removeAllTabs()
        passwords.eraseAll()
        // Local only: history deletions don't sync, so the Mac keeps its copy.
        viaMac.history?.deleteAll()
        await viaMac.environment.eraseWebsiteData()
    }
}
