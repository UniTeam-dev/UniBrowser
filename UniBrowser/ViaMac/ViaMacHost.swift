import AppKit
import Foundation
import Observation
import SystemConfiguration

/// The Mac side of the iPhone link: paired iPhones send their work-site
/// requests through this Mac (and so through its VPN), and get a live
/// two-way mirror of this Mac's spaces, groups, tabs and saved logins.
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

    private enum Keys {
        static let enabled = "viaMac.enabled"
        static let devices = "viaMac.pairedDevices"
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        pairedDevices = UserDefaults.standard.data(forKey: Keys.devices)
            .flatMap { try? JSONDecoder().decode([PairedDevice].self, from: $0) } ?? []
    }

    /// Called once from AppModel; starts serving if the user left it on.
    func attach(store: BrowserStore, passwords: KeychainCredentialProvider) {
        self.store = store
        self.passwords = passwords
        store.onLocalChange = { [weak self] snapshot in self?.mirror(snapshot) }
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
            let address = try await engine.start(secretKey: ViaMacIdentity.secretKey())
            self.engine = engine
            endpointID = address.id
            relayURL = address.relayURL
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
        pairing = nil
        status = .off
        updateAwakeActivity()
    }

    // MARK: - Pairing

    /// Shows a fresh QR code; it works once and for ten minutes.
    func beginPairing() {
        guard let endpointID else { return }
        pairing = PairingPayload(
            macID: endpointID,
            relayURL: relayURL,
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
    func hello(session: SessionSnapshot, base: SessionSnapshot?, savedPasswords: [SyncedCredential]) async -> [SyncMessage] {
        guard let store else { return [] }
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
        return [.session(result), .passwords(logins)]
    }

    func syncStarted(_ deviceID: String) {
        syncingDeviceIDs.insert(deviceID)
        watchPasswords()
    }

    func syncEnded(_ deviceID: String) {
        syncingDeviceIDs.remove(deviceID)
        if syncingDeviceIDs.isEmpty {
            passwordsWatch?.cancel()
            passwordsWatch = nil
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
        case .hello, .passwords, .sessionKeepingImages:
            break
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
