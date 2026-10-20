import Foundation
import Observation

/// Root state: both browsing modes, the logins, the link to the Mac, and which mode is on screen.
@MainActor
@Observable
final class AppModel {
    var mode: BrowsingMode {
        // Private isn't remembered: a relaunch opens the normal mode.
        didSet { UserDefaults.standard.set(mode == .private ? BrowsingMode.direct.rawValue : mode.rawValue, forKey: Self.modeKey) }
    }

    let passwords: PhonePasswords
    let direct: MobileStore
    /// The Mac's spaces, groups and tabs, mirrored live while connected.
    let viaMac: MobileStore
    let relay: MacRelay
    /// Saved per-site decisions, shared by the normal and via-Mac modes.
    let siteSettings = SiteSettingsStore.persistent()
    /// Saved SSH servers and trusted server keys: one set for the whole app, not per mode.
    let sshHosts = SSHHostStore(fileURL: LibraryFiles.url("ssh-hosts.json"), secrets: SSHSecretStore())
    let knownHosts = KnownHostsStore(fileURL: LibraryFiles.url("known-hosts.json"))
    /// «Приватный»: replaced, with its in-memory cookies, each time the user leaves it.
    private(set) var privateStore: MobileStore
    /// Command history per SSH host, shared by that host's tabs so they don't overwrite each other's saves.
    @ObservationIgnored private var sshHistories: [UUID: CommandHistory] = [:]
    /// SSH tabs whose session was closed when the app went to the background; they log in again on return.
    @ObservationIgnored private var sshTabsToResume: [MobileTab] = []

    private static let modeKey = "browsingMode"

    init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(BrowsingMode.init(rawValue:)) ?? .direct
        let passwords = PhonePasswords()
        self.passwords = passwords
        direct = MobileStore(mode: .direct, environment: MobileWebEnvironment(mode: .direct, passwords: passwords, siteSettings: siteSettings))
        privateStore = Self.makePrivateStore(passwords: passwords, siteSettings: siteSettings)

        let relay = MacRelay()
        self.relay = relay

        let viaMacEnvironment = MobileWebEnvironment(mode: .viaMac, passwords: passwords, siteSettings: siteSettings)
        viaMacEnvironment.apply(proxies: MacRelay.proxyConfigurations())
        viaMac = MobileStore(mode: .viaMac, environment: viaMacEnvironment)
        relay.attach(store: viaMac, passwords: passwords, sshHosts: sshHosts, knownHosts: knownHosts)

        // A deleted server's tabs close their session and say «Сервер удалён из хранилища».
        sshHosts.onRemoved = { [weak self] ids in
            for tab in self?.sshTabs ?? [] where tab.url?.sshHostID.map(ids.contains) == true { tab.sleep() }
        }
        // Like via-Mac pages that failed before the link was up (commit 0bdfaeb): log in again once it is.
        relay.onLinkEstablished = { [weak self] in
            for tab in self?.sshTabs ?? [] where tab.sshSession?.state == .failed(SSHSession.noMacLinkMessage) {
                tab.sshTerminal?.connect()
            }
        }
    }

    /// Every SSH tab of every mode.
    var sshTabs: [MobileTab] {
        [direct, viaMac, privateStore].flatMap { $0.tabs.values.filter(\.isSSH) }
    }

    func sshHistory(for hostID: UUID) -> CommandHistory {
        if let history = sshHistories[hostID] { return history }
        let history = CommandHistory(fileURL: LibraryFiles.url("ssh-history/\(hostID.uuidString.lowercased()).json"))
        sshHistories[hostID] = history
        return history
    }

    /// iOS drops the app's sockets in the background (no background modes): close the sessions now.
    func closeSSHSessionsForBackground() {
        sshTabsToResume = sshTabs.filter { tab in
            guard let session = tab.sshSession else { return false }
            switch session.state {
            case .closed, .failed: return false
            default: break
            }
            session.close()
            return true
        }
    }

    /// Back on screen: the tabs closed for the background log in again, «Новая сессия» in their status line.
    func resumeSSHSessions() {
        for tab in sshTabsToResume where tab.sshSession != nil {
            tab.isNewSSHSession = true
            tab.sshTerminal?.connect()
        }
        sshTabsToResume = []
    }

    var store: MobileStore {
        switch mode {
        case .direct: direct
        case .viaMac: viaMac
        case .private: privateStore
        }
    }

    private static func makePrivateStore(passwords: PhonePasswords, siteSettings: SiteSettingsStore) -> MobileStore {
        MobileStore(mode: .private, environment: MobileWebEnvironment(mode: .private, passwords: passwords, siteSettings: siteSettings.privateCopy()))
    }

    func switchMode(to newMode: BrowsingMode) {
        guard newMode != mode else { return }
        // Only the visible mode keeps a live page.
        store.selectedTab?.sleep()
        // Leaving private mode closes its tabs; a fresh store on entering forgets the old
        // cookies and storage and starts from the site decisions saved by now.
        if mode == .private { privateStore.removeAllTabs() }
        if newMode == .private { privateStore = Self.makePrivateStore(passwords: passwords, siteSettings: siteSettings) }
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
