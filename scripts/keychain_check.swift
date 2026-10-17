// Round-trips UniBrowser's keychain queries (save -> all -> delete) so the query
// shapes in KeychainCredentialProvider stay valid. Writes to the login keychain
// under a throwaway label, then removes it.
//   swiftc scripts/keychain_check.swift -o /tmp/keychain_check && /tmp/keychain_check
import Foundation
import Security

let label = "UniBrowserSelfCheck"
let host = "selfcheck.example"
let account = "tester"
let secret = "s3cr3t-\(UUID().uuidString)"

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }

// clean any leftovers
SecItemDelete([kSecClass: kSecClassInternetPassword, kSecAttrLabel: label] as CFDictionary)

// save (same shape as KeychainCredentialProvider.save)
let item: [CFString: Any] = [
    kSecClass: kSecClassInternetPassword,
    kSecAttrServer: host, kSecAttrAccount: account, kSecAttrLabel: label,
    kSecAttrProtocol: kSecAttrProtocolHTTPS, kSecValueData: Data(secret.utf8),
]
guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { fail("add") }

// all(): attribute-only enumeration of hosts
var attrs: CFTypeRef?
let allStatus = SecItemCopyMatching([
    kSecClass: kSecClassInternetPassword, kSecAttrLabel: label,
    kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true,
] as CFDictionary, &attrs)
guard allStatus == errSecSuccess else { fail("all status \(allStatus)") }
let hosts = Set((attrs as? [[String: Any]] ?? []).compactMap { $0[kSecAttrServer as String] as? String })
guard hosts == [host] else { fail("hosts \(hosts)") }

// per-account read with data (same shape as credentials(for:))
var found: CFTypeRef?
let readStatus = SecItemCopyMatching([
    kSecClass: kSecClassInternetPassword, kSecAttrServer: host, kSecAttrAccount: account,
    kSecAttrLabel: label, kSecMatchLimit: kSecMatchLimitOne, kSecReturnData: true,
] as CFDictionary, &found)
guard readStatus == errSecSuccess else { fail("read status \(readStatus)") }
guard let data = found as? Data,
      String(data: data, encoding: .utf8) == secret else { fail("password mismatch") }

// delete
guard SecItemDelete([
    kSecClass: kSecClassInternetPassword, kSecAttrServer: host,
    kSecAttrAccount: account, kSecAttrLabel: label,
] as CFDictionary) == errSecSuccess else { fail("delete") }

// gone
let gone = SecItemCopyMatching([
    kSecClass: kSecClassInternetPassword, kSecAttrLabel: label, kSecReturnAttributes: true,
] as CFDictionary, nil)
guard gone == errSecItemNotFound else { fail("still present \(gone)") }

print("keychain check passed")
