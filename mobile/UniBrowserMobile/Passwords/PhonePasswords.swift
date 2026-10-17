import Foundation
import Observation
import Security

/// Logins on the phone: a copy of the Mac's UniBrowser passwords, refreshed
/// every time the link connects, plus logins saved here that the Mac hasn't
/// confirmed yet. Both lists live in the phone's Keychain, never in files.
@MainActor
@Observable
final class PhonePasswords {
    private(set) var fromMac: [SyncedCredential]
    /// Saved on the phone, waiting to reach the Mac.
    private(set) var pending: [SyncedCredential]

    /// Set by MacRelay: sends a new login to the Mac while connected.
    @ObservationIgnored var onSave: ((SyncedCredential) -> Void)?

    private enum Account {
        static let mirror = "mirror"
        static let pending = "pending"
    }

    init() {
        fromMac = Self.load(Account.mirror)
        pending = Self.load(Account.pending)
    }

    var all: [SyncedCredential] {
        let mine = Set(pending.map(\.id))
        return (pending + fromMac.filter { !mine.contains($0.id) }).sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    /// Logins for the page's host and its parent domains ("login.corp.example" also gets "corp.example").
    func credentials(for host: String) -> [SyncedCredential] {
        let host = host.lowercased()
        return all.filter { host == $0.host || host.hasSuffix("." + $0.host) }
    }

    func save(_ credential: SyncedCredential) {
        pending.removeAll { $0.id == credential.id }
        pending.append(credential)
        Self.store(pending, Account.pending)
        onSave?(credential)
    }

    /// The Mac's full list arrived; logins it now has stop being pending.
    func replaceFromMac(_ credentials: [SyncedCredential]) {
        fromMac = credentials
        let confirmed = Set(credentials)
        pending.removeAll { confirmed.contains($0) }
        Self.store(fromMac, Account.mirror)
        Self.store(pending, Account.pending)
    }

    func eraseAll() {
        fromMac = []
        pending = []
        Self.store([], Account.mirror)
        Self.store([], Account.pending)
    }

    // MARK: - Keychain

    private static let service = "app.unibrowser.passwords"

    private static func load(_ account: String) -> [SyncedCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([SyncedCredential].self, from: data)) ?? []
    }

    private static func store(_ credentials: [SyncedCredential], _ account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard !credentials.isEmpty, let data = try? JSONEncoder().encode(credentials) else { return }
        var item = match
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }
}
