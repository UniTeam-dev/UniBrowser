import AppKit
import Foundation
import Observation
import SystemConfiguration

/// The Mac side of the iPhone link: paired iPhones send every page of their
/// «Через Mac» mode through this Mac and its network, and get a live
/// two-way mirror of this Mac's spaces, groups, tabs, saved logins, bookmarks
/// and history. The Mac keeps one library; all its phones share it.
@MainActor
@Observable
final class ViaMacHost {
    enum Status: Equatable {
        case off
        case starting
        case ready
        case failed(String)
    }

    struct PairedDevice: Codable, Identifiable, Hashable {
        /// The phone's iroh endpoint id.
        var id: String
        var name: String
        var pairedAt: Date
    }

    private(set) var status: Status = .off
    private(set) var endpointID: String?
    private(set) var relayURL: String?
    private(set) var pairedDevices: [PairedDevice]
    private(set) var connectedDeviceIDs: Set<String> = []
    /// Phones whose tab mirror is live right now.
    private(set) var syncingDeviceIDs: Set<String> = []
    /// The code currently shown as a QR; nil until "Показать QR-код" is pressed.
    private(set) var pairing: PairingPayload?
    /// The UDP port the link listens on (IPv4), the one to forward on the router.
    private(set) var boundPort: UInt16?
    /// This Mac's address on its local network, for the router's port forward.
    private(set) var lanAddress: String?
    /// How each phone reached the Mac on its last link, as the phone reported it.
    private(set) var linkPaths: [String: LinkPath] = [:]

    /// The fixed UDP port for a router port forward.
    var port: Int {
        didSet {
            UserDefaults.standard.set(port, forKey: Keys.port)
            if port != oldValue { restartIfRunning() }
        }
    }

    /// «Внешний адрес»: the home's public IP or DNS name, optionally with `:port`. Phones
    /// get it with the QR and every answer, so changing it needs no restart.
    var externalAddress: String {
        didSet { UserDefaults.standard.set(externalAddress, forKey: Keys.externalAddress) }
    }

    /// «Свой сервер связи»: a relay URL; empty or n0's means n0's public relays.
    var relayServer: String {
        didSet {
            UserDefaults.standard.set(relayServer, forKey: Keys.relayServer)
            if relayServer != oldValue { restartIfRunning() }
        }
    }

    /// The external address as phones dial it: `host:port`, the port defaulting to this Mac's.
    var externalAddressForPhones: String? {
        ViaMacAddress.parse(externalAddress, defaultPort: boundPort ?? UInt16(clamping: port))
            .map { ViaMacAddress.join($0.host, $0.port) }
    }

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            Task {
                if isEnabled { await start() } else { await stop() }
            }
        }
    }

    @ObservationIgnored private weak var store: BrowserStore?
    @ObservationIgnored private var passwords: KeychainCredentialProvider?
    @ObservationIgnored private var engine: ViaMacEngine?
    @ObservationIgnored private var awakeActivity: NSObjectProtocol?
    /// The session the phones last got or sent, so an unchanged save isn't resent.
    @ObservationIgnored private var lastMirrored: SessionSnapshot?
    @ObservationIgnored private var lastSentPasswords: [SyncedCredential] = []
    @ObservationIgnored private var passwordsWatch: Task<Void, Never>?
    @ObservationIgnored private var history: HistoryStore?
    @ObservationIgnored private var bookmarks: BookmarkStore?
    @ObservationIgnored private var historyPump: Task<Void, Never>?

    private enum Keys {
        static let enabled = "viaMac.enabled"
        static let devices = "viaMac.pairedDevices"
        static let port = "viaMac.port"
        static let externalAddress = "viaMac.externalAddress"
        static let relayServer = "viaMac.relayServer"
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        pairedDevices = UserDefaults.standard.data(forKey: Keys.devices)
            .flatMap { try? JSONDecoder().decode([PairedDevice].self, from: $0) } ?? []
        port = UserDefaults.standard.object(forKey: Keys.port) as? Int ?? Int(ViaMacAddress.defaultPort)
        externalAddress = UserDefaults.standard.string(forKey: Keys.externalAddress) ?? ""
        relayServer = UserDefaults.standard.string(forKey: Keys.relayServer) ?? ""
    }

    /// Called once from AppModel; starts serving if the user left it on.
    func attach(store: BrowserStore, passwords: KeychainCredentialProvider, history: HistoryStore, bookmarks: BookmarkStore) {
        self.store = store
        self.passwords = passwords
        self.history = history
        self.bookmarks = bookmarks
        store.onLocalChange = { [weak self] snapshot in self?.mirror(snapshot) }
        bookmarks.onLocalChange = { [weak self] in
            guard let self, let engine = self.engine, !self.syncingDeviceIDs.isEmpty else { return }
            let all = bookmarks.all
            Task { await engine.broadcast(.bookmarks(all)) }
        }
        if isEnabled { Task { await start() } }
    }

    var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    // MARK: - Lifecycle

    func start() async {
        guard engine == nil, status != .starting else { return }
        status = .starting
        let engine = ViaMacEngine(host: self)
        do {
            let address = try await engine.start(secretKey: ViaMacIdentity.secretKey(), port: UInt16(clamping: port),
                                                 relay: ViaMacAddress.customRelay(relayServer))
            self.engine = engine
            endpointID = address.id
            relayURL = address.relayURL
            boundPort = address.port
            lanAddress = Self.lanAddress(in: await engine.directAddresses())
            status = .ready
            updateAwakeActivity()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        let engine = self.engine
        self.engine = nil
        await engine?.stop()
        connectedDeviceIDs = []
        syncingDeviceIDs = []
        passwordsWatch?.cancel()
        passwordsWatch = nil
        historyPump?.cancel()
        historyPump = nil
        pairing = nil
        boundPort = nil
        linkPaths = [:]
        status = .off
        updateAwakeActivity()
    }

    private func restartIfRunning() {
        guard engine != nil else { return }
        Task {
            await stop()
            await start()
        }
    }

    /// The private IPv4 addresses among iroh's `ip:port` ones, 192.168.x.x first (the usual
    /// home router range; 172.16–31 is often a VPN or a virtual machine network).
    private static func lanAddress(in addresses: [String]) -> String? {
        let ips = addresses.compactMap { $0.split(separator: ":").count == 2 ? String($0.split(separator: ":")[0]) : nil }
        func rank(_ ip: String) -> Int? {
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return nil }
            if parts[0] == 192 && parts[1] == 168 { return 0 }
            if parts[0] == 10 { return 1 }
            if parts[0] == 172 && (16...31).contains(parts[1]) { return 2 }
            return nil
        }
        let lan = ips.filter { rank($0) != nil }.sorted { rank($0)! < rank($1)! }
        return lan.isEmpty ? nil : lan.joined(separator: ", ")
    }

    // MARK: - Pairing

    /// Shows a fresh QR code; it works once and for ten minutes.
    func beginPairing() async {
        guard let endpointID, let engine else { return }
        pairing = PairingPayload(
            macID: endpointID,
            relayURL: relayURL,
            addresses: await engine.directAddresses(),
            externalAddress: externalAddressForPhones,
            macName: macName,
            token: PairingPayload.newToken(),
            expires: .now.addingTimeInterval(ViaMacProtocol.pairingLifetime)
        )
    }

    func cancelPairing() {
        pairing = nil
    }

    func isPaired(_ deviceID: String) -> Bool {
        pairedDevices.contains { $0.id == deviceID }
    }

    /// Accepts the phone if `token` matches the QR on screen and hasn't expired.
    func redeem(token: String, deviceName: String, deviceID: String) -> Bool {
        if isPaired(deviceID) { return true }
        guard let pairing, pairing.token == token, pairing.expires > .now else { return false }
        self.pairing = nil
        pairedDevices.append(PairedDevice(id: deviceID, name: deviceName, pairedAt: .now))
        savePairedDevices()
        updateAwakeActivity()
        return true
    }

    func remove(_ device: PairedDevice) {
        pairedDevices.removeAll { $0.id == device.id }
        connectedDeviceIDs.remove(device.id)
        syncingDeviceIDs.remove(device.id)
        savePairedDevices()
        updateAwakeActivity()
        Task { await engine?.disconnect(deviceID: device.id) }
    }

    private func savePairedDevices() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pairedDevices), forKey: Keys.devices)
    }

    // MARK: - Engine callbacks

    func deviceConnected(_ deviceID: String) {
        connectedDeviceIDs.insert(deviceID)
    }

    func linkPathReported(_ path: LinkPath, by deviceID: String) {
        linkPaths[deviceID] = path
    }

    func deviceDisconnected(_ deviceID: String) {
        connectedDeviceIDs.remove(deviceID)
        syncingDeviceIDs.remove(deviceID)
    }

    func open(_ url: URL) {
        store?.newTab(url: url)
        NSApp.activate()
    }

    // MARK: - Mirror

    /// The phone's first sync frame after connecting. Merges what both sides did
    /// while apart and returns what the phone should get back.
    func hello(session: SessionSnapshot, base: SessionSnapshot?, savedPasswords: [SyncedCredential],
               bookmarks remoteBookmarks: [Bookmark], from deviceID: String) async -> [SyncMessage] {
        guard let store, let bookmarks else { return [] }
        if bookmarks.merge(remoteBookmarks) {
            await engine?.broadcast(.bookmarks(bookmarks.all), except: deviceID)
        }
        for credential in savedPasswords {
            try? await passwords?.save(Credential(host: credential.host, username: credential.username, password: credential.password))
        }
        let mine = store.currentSnapshot()
        var phone = session
        // First sync: the Mac's spaces and groups win; the phone's tabs join them.
        if base == nil { phone.modifiedAt = .distantPast }
        var result = SessionSnapshot.merged(mine, phone, base: base)
        if result.hasSameContent(as: mine) {
            result = mine
        } else {
            result.modifiedAt = max(.now, store.lastModified.addingTimeInterval(0.001))
            result.deviceID = BrowserStore.deviceID
            store.applyMirror(result)
        }
        lastMirrored = result
        let logins = await allPasswords()
        lastSentPasswords = logins
        return [.session(result), .passwords(logins), .bookmarks(bookmarks.all)]
    }

    func syncStarted(_ deviceID: String) {
        syncingDeviceIDs.insert(deviceID)
        watchPasswords()
        pumpHistory()
    }

    func syncEnded(_ deviceID: String) {
        syncingDeviceIDs.remove(deviceID)
        if syncingDeviceIDs.isEmpty {
            passwordsWatch?.cancel()
            passwordsWatch = nil
            historyPump?.cancel()
            historyPump = nil
        }
    }

    func received(_ message: SyncMessage, from deviceID: String) async {
        switch message {
        case .session(let session):
            guard let store else { return }
            guard let time = session.modifiedAt, time > store.lastModified else {
                // The Mac changed later: the phone takes the Mac's version instead.
                await engine?.send(.session(store.currentSnapshot()), to: deviceID)
                return
            }
            store.applyMirror(session)
            lastMirrored = session
            // Other paired phones follow too.
            await engine?.broadcast(.session(session), except: deviceID)
        case .savePassword(let credential):
            try? await passwords?.save(Credential(host: credential.host, username: credential.username, password: credential.password))
            await sendPasswordsIfChanged()
        case .bookmarks(let remote):
            guard let bookmarks else { return }
            if bookmarks.merge(remote) {
                await engine?.broadcast(.bookmarks(bookmarks.all), except: deviceID)
            }
            // The phone is missing something the Mac has: it gets the Mac's list back.
            if Set(bookmarks.all) != Set(remote) {
                await engine?.send(.bookmarks(bookmarks.all), to: deviceID)
            }
        case .history(let visits):
            history?.merge(visits)
        case .hello, .passwords, .sessionKeepingImages:
            break
        }
    }

    /// Every 5 s while phones are syncing, each gets the visits made since the
    /// last batch it was sent (its cursor survives relaunches). Visits that came
    /// from one phone go on to the others too.
    private func pumpHistory() {
        guard historyPump == nil else { return }
        historyPump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let engine = self.engine, let history = self.history else { return }
                for deviceID in self.syncingDeviceIDs {
                    let key = "viaMac.historySent." + deviceID
                    let cursor = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
                    // Batches stay small; the first sync of a long history takes a few rounds.
                    let batch = Array(history.visits(since: cursor).prefix(500))
                    guard let last = batch.last else { continue }
                    if await engine.sendChecked(.history(batch), to: deviceID) {
                        UserDefaults.standard.set(last.visitedAt, forKey: key)
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Every save on the Mac goes to the phones that are connected right now.
    private func mirror(_ snapshot: SessionSnapshot) {
        guard let engine, !syncingDeviceIDs.isEmpty else { return }
        if let lastMirrored, lastMirrored.hasSameContent(as: snapshot) { return }
        lastMirrored = snapshot
        Task { await engine.broadcast(.session(snapshot)) }
    }

    private func allPasswords() async -> [SyncedCredential] {
        let all = (try? await passwords?.all()) ?? []
        return all.map { SyncedCredential(host: $0.host, username: $0.username, password: $0.password) }
    }

    private func sendPasswordsIfChanged() async {
        let logins = await allPasswords()
        guard logins != lastSentPasswords, let engine else { return }
        lastSentPasswords = logins
        await engine.broadcast(.passwords(logins))
    }

    /// Logins change in the passwords window, the save bar and CSV import, so
    /// while a phone is syncing the store is re-read every few seconds.
    private func watchPasswords() {
        guard passwordsWatch == nil else { return }
        passwordsWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.sendPasswordsIfChanged()
            }
        }
    }

    // MARK: - Keeping the Mac awake

    /// A sleeping Mac drops the phone's connection, so idle sleep is held off
    /// while the mode is on and a phone is paired. A closed lid on battery still sleeps.
    private func updateAwakeActivity() {
        let shouldHold = status == .ready && !pairedDevices.isEmpty
        if shouldHold, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "UniBrowser: связь с iPhone"
            )
        } else if !shouldHold, let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
    }
}
