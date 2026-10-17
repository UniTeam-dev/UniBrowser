import Foundation
import Network
import Observation
import UIKit

/// The phone's side of the link to the Mac: the paired Mac, the connection,
/// which domains go through it, and the live mirror of the Mac's tabs and logins.
///
/// Proxy route: WKWebView → SOCKS5 on 127.0.0.1:47801 → ViaMacClient → iroh
/// (direct or via relay) → SOCKS server in UniBrowser on the Mac → the Mac's
/// network and VPN. Host names are resolved on the Mac, so internal DNS names work.
///
/// Mirror: the via-Mac mode's spaces, groups and tabs are the Mac's. While
/// connected, every change on either side is sent at once and the later one
/// wins; after time apart, the Mac merges both sides and keeps new tabs from each.
@MainActor
@Observable
final class MacRelay {
    enum Path: Equatable {
        /// Same Wi-Fi or a punched-through NAT.
        case direct
        /// Through a relay server, which sees only ciphertext.
        case relay
    }

    enum Status: Equatable {
        case notPaired
        case connecting
        case connected(Path)
        case unreachable(reason: String)
    }

    struct PairedMac: Codable, Equatable {
        var id: String
        var relayURL: String?
        var name: String
    }

    /// Loopback port where ViaMacClient serves the tunnel as SOCKS5.
    static let localProxyPort: NWEndpoint.Port = 47801

    private(set) var status: Status = .notPaired
    private(set) var pairedMac: PairedMac?
    private(set) var lastError: String?
    /// True while the tab mirror is live.
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?

    /// Domains sent through the Mac, e.g. "corp.example". Everything else goes direct.
    var workDomains: [String] {
        didSet {
            UserDefaults.standard.set(workDomains, forKey: Keys.domains)
            onProxiesChange?(proxyConfigurations())
        }
    }

    @ObservationIgnored var onProxiesChange: (@MainActor ([ProxyConfiguration]) -> Void)?
    @ObservationIgnored private let client = ViaMacClient()
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private weak var store: MobileStore?
    @ObservationIgnored private weak var passwords: PhonePasswords?
    @ObservationIgnored private var channel: SyncChannel?
    /// The last session both sides agreed on; the base of the next merge.
    @ObservationIgnored private var base: SessionSnapshot?
    @ObservationIgnored private var lastMirrored: SessionSnapshot?

    private enum Keys {
        static let domains = "viaMac.workDomains"
        static let mac = "viaMac.pairedMac"
    }

    init() {
        workDomains = UserDefaults.standard.stringArray(forKey: Keys.domains) ?? []
        pairedMac = UserDefaults.standard.data(forKey: Keys.mac)
            .flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }
        base = Self.loadBase()
        let client = self.client
        Task {
            do {
                try await client.startLocalProxy(port: Self.localProxyPort)
            } catch {
                self.lastError = "Не удалось открыть локальный порт: \(error.localizedDescription)"
            }
        }
    }

    /// Called once from AppModel with the via-Mac mode's tabs and the phone's logins.
    func attach(store: MobileStore, passwords: PhonePasswords) {
        self.store = store
        self.passwords = passwords
        store.onLocalChange = { [weak self] snapshot in self?.mirror(snapshot) }
        passwords.onSave = { [weak self] credential in self?.send(.savePassword(credential)) }
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    // MARK: - Proxy

    /// One SOCKS5 hop to the tunnel for the work domains. Failover is off on
    /// purpose: with the Mac unreachable a work page fails instead of quietly
    /// loading from the phone's own network.
    func proxyConfigurations() -> [ProxyConfiguration] {
        guard !workDomains.isEmpty else { return [] }
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: Self.localProxyPort))
        proxy.matchDomains = workDomains
        proxy.allowFailover = false
        return [proxy]
    }

    func addDomain(_ raw: String) {
        let domain = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/*."))
        guard !domain.isEmpty, !workDomains.contains(domain) else { return }
        workDomains.append(domain)
    }

    func removeDomains(at offsets: IndexSet) {
        workDomains.remove(atOffsets: offsets)
    }

    // MARK: - Pairing

    /// Handles a `unibrowser://pair?…` link from the Mac's QR code (Camera or pasted).
    func pair(using link: String) async {
        lastError = nil
        do {
            let payload = try PairingPayload(link: link)
            linkTask?.cancel()
            linkTask = nil
            await client.disconnect()
            status = .connecting
            let name = try await client.pair(with: payload, deviceName: UIDevice.current.name)
            if pairedMac?.id != payload.macID { setBase(nil) }
            pairedMac = PairedMac(id: payload.macID, relayURL: payload.relayURL, name: name)
            savePairedMac()
            // Reuses the connection pairing just made, starts the mirror and keeps the link up.
            isActive = true
            startLink()
        } catch {
            lastError = error.localizedDescription
            status = pairedMac == nil ? .notPaired : .unreachable(reason: error.localizedDescription)
        }
    }

    func unpair() async {
        linkTask?.cancel()
        linkTask = nil
        await client.disconnect()
        linkClosed()
        pairedMac = nil
        savePairedMac()
        setBase(nil)
        status = .notPaired
    }

    private func savePairedMac() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pairedMac), forKey: Keys.mac)
    }

    // MARK: - Keeping the link up

    /// iOS suspends the app in the background, which drops the link; it is
    /// re-established whenever the app becomes active.
    func appBecameActive() {
        isActive = true
        startLink()
    }

    func appWentToBackground() {
        isActive = false
        linkTask?.cancel()
        linkTask = nil
        Task {
            // Lets the last change (saved just before) reach the Mac.
            try? await Task.sleep(for: .milliseconds(300))
            await client.disconnect()
            linkClosed()
        }
    }

    func reconnectNow() {
        linkTask?.cancel()
        linkTask = nil
        startLink()
    }

    private func startLink() {
        guard linkTask == nil, pairedMac != nil, isActive else { return }
        linkTask = Task { [weak self] in
            var delay: Double = 1
            while !Task.isCancelled, let self, self.isActive, let mac = self.pairedMac {
                self.status = .connecting
                do {
                    _ = try await self.client.connect(macID: mac.id, relayURL: mac.relayURL)
                    delay = 1
                    await self.linkEstablished()
                    let reason = await self.client.waitUntilClosed()
                    self.linkClosed()
                    if Task.isCancelled { return }
                    self.status = .unreachable(reason: "Связь с Mac прервалась (\(reason)).")
                } catch {
                    if Task.isCancelled { return }
                    self.status = .unreachable(reason: "Mac недоступен: \(error.localizedDescription)")
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    private func linkEstablished() async {
        await refreshPath()
        await startMirror()
        // Paths start on the relay and move to direct once hole punching succeeds.
        Task { [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isConnected else { return }
                await self.refreshPath()
            }
        }
    }

    private func refreshPath() async {
        switch await client.currentPath() {
        case .direct: status = .connected(.direct)
        case .relay: status = .connected(.relay)
        case nil: break
        }
    }

    private func linkClosed() {
        channel = nil
        isSyncing = false
    }

    // MARK: - Mirror

    private func startMirror() async {
        guard let store, let passwords else { return }
        do {
            let channel = try await client.openSync()
            self.channel = channel
            try await channel.write(.hello(session: store.currentSnapshot(), base: base, savedPasswords: passwords.pending))
            isSyncing = true
            Task { [weak self] in
                var isFirst = true
                while let message = try? await channel.next() {
                    guard let self, self.channel === channel else { return }
                    self.received(message, isMergeAnswer: isFirst)
                    if case .session = message { isFirst = false }
                }
                if let self, self.channel === channel { self.linkClosed() }
            }
        } catch {
            lastError = "Вкладки не синхронизировались: \(error.localizedDescription)"
        }
    }

    private func received(_ message: SyncMessage, isMergeAnswer: Bool) {
        switch message {
        case .session(let session):
            // The answer to hello is the Mac's merge of both sides and always applies.
            guard let store else { return }
            store.applyMirror(session, force: isMergeAnswer)
            if store.lastModified == session.modifiedAt {
                lastMirrored = session
                setBase(session)
            } else {
                // The phone changed later: the Mac takes the phone's version instead.
                let mine = store.currentSnapshot()
                lastMirrored = mine
                setBase(mine)
                send(.session(mine))
            }
            lastSynced = .now
        case .passwords(let logins):
            passwords?.replaceFromMac(logins)
        case .hello, .savePassword:
            break
        }
    }

    /// Every save in the via-Mac mode goes to the Mac while connected; offline
    /// changes wait for the merge on the next connection.
    private func mirror(_ snapshot: SessionSnapshot) {
        guard channel != nil else { return }
        if let lastMirrored, lastMirrored.hasSameContent(as: snapshot) { return }
        lastMirrored = snapshot
        setBase(snapshot)
        send(.session(snapshot))
    }

    private func send(_ message: SyncMessage) {
        guard let channel else { return }
        Task {
            do {
                try await channel.write(message)
                lastSynced = .now
            } catch {
                if self.channel === channel { linkClosed() }
            }
        }
    }

    private func setBase(_ snapshot: SessionSnapshot?) {
        base = snapshot
        let url = Self.baseURL
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static var baseURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "UniBrowser", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "mirror-base.json")
    }

    private static func loadBase() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: baseURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    // MARK: - Send to Mac

    /// Opens `url` in a new tab on the Mac and brings UniBrowser forward there.
    /// Returns false if the Mac isn't reachable.
    func sendToMac(_ url: URL) async -> Bool {
        do {
            _ = try await client.request(.open(url: url))
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
