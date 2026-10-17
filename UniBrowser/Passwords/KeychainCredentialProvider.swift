import Foundation
import Security

/// Stores logins as internet-password items in the user's login keychain,
/// labelled "UniBrowser". These do not show up in the Passwords app; this is
/// the stopgap until the Apple Passwords bridge is allowed (see docs/passwords.md).
@MainActor
final class KeychainCredentialProvider: CredentialProvider {
    private let label = "UniBrowser"

    var displayName: String { "Связка ключей UniBrowser" }

    func credentials(for host: String) async throws -> [Credential] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrLabel: label,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }

        let items = result as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8)
            else { return nil }
            return Credential(host: host, username: account, password: password)
        }
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
