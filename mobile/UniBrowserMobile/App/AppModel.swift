import Foundation
import Observation

/// Root state: both browsing modes, the link to the Mac, and which mode is on screen.
@MainActor
@Observable
final class AppModel {
    var mode: BrowsingMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    let direct: MobileStore
    let viaMac: MobileStore
    let relay: MacRelay

    private static let modeKey = "browsingMode"

    init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(BrowsingMode.init(rawValue:)) ?? .direct
        direct = MobileStore(mode: .direct, environment: MobileWebEnvironment(mode: .direct))

        let relay = MacRelay()
        self.relay = relay

        let viaMacEnvironment = MobileWebEnvironment(mode: .viaMac)
        viaMacEnvironment.apply(proxies: relay.proxyConfigurations())
        relay.onProxiesChange = { [weak viaMacEnvironment] proxies in
            viaMacEnvironment?.apply(proxies: proxies)
        }
        viaMac = MobileStore(mode: .viaMac, environment: viaMacEnvironment)
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

    /// Wipes the via-Mac mode: its tabs, cookies, cache and storage.
    func eraseViaMacData() async {
        viaMac.removeAllTabs()
        await viaMac.environment.eraseWebsiteData()
    }
}
