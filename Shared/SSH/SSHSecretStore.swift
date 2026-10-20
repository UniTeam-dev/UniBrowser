import Foundation
import Security

/// Host secrets in the keychain: one generic-password item per host (account = host UUID),
/// the JSON-encoded `SSHSecret` as its data.
struct SSHSecretStore: Sendable {
    let service: String
    /// Makes every `write` throw; for the store check only.
    let failsWrites: Bool

    init(service: String = "app.unibrowser.ssh", failsWrites: Bool = false) {
        self.service = service
        self.failsWrites = failsWrites
    }

    func read(_ id: UUID) -> SSHSecret? {
        var query = match(id)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return try? JSONDecoder().decode(SSHSecret.self, from: data)
    }

    func write(_ secret: SSHSecret, for id: UUID) throws {
        if failsWrites { throw KeychainError(status: errSecInteractionNotAllowed) }
        let data = try JSONEncoder().encode(secret)
        let status = SecItemUpdate(match(id) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var item = match(id)
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    func delete(_ id: UUID) {
        SecItemDelete(match(id) as CFDictionary)
    }

    private func match(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
    }

    struct KeychainError: Error { let status: OSStatus }
}
