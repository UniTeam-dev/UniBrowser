import Foundation
import Security

/// Stores logins as internet-password items in the user's login keychain,
/// labelled "UniBrowser". These do not show up in the Passwords app: macOS has
/// no public API for a third-party browser to reach it (see docs/passwords.md).
@MainActor
final class KeychainCredentialProvider: CredentialProvider {
    private let label = "UniBrowser"

    var displayName: String { "Связка ключей UniBrowser" }

    func credentials(for host: String) async throws -> [Credential] {
        // Keychain returns errSecParam for attributes+data+MatchLimitAll together, so list
        // the accounts first (attributes only), then read each password on its own.
        let listQuery: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrLabel: label,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(listQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }

        let accounts = Set((result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String })
        return try accounts.compactMap { account in
            guard let password = try password(host: host, account: account) else { return nil }
            return Credential(host: host, username: account, password: password)
        }
    }

    private func password(host: String, account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrAccount: account,
            kSecAttrLabel: label,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Every login UniBrowser saved, for the passwords manager, sorted by site then name.
    /// Enumerates hosts by attribute first, then reads each site's passwords with the
    /// per-host query above — asking for all attributes AND data at once returns errSecParam.
    func all() async throws -> [Credential] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrLabel: label,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }

        let hosts = Set((result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrServer as String] as? String })
        var all: [Credential] = []
        for host in hosts { all.append(contentsOf: try await credentials(for: host)) }
        return all.sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    /// Imports a Passwords-app CSV export into the keychain. Returns how many logins were saved.
    @discardableResult
    func importCSV(_ text: String) async throws -> Int {
        let credentials = PasswordCSV.credentials(from: text)
        for credential in credentials { try await save(credential) }
        return credentials.count
    }

    func delete(_ credential: Credential) throws {
        let match: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: credential.host,
            kSecAttrAccount: credential.username,
            kSecAttrLabel: label,
        ]
        let status = SecItemDelete(match as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }

    func save(_ credential: Credential) async throws {
        let match: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: credential.host,
            kSecAttrAccount: credential.username,
            kSecAttrLabel: label,
        ]
        let data = Data(credential.password.utf8)
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = match
            item[kSecAttrProtocol] = kSecAttrProtocolHTTPS
            item[kSecValueData] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialError.keychain(added) }
        } else if status != errSecSuccess {
            throw CredentialError.keychain(status)
        }
    }
}
