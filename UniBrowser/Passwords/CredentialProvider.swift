import Foundation

struct Credential: Hashable, Identifiable, Sendable {
    var host: String
    var username: String
    var password: String

    var id: String { "\(host)\u{1F}\(username)" }
}

enum CredentialError: LocalizedError {
    case notConnected(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConnected(let reason): reason
        case .keychain(let status): SecCopyErrorMessageString(status, nil) as String? ?? "Ошибка связки ключей \(status)"
        }
    }
}

/// Where logins come from and go to.
@MainActor
protocol CredentialProvider: AnyObject {
    /// Shown in the UI: "Пароли" or "Связка ключей UniBrowser".
    var displayName: String { get }
    func credentials(for host: String) async throws -> [Credential]
    func save(_ credential: Credential) async throws
}

