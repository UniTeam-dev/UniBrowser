import Foundation
import Network
import Observation
import UIKit

/// The phone's side of the link to the Mac: the paired Mac, the connection,
/// and the live mirror of the Mac's tabs, logins, bookmarks and history. Every page of the via-Mac mode goes through it.
///
/// Proxy route: WKWebView → SOCKS5 on 127.0.0.1:47801 → ViaMacClient → iroh
/// (direct or via relay) → SOCKS server in UniBrowser on the Mac → the Mac's
/// network. Host names are resolved on the Mac, so internal DNS names work.
///
/// Mirror: the via-Mac mode's spaces, groups and tabs are the Mac's. While
/// connected, every change on either side is sent at once and the later one
/// wins; after time apart, the Mac merges both sides and keeps new tabs from each.
@MainActor
@Observable
final class MacRelay {
    enum Status: Equatable {
        case notPaired
        case connecting
        /// The path: the Mac's external address, other direct, or a relay server (which sees only ciphertext).
        case connected(LinkPath)
        case unreachable(reason: String)
    }

    struct PairedMac: Codable, Equatable {
        var id: String
        var relayURL: String?
        var name: String
        /// The Mac's own IP addresses, from the QR and then from every ping answer.
        var addresses: [String]?
        /// The Mac's «Внешний адрес» (`host:port`), from the QR and every answer.
        var externalAddress: String?
    }

    /// Loopback port where ViaMacClient serves the tunnel as SOCKS5.
    static let localProxyPort: NWEndpoint.Port = 47801

    private(set) var status: Status = .notPaired
    private(set) var pairedMac: PairedMac?
    private(set) var lastError: String?
    /// True while the tab mirror is live.
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?

    /// The user's own «Внешний адрес Mac» on this phone; empty: the one the Mac sends.
    var externalAddressOverride: String {
        didSet { UserDefaults.standard.set(externalAddressOverride, forKey: Keys.externalOverride) }
    }

    /// The user's own «Сервер связи» on this phone; empty: the Mac's.
    var relayOverride: String {
        didSet { UserDefaults.standard.set(relayOverride, forKey: Keys.relayOverride) }
    }

    /// The external address dialled on the next connect.
    var effectiveExternalAddress: String? {
        let own = externalAddressOverride.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? pairedMac?.externalAddress : own
    }

    /// The Mac's relay as used on the next connect; the phone binds with it too unless it's n0's.
    var effectiveRelay: String? {
        let own = relayOverride.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? pairedMac?.relayURL : own
    }

    @ObservationIgnored private let client = ViaMacClient()
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var isPairing = false
    /// Set when the keep-alive gave up on a link that still looked open.
    @ObservationIgnored private var macStoppedAnswering = false
    @ObservationIgnored private weak var store: MobileStore?
    @ObservationIgnored private weak var sshHosts: SSHHostStore?
    @ObservationIgnored private weak var knownHosts: KnownHostsStore?
    @ObservationIgnored private weak var passwords: PhonePasswords?
    @ObservationIgnored private var channel: SyncChannel?
    /// The last session both sides agreed on; the base of the next merge.
    @ObservationIgnored private var base: SessionSnapshot?
    /// Between hello and the Mac's merged answer the phone's session may lack what the
    /// Mac changed meanwhile; sending it then would overwrite those changes.
    @ObservationIgnored private var awaitingMergeAnswer = false
    @ObservationIgnored private var lastMirrored: SessionSnapshot?
    @ObservationIgnored private var historyPump: Task<Void, Never>?
    @ObservationIgnored private var proxyChange: Task<Void, Never>?
    /// The external address as resolved for the current link, to tell that path apart.
    @ObservationIgnored private var externalTargets: [String] = []
    @ObservationIgnored private var linkPath: LinkPath?
    /// Each time the link comes up; SSH tabs that found no link log in again.
    @ObservationIgnored var onLinkEstablished: (() -> Void)?

    private enum Keys {
        static let mac = "viaMac.pairedMac"
        static let externalOverride = "viaMac.externalAddressOverride"
        static let relayOverride = "viaMac.relayOverride"
    }

    init() {
        pairedMac = UserDefaults.standard.data(forKey: Keys.mac)
            .flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }
        base = Self.loadBase()
        externalAddressOverride = UserDefaults.standard.string(forKey: Keys.externalOverride) ?? ""
        relayOverride = UserDefaults.standard.string(forKey: Keys.relayOverride) ?? ""
    }

    /// Called once from AppModel with the via-Mac mode's tabs and the phone's logins.
    func attach(store: MobileStore, passwords: PhonePasswords, sshHosts: SSHHostStore, knownHosts: KnownHostsStore) {
        self.store = store
        self.passwords = passwords
        self.sshHosts = sshHosts
        self.knownHosts = knownHosts
        sshHosts.onLocalChange = { [weak self, weak sshHosts] in
            guard let sshHosts else { return }
            self?.send(.sshHosts(sshHosts.synced()))
        }
        knownHosts.onLocalChange = { [weak self, weak knownHosts] in
            guard let knownHosts else { return }
            self?.send(.knownHosts(knownHosts.all))
        }
        store.onLocalChange = { [weak self] snapshot in self?.mirror(snapshot) }
        passwords.onSave = { [weak self] credential in self?.send(.savePassword(credential)) }
        store.bookmarks.onLocalChange = { [weak self, weak store] in
            guard let store else { return }
            self?.send(.bookmarks(store.bookmarks.all))
        }
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    // MARK: - Proxy

    /// One SOCKS5 hop to the tunnel for every load of the via-Mac mode. Failover is
    /// off on purpose: with the Mac unreachable a page fails instead of quietly
    /// loading from the phone's own network.
    static func proxyConfigurations() -> [ProxyConfiguration] {
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: localProxyPort))
        proxy.allowFailover = false
        return [proxy]
    }

    // MARK: - Pairing

    /// Handles a `unibrowser://pair?…` link from the Mac's QR code (Camera or pasted).
    func pair(using link: String) async {
        lastError = nil
        // The link opened from the QR also makes the app active; that must not start a
        // second link to the old Mac while this one pairs.
        isPairing = true
        do {
            let payload = try PairingPayload(link: link)
            linkTask?.cancel()
            linkTask = nil
            await client.disconnect()
            linkClosed()
            status = .connecting
            let external = await ViaMacClient.resolve(payload.externalAddress)
            let response = try await client.pair(with: payload, addresses: (payload.addresses ?? []) + external,
                                                 deviceName: UIDevice.current.name)
            if pairedMac?.id != payload.macID { setBase(nil) }
            pairedMac = PairedMac(id: payload.macID, relayURL: payload.relayURL, name: response.macName ?? payload.macName,
                                  addresses: response.addresses ?? payload.addresses, externalAddress: payload.externalAddress)
            savePairedMac()
            updateMac(from: response)
            isActive = true
        } catch {
            lastError = error.localizedDescription
            status = pairedMac == nil ? .notPaired : .unreachable(reason: error.localizedDescription)
        }
        isPairing = false
        // Reuses the connection pairing just made, starts the mirror and keeps the link up.
        startLink()
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
        setLocalProxy(open: true)
        startLink()
    }

    func appWentToBackground() {
        isActive = false
        setLocalProxy(open: false)
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

    /// Opens or closes the loopback SOCKS port, in call order. iOS defuncts the
    /// listener of a suspended app; a port kept from before would leave every
    /// page hanging after the return while the link shows as connected.
    private func setLocalProxy(open: Bool) {
        let previous = proxyChange
        let client = self.client
        proxyChange = Task {
            await previous?.value
            guard open else { return await client.stopLocalProxy() }
            do {
                try await client.startLocalProxy(port: Self.localProxyPort)
            } catch {
                lastError = "Не удалось открыть локальный порт: \(error.localizedDescription)"
            }
        }
    }

    private func startLink() {
        guard linkTask == nil, pairedMac != nil, isActive, !isPairing else { return }
        linkTask = Task { [weak self] in
            var delay: Double = 1
            while !Task.isCancelled, let self, self.isActive, let mac = self.pairedMac {
                self.status = .connecting
                do {
                    // A DDNS name is resolved anew each time: the home IP may have changed.
                    let external = await ViaMacClient.resolve(self.effectiveExternalAddress)
                    self.externalTargets = external
                    self.linkPath = nil
                    _ = try await self.client.connect(macID: mac.id, relayURL: self.effectiveRelay,
                                                      addresses: (mac.addresses ?? []) + external)
                    // «Connected» only once the Mac answers on this link: a phone it doesn't know, or a
                    // link that carries nothing yet, stays «connecting». A new link over a throttled
                    // relay can take a minute to carry its first stream.
                    try await self.ping(timeout: 60)
                    if Task.isCancelled { return }
                    delay = 1
                    await self.linkEstablished()
                    self.macStoppedAnswering = false
                    let keepAlive = self.keepAlive()
                    var reason = await self.client.waitUntilClosed()
                    keepAlive.cancel()
                    self.linkClosed()
                    if Task.isCancelled { return }
                    if self.macStoppedAnswering { reason = "Mac не отвечает" }
                    self.status = .unreachable(reason: "Связь с Mac прервалась (\(reason)).")
                } catch ViaMacError.outdatedMac {
                    if Task.isCancelled { return }
                    self.status = .unreachable(reason: ViaMacError.outdatedMac.localizedDescription)
                } catch ViaMacError.rejected(let reason) {
                    if Task.isCancelled { return }
                    self.status = .unreachable(reason: reason)
                } catch {
                    if Task.isCancelled { return }
                    self.status = .unreachable(reason: "Mac недоступен: \(error.localizedDescription)")
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    /// One round trip to the Mac; keeps how to reach the Mac for the next connect and tells
    /// the Mac which path this link took.
    private func ping(timeout: Double) async throws {
        updateMac(from: try await client.ping(path: linkPath, timeout: timeout))
    }

    /// The Mac's addresses, relay and external address from its answer.
    private func updateMac(from response: ControlResponse) {
        guard var mac = pairedMac else { return }
        if let addresses = response.addresses { mac.addresses = addresses }
        if let relay = response.relayURL { mac.relayURL = relay }
        // An older Mac doesn't send it; an empty one means the user cleared it.
        if let external = response.externalAddress { mac.externalAddress = external.isEmpty ? nil : external }
        guard mac != pairedMac else { return }
        pairedMac = mac
        savePairedMac()
    }

    /// A link can stay open while nothing gets through (the Mac app hung, a relay
    /// that stopped forwarding). Pings every 10 s; one unanswered for 10 s closes
    /// the link, and the loop in `startLink` connects again.
    private func keepAlive() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                do {
                    try await self.ping(timeout: 10)
                } catch {
                    if Task.isCancelled { return }
                    self.macStoppedAnswering = true
                    await self.client.disconnect()
                    return
                }
            }
        }
    }

    private func linkEstablished() async {
        await refreshPath()
        await startMirror()
        // Tabs restored at launch load before the link is up and fail; load them again now.
        for tab in store?.tabs.values.filter(\.loadFailed) ?? [] {
            if let url = tab.url { tab.load(url) }
        }
        onLinkEstablished?()
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
        guard let path = await client.currentPath(external: externalTargets) else { return }
        linkPath = path
        status = .connected(path)
    }

    private func linkClosed() {
        channel = nil
        isSyncing = false
        historyPump?.cancel()
        historyPump = nil
    }

    // MARK: - Mirror

    private func startMirror() async {
        guard let store, let passwords, let sshHosts, let knownHosts else { return }
        do {
            let channel = try await client.openSync()
            self.channel = channel
            awaitingMergeAnswer = true
            try await channel.write(.hello(session: store.currentSnapshot(), base: base, savedPasswords: passwords.pending,
                                           bookmarks: store.bookmarks.all, sshHosts: sshHosts.synced(), knownHosts: knownHosts.all))
            isSyncing = true
            pumpHistory(channel)
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
            if isMergeAnswer { awaitingMergeAnswer = false }
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
        case .bookmarks(let remote):
            guard let bookmarks = store?.bookmarks else { return }
            bookmarks.merge(remote)
            // The Mac is missing something the phone has: it gets the phone's list back.
            if Set(bookmarks.all) != Set(remote) { send(.bookmarks(bookmarks.all)) }
        case .sshHosts(let remote):
            guard let sshHosts else { return }
            sshHosts.merge(remote)
            // Only when the Mac would gain something, so a kept local version or a tie doesn't bounce.
            let mine = sshHosts.synced()
            if SSHHostMerge.needsReply(received: remote, mine: mine) { send(.sshHosts(mine)) }
        case .knownHosts(let remote):
            guard let knownHosts else { return }
            knownHosts.merge(remote)
            if KnownHostMerge.needsReply(received: remote, mine: knownHosts.all) { send(.knownHosts(knownHosts.all)) }
        case .history(let visits):
            store?.history?.merge(visits)
        case .hello, .savePassword, .sessionKeepingImages:
            break
        }
    }

    /// Every 5 s while syncing, the visits made since the last batch the Mac
    /// got (the cursor per Mac survives relaunches).
    private func pumpHistory(_ channel: SyncChannel) {
        historyPump?.cancel()
        historyPump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.channel === channel, let mac = self.pairedMac, let history = self.store?.history else { return }
                let key = "viaMac.historySent." + mac.id
                let cursor = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
                // Batches stay small; the first sync of a long history takes a few rounds.
                let batch = Array(history.visits(since: cursor).prefix(500))
                if let last = batch.last {
                    do {
                        // Only the phone's own visits: the ones from the Mac are already there.
                        let own = batch.filter { $0.deviceID == history.deviceID }
                        if !own.isEmpty { try await channel.write(.history(own)) }
                        UserDefaults.standard.set(last.visitedAt, forKey: key)
                        self.lastSynced = .now
                    } catch {
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Every save in the via-Mac mode goes to the Mac while connected; offline
    /// changes wait for the merge on the next connection.
    private func mirror(_ snapshot: SessionSnapshot) {
        guard channel != nil, !awaitingMergeAnswer else { return }
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
